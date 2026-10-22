import SwiftUI

struct ContentView: View {
    @State private var agent = VoiceAgent()
    @State private var isShowingSettings = false

    private var pipeline: [String] {
        [
            GeminiModels.transcription.name,
            GeminiModels.name(for: agent.conversationModel),
            GeminiModels.name(for: agent.speechModel),
        ]
    }

    private var orbLevel: Float {
        agent.phase == .speaking ? agent.outputLevel : agent.inputLevel
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TranscriptView(
                    messages: agent.messages,
                    pipeline: pipeline,
                    hasAPIKey: agent.hasAPIKey,
                    onAddAPIKey: { isShowingSettings = true }
                )
                .frame(maxHeight: .infinity)

                controlPanel
            }
            .navigationTitle("Gemini Voice")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Settings", systemImage: "gearshape") {
                        isShowingSettings = true
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("New Conversation", systemImage: "square.and.pencil") {
                        agent.startNewConversation()
                    }
                    .disabled(agent.messages.isEmpty)
                }
            }
            .sheet(isPresented: $isShowingSettings) {
                SettingsView(agent: agent)
            }
        }
    }

    private var controlPanel: some View {
        VStack(spacing: 14) {
            Button {
                agent.orbTapped()
            } label: {
                OrbView(phase: agent.phase, level: orbLevel)
                    .frame(width: 150, height: 150)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .disabled(!agent.isSessionActive || agent.phase == .connecting)
            .accessibilityLabel(agent.phase.orbAccessibilityLabel)
            .accessibilityValue(agent.phase.title)

            VStack(spacing: 4) {
                Text(agent.phase.title)
                    .font(.headline)
                Text(agent.phase.hint)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .animation(.smooth, value: agent.phase)

            if !agent.metrics.isEmpty {
                LatencyView(metrics: agent.metrics)
                    .transition(.opacity)
            }

            if let errorMessage = agent.errorMessage {
                errorBanner(errorMessage)
            }

            primaryButton
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .frame(maxWidth: 560)
        .animation(.smooth, value: agent.metrics.isEmpty)
        .animation(.smooth, value: agent.errorMessage)
    }

    @ViewBuilder
    private var primaryButton: some View {
        if agent.isSessionActive {
            Button(role: .destructive) {
                agent.end()
            } label: {
                Label("End Conversation", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
        } else {
            Button {
                if agent.hasAPIKey {
                    agent.start()
                } else {
                    isShowingSettings = true
                }
            } label: {
                Label("Start Conversation", systemImage: "mic.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Dismiss", systemImage: "xmark") {
                agent.errorMessage = nil
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
        }
        .padding(12)
        .background(.orange.opacity(0.12), in: .rect(cornerRadius: 12))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

#Preview {
    ContentView()
}
