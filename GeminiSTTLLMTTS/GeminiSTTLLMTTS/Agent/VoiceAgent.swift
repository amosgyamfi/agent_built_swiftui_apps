import AVFoundation
import Foundation
import Observation

/// Runs the hands-free conversation loop: listen → transcribe → stream reply → speak → listen.
@Observable
final class VoiceAgent {
    enum Phase: Equatable {
        case idle, connecting, listening, transcribing, thinking, speaking
    }

    enum Role {
        case user, assistant
    }

    struct Message: Identifiable, Equatable {
        let id = UUID()
        let role: Role
        var text: String
        var wasInterrupted = false
    }

    struct TurnMetrics: Equatable {
        /// End of speech → transcript received.
        var transcription: Duration?
        /// LLM request sent → first text token.
        var firstToken: Duration?
        /// End of speech → first audio scheduled. This is the latency the user feels.
        var firstAudio: Duration?

        var isEmpty: Bool { transcription == nil && firstToken == nil && firstAudio == nil }
    }

    enum AgentError: LocalizedError {
        case microphoneDenied

        var errorDescription: String? {
            "Microphone access is off. Enable it in Settings to talk to Gemini."
        }
    }

    private enum DefaultsKey {
        static let voice = "voice"
        static let conversationModel = "conversationModel"
        static let speechModel = "speechModel"
    }

    static let systemInstruction = """
    You are Gemini, a warm, quick-witted voice assistant in a real-time spoken conversation. \
    Everything you write is converted to speech. Reply in one to three short, natural spoken sentences \
    unless the user explicitly asks for more detail. Lead with the answer. Never use markdown, bullet \
    points, numbered lists, emoji, code blocks, tables, or URLs. Write numbers, symbols, and abbreviations \
    the way a person would say them aloud. The user's words come from speech recognition, so if a request \
    is ambiguous or seems misheard, ask a brief clarifying question.
    """

    private(set) var phase: Phase = .idle
    private(set) var isSessionActive = false
    private(set) var messages: [Message] = []
    private(set) var metrics = TurnMetrics()
    private(set) var inputLevel: Float = 0
    private(set) var outputLevel: Float = 0
    private(set) var hasAPIKey: Bool
    private(set) var hasStoredAPIKey: Bool
    var errorMessage: String?

    var voice: String {
        didSet { UserDefaults.standard.set(voice, forKey: DefaultsKey.voice) }
    }

    var conversationModel: String {
        didSet { UserDefaults.standard.set(conversationModel, forKey: DefaultsKey.conversationModel) }
    }

    var speechModel: String {
        didSet { UserDefaults.standard.set(speechModel, forKey: DefaultsKey.speechModel) }
    }

    @ObservationIgnored private let capture = MicrophoneCapture()
    @ObservationIgnored private let player = PCMPlayer()
    @ObservationIgnored private var sessionTask: Task<Void, Never>?
    @ObservationIgnored private var sessionID: UUID?
    @ObservationIgnored private var turnTask: Task<Void, Error>?
    @ObservationIgnored private var meterTask: Task<Void, Never>?
    @ObservationIgnored private var previousInteractionID: String?

    init() {
        let defaults = UserDefaults.standard
        let voice = defaults.string(forKey: DefaultsKey.voice) ?? ""
        let conversationModel = defaults.string(forKey: DefaultsKey.conversationModel) ?? ""
        let speechModel = defaults.string(forKey: DefaultsKey.speechModel) ?? ""
        self.voice = GeminiModels.voices.contains { $0.name == voice } ? voice : GeminiModels.defaultVoice
        self.conversationModel = GeminiModels.conversationOptions.contains { $0.id == conversationModel }
            ? conversationModel : GeminiModels.defaultConversationModel
        self.speechModel = GeminiModels.speechOptions.contains { $0.id == speechModel }
            ? speechModel : GeminiModels.defaultSpeechModel
        hasAPIKey = APIKeyStore.resolvedKey() != nil
        hasStoredAPIKey = APIKeyStore.storedKey() != nil
    }

    // MARK: - Controls

    func start() {
        guard !isSessionActive else { return }
        errorMessage = nil
        isSessionActive = true
        let id = UUID()
        sessionID = id
        sessionTask = Task { await runSession(id: id) }
    }

    func end() {
        sessionTask?.cancel()
        turnTask?.cancel()
        tearDownSession()
    }

    /// Single-tap control on the orb: send what was said, or barge in on the reply.
    func orbTapped() {
        switch phase {
        case .idle:
            start()
        case .listening:
            capture.finishNow()
        case .transcribing, .thinking, .speaking:
            interrupt()
        case .connecting:
            break
        }
    }

    func interrupt() {
        turnTask?.cancel()
        player.stopPlayback()
    }

    func startNewConversation() {
        interrupt()
        messages.removeAll()
        metrics = TurnMetrics()
        previousInteractionID = nil
    }

    func saveAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        APIKeyStore.save(trimmed)
        refreshKeyState()
    }

    func removeAPIKey() {
        APIKeyStore.deleteStoredKey()
        refreshKeyState()
    }

    // MARK: - Session loop

    private func runSession(id: UUID) async {
        defer {
            if sessionID == id { tearDownSession() }
        }

        phase = .connecting
        do {
            guard let apiKey = APIKeyStore.resolvedKey() else { throw GeminiClient.ClientError.missingAPIKey }
            let client = GeminiClient(apiKey: apiKey)

            guard await AVAudioApplication.requestRecordPermission() else { throw AgentError.microphoneDenied }
            try configureAudioSession()
            try player.start()
            startOutputMetering()

            try await client.warmUp(model: conversationModel)

            var silentListens = 0
            while !Task.isCancelled {
                guard let wav = try await listen() else {
                    silentListens += 1
                    if silentListens >= 2 { break }
                    continue
                }
                silentListens = 0

                let turn = Task { try await self.respond(to: wav, client: client) }
                turnTask = turn
                do {
                    try await turn.value
                } catch where turn.isCancelled {
                    // The user barged in; go straight back to listening.
                }
                turnTask = nil
            }
        } catch is CancellationError {
        } catch where Task.isCancelled {
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func listen() async throws -> Data? {
        phase = .listening
        let events = try capture.start()
        defer {
            capture.stop()
            inputLevel = 0
        }
        for await event in events {
            switch event {
            case .level(let level):
                inputLevel = level
            case .speechStarted:
                break
            case .utterance(let wav):
                return wav
            case .noSpeech:
                return nil
            }
        }
        try Task.checkCancellation()
        return nil
    }

    private func respond(to wav: Data, client: GeminiClient) async throws {
        let clock = ContinuousClock()
        let speechEnded = clock.now
        metrics = TurnMetrics()

        phase = .transcribing
        let transcript = try await client.transcribe(wav: wav, model: GeminiModels.transcription.id)
        metrics.transcription = clock.now - speechEnded
        try Task.checkCancellation()
        guard !transcript.isEmpty else { return }
        messages.append(Message(role: .user, text: transcript))

        phase = .thinking
        let reply = Message(role: .assistant, text: "")
        messages.append(reply)

        let (segments, segmentSink) = AsyncStream.makeStream(of: AsyncThrowingStream<Data, Error>.self)
        var synthesisTasks: [Task<Void, Never>] = []
        defer {
            segmentSink.finish()
            synthesisTasks.forEach { $0.cancel() }
        }

        let voice = voice
        let speechModel = speechModel
        // Each sentence gets its own streaming TTS request immediately, so later sentences
        // synthesize while earlier ones play. Playback consumes them strictly in order.
        func speak(_ sentence: String) {
            let text = SpeechText.speakable(sentence)
            guard !text.isEmpty else { return }
            let (audio, sink) = AsyncThrowingStream.makeStream(of: Data.self)
            synthesisTasks.append(Task.detached(priority: .userInitiated) {
                do {
                    for try await chunk in try client.streamSpeech(text, model: speechModel, voice: voice) {
                        sink.yield(chunk)
                    }
                    sink.finish()
                } catch {
                    sink.finish(throwing: error)
                }
            })
            segmentSink.yield(audio)
        }

        async let playback: Void = play(segments, speechEnded: speechEnded)

        do {
            var chunker = SentenceChunker()
            var replyText = ""
            let requestSent = clock.now
            let stream = try client.streamReply(
                to: transcript,
                model: conversationModel,
                systemInstruction: Self.systemInstruction,
                previousInteractionID: previousInteractionID
            )
            for try await event in stream {
                switch event {
                case .text(let delta):
                    if metrics.firstToken == nil {
                        metrics.firstToken = clock.now - requestSent
                    }
                    replyText += delta
                    updateMessage(reply.id) { $0.text = replyText }
                    chunker.append(delta).forEach(speak)
                case .completed(let interactionID):
                    if let interactionID {
                        previousInteractionID = interactionID
                    }
                }
            }
            try Task.checkCancellation()
            if let tail = chunker.flush() {
                speak(tail)
            }
            segmentSink.finish()
            try await playback
        } catch {
            if Task.isCancelled {
                markInterrupted(reply.id)
            }
            throw error
        }
    }

    private func play(
        _ segments: AsyncStream<AsyncThrowingStream<Data, Error>>,
        speechEnded: ContinuousClock.Instant
    ) async throws {
        for await segment in segments {
            var carry = Data()
            for try await chunk in segment {
                var pcm = carry
                pcm.append(chunk)
                // Network chunks are not guaranteed to split on 16-bit sample boundaries.
                if pcm.count.isMultiple(of: 2) {
                    carry.removeAll()
                } else {
                    carry = Data([pcm.removeLast()])
                }
                guard !pcm.isEmpty else { continue }

                if metrics.firstAudio == nil {
                    metrics.firstAudio = ContinuousClock.now - speechEnded
                }
                if phase != .speaking {
                    phase = .speaking
                }
                try player.enqueue(pcm)
            }
        }
        try Task.checkCancellation()
        let player = player
        await withTaskCancellationHandler {
            await player.waitUntilIdle()
        } onCancel: {
            player.stopPlayback()
        }
    }

    // MARK: - Helpers

    private func updateMessage(_ id: UUID, _ change: (inout Message) -> Void) {
        guard let index = messages.lastIndex(where: { $0.id == id }) else { return }
        change(&messages[index])
    }

    private func markInterrupted(_ id: UUID) {
        guard let index = messages.lastIndex(where: { $0.id == id }) else { return }
        if messages[index].text.isEmpty {
            messages.remove(at: index)
        } else {
            messages[index].wasInterrupted = true
        }
    }

    private func refreshKeyState() {
        hasAPIKey = APIKeyStore.resolvedKey() != nil
        hasStoredAPIKey = APIKeyStore.storedKey() != nil
    }

    private func startOutputMetering() {
        guard meterTask == nil else { return }
        let levels = player.levels
        meterTask = Task { [weak self] in
            for await level in levels {
                guard let self else { return }
                let level = self.phase == .speaking ? level : 0
                if abs(level - self.outputLevel) > 0.02 {
                    self.outputLevel = level
                }
            }
        }
    }

    private func tearDownSession() {
        sessionTask = nil
        sessionID = nil
        turnTask = nil
        capture.stop()
        player.shutdown()
        deactivateAudioSession()
        phase = .idle
        isSessionActive = false
        inputLevel = 0
        outputLevel = 0
    }

    private func configureAudioSession() throws {
        #if os(iOS) || os(visionOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .default,
            options: [.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP]
        )
        try session.setPreferredIOBufferDuration(0.01)
        try session.setActive(true)
        #endif
    }

    private func deactivateAudioSession() {
        #if os(iOS) || os(visionOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}
