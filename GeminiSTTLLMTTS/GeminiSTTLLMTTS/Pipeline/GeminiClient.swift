import Foundation

/// Minimal REST client for the Gemini Interactions API covering the three pipeline stages.
nonisolated struct GeminiClient: Sendable {
    enum ReplyEvent: Sendable {
        case text(String)
        case completed(interactionID: String?)
    }

    enum ClientError: LocalizedError {
        case missingAPIKey
        case http(status: Int, message: String)
        case server(String)

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                "Add your Gemini API key in Settings to start a conversation."
            case .http(let status, let message):
                "Gemini returned HTTP \(status): \(message)"
            case .server(let message):
                "Gemini error: \(message)"
            }
        }
    }

    private static let baseURL = URL(string: "https://generativelanguage.googleapis.com/v1beta/")!
    private static let interactionsURL = URL(string: "https://generativelanguage.googleapis.com/v1beta/interactions")!
    private static let streamingInteractionsURL = URL(string: "https://generativelanguage.googleapis.com/v1beta/interactions?alt=sse")!

    /// One shared session so every stage reuses the same warm HTTP/2 connection.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    let apiKey: String

    /// Validates the key and opens the TLS connection before the first turn.
    func warmUp(model: String) async throws {
        var request = URLRequest(url: Self.baseURL.appending(path: "models/\(model)"))
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        let (data, response) = try await Self.session.data(for: request)
        try Self.validate(response, body: data)
    }

    // MARK: - STT

    func transcribe(wav: Data, model: String) async throws -> String {
        let body: [String: Any] = [
            "model": model,
            "store": false,
            "input": [
                ["type": "audio", "mime_type": "audio/wav", "data": wav.base64EncodedString()],
            ],
            "generation_config": [
                "transcription_config": ["mode": "smart"],
            ],
        ]
        let request = try makeRequest(url: Self.interactionsURL, body: body)
        let (data, response) = try await Self.session.data(for: request)
        try Self.validate(response, body: data)
        let interaction = try JSONDecoder().decode(InteractionResponse.self, from: data)
        return interaction.outputText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - LLM

    func streamReply(
        to text: String,
        model: String,
        systemInstruction: String,
        previousInteractionID: String?
    ) throws -> AsyncThrowingStream<ReplyEvent, Error> {
        var body: [String: Any] = [
            "model": model,
            "input": text,
            "system_instruction": systemInstruction,
            "generation_config": ["thinking_level": GeminiModels.thinkingLevel(for: model)],
            "stream": true,
        ]
        if let previousInteractionID {
            body["previous_interaction_id"] = previousInteractionID
        }
        let request = try makeRequest(url: Self.streamingInteractionsURL, body: body)
        return stream(request) { event in
            switch event.eventType {
            case "step.delta" where event.delta?.type == "text":
                event.delta?.text.map(ReplyEvent.text)
            case "interaction.completed":
                .completed(interactionID: event.interaction?.id)
            default:
                nil
            }
        }
    }

    // MARK: - TTS

    /// Streams headerless 16-bit little-endian PCM at 24 kHz mono.
    func streamSpeech(_ text: String, model: String, voice: String) throws -> AsyncThrowingStream<Data, Error> {
        let body: [String: Any] = [
            "model": model,
            "store": false,
            "input": [
                ["type": "user_input", "content": [["type": "text", "text": text]]],
            ],
            "response_format": ["type": "audio", "mime_type": "audio/l16", "sample_rate": 24_000],
            "generation_config": ["speech_config": [["voice": voice]]],
            "stream": true,
        ]
        let request = try makeRequest(url: Self.streamingInteractionsURL, body: body)
        return stream(request) { event in
            guard event.eventType == "step.delta",
                  event.delta?.type == "audio",
                  let encoded = event.delta?.data else { return nil }
            return Data(base64Encoded: encoded)
        }
    }

    // MARK: - Transport

    private func makeRequest(url: URL, body: [String: Any]) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func stream<Element: Sendable>(
        _ request: URLRequest,
        transform: @escaping @Sendable (StreamEvent) -> Element?
    ) -> AsyncThrowingStream<Element, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await Self.session.bytes(for: request)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        var body = Data()
                        for try await byte in bytes { body.append(byte) }
                        throw ClientError.http(status: http.statusCode, message: Self.errorMessage(from: body))
                    }

                    let decoder = JSONDecoder()
                    decoder.keyDecodingStrategy = .convertFromSnakeCase
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let event = try? decoder.decode(StreamEvent.self, from: Data(payload.utf8)) else { continue }
                        if event.eventType == "error" {
                            throw ClientError.server(event.error?.message ?? "Unknown streaming error")
                        }
                        if let element = transform(event) {
                            continuation.yield(element)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func validate(_ response: URLResponse, body: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            throw ClientError.http(status: http.statusCode, message: errorMessage(from: body))
        }
    }

    private static func errorMessage(from body: Data) -> String {
        if let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: body),
           let message = envelope.error.message {
            return message
        }
        return String(decoding: body.prefix(300), as: UTF8.self)
    }
}

// MARK: - Wire types

nonisolated private struct InteractionResponse: Decodable {
    struct Step: Decodable {
        let type: String
        let content: [Content]?
    }

    struct Content: Decodable {
        let type: String
        let text: String?
    }

    let steps: [Step]?

    var outputText: String {
        (steps ?? [])
            .filter { $0.type == "model_output" }
            .flatMap { $0.content ?? [] }
            .compactMap { $0.type == "text" ? $0.text : nil }
            .joined()
    }
}

nonisolated struct StreamEvent: Decodable, Sendable {
    struct Delta: Decodable, Sendable {
        let type: String?
        let text: String?
        let data: String?
    }

    struct Interaction: Decodable, Sendable {
        let id: String?
        let status: String?
    }

    struct Failure: Decodable, Sendable {
        let message: String?
    }

    let eventType: String?
    let delta: Delta?
    let interaction: Interaction?
    let error: Failure?
}

nonisolated private struct ErrorEnvelope: Decodable {
    struct Body: Decodable {
        let message: String?
    }

    let error: Body
}
