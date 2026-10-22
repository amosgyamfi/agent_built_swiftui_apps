import Foundation

nonisolated struct ModelOption: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let detail: String
}

nonisolated struct VoiceOption: Identifiable, Hashable, Sendable {
    let name: String
    let character: String

    var id: String { name }
}

nonisolated enum GeminiModels {
    static let transcription = ModelOption(
        id: "gemini-3.5-transcribe",
        name: "Gemini 3.5 Transcribe",
        detail: "Low-latency speech-to-text"
    )

    static let conversationOptions = [
        ModelOption(id: "gemini-3.8-flash", name: "Gemini 3.8 Flash", detail: "Most capable Flash model"),
        ModelOption(id: "gemini-3.6-flash", name: "Gemini 3.6 Flash", detail: "Previous-generation Flash"),
        ModelOption(id: "gemini-3.5-flash-lite", name: "Gemini 3.5 Flash-Lite", detail: "Fastest, lowest cost"),
    ]

    static let speechOptions = [
        ModelOption(id: "gemini-3.8-flash-lite-tts", name: "Gemini 3.8 Flash-Lite TTS", detail: "Built for real-time voice agents"),
        ModelOption(id: "gemini-3.8-flash-tts", name: "Gemini 3.8 Flash TTS", detail: "Highest fidelity, more expressive"),
    ]

    static let defaultConversationModel = conversationOptions[0].id
    static let defaultSpeechModel = speechOptions[0].id

    /// Gemini 3.8 Flash cannot go below `low`; the older Flash models accept `minimal`.
    static func thinkingLevel(for conversationModel: String) -> String {
        conversationModel.hasPrefix("gemini-3.8") ? "low" : "minimal"
    }

    static func name(for modelID: String) -> String {
        (conversationOptions + speechOptions + [transcription]).first { $0.id == modelID }?.name ?? modelID
    }

    static let voices = [
        VoiceOption(name: "Kore", character: "Firm"),
        VoiceOption(name: "Puck", character: "Upbeat"),
        VoiceOption(name: "Zephyr", character: "Bright"),
        VoiceOption(name: "Charon", character: "Informative"),
        VoiceOption(name: "Aoede", character: "Breezy"),
        VoiceOption(name: "Leda", character: "Youthful"),
        VoiceOption(name: "Achird", character: "Friendly"),
        VoiceOption(name: "Sulafat", character: "Warm"),
        VoiceOption(name: "Despina", character: "Smooth"),
        VoiceOption(name: "Iapetus", character: "Clear"),
    ]

    static let defaultVoice = "Kore"
}
