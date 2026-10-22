import SwiftUI

struct TranscriptView: View {
    let messages: [VoiceAgent.Message]
    let pipeline: [String]
    let hasAPIKey: Bool
    let onAddAPIKey: () -> Void

    var body: some View {
        if messages.isEmpty {
            emptyState
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(messages) { message in
                            MessageBubble(message: message)
                                .id(message.id)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: messages.last?.text) {
                    guard let last = messages.last else { return }
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private var emptyState: some View {
        ScrollView {
            VStack(spacing: 18) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.tint)
                    .symbolRenderingMode(.hierarchical)

                VStack(spacing: 8) {
                    Text("Talk with Gemini")
                        .font(.title2.bold())
                    Text("Your speech is transcribed, answered, and spoken back sentence by sentence while the reply is still streaming.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                PipelineView(stages: pipeline)

                if !hasAPIKey {
                    Button("Add Gemini API Key", systemImage: "key.fill", action: onAddAPIKey)
                        .buttonStyle(.bordered)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 40)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
    }
}

private struct PipelineView: View {
    let stages: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(zip(["Speech-to-text", "Language model", "Text-to-speech"], stages)), id: \.0) { role, model in
                HStack(spacing: 12) {
                    Text(role)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 110, alignment: .leading)
                    Text(model)
                        .font(.subheadline.weight(.medium))
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.tertiary, in: .rect(cornerRadius: 14))
    }
}

private struct MessageBubble: View {
    let message: VoiceAgent.Message

    private var isUser: Bool { message.role == .user }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 48) }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                Group {
                    if message.text.isEmpty {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.vertical, 2)
                    } else {
                        Text(message.text)
                            .textSelection(.enabled)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .foregroundStyle(isUser ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .background(
                    isUser ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.fill.secondary),
                    in: .rect(cornerRadius: 18)
                )

                if message.wasInterrupted {
                    Label("Interrupted", systemImage: "hand.raised.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if !isUser { Spacer(minLength: 48) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(isUser ? "You" : "Gemini"): \(message.text)")
    }
}
