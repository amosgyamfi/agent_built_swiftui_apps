import SwiftUI

struct OrbView: View {
    let phase: VoiceAgent.Phase
    let level: Float

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isWorking: Bool {
        phase == .connecting || phase == .transcribing || phase == .thinking
    }

    var body: some View {
        TimelineView(.animation(paused: reduceMotion || phase == .idle)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let breathing = reduceMotion ? 0 : CGFloat(sin(time * 2.2)) * 0.025
            let energy = CGFloat(level)

            ZStack {
                Circle()
                    .fill(phase.tint.gradient)
                    .opacity(0.18 + Double(energy) * 0.2)
                    .scaleEffect(reduceMotion ? 1 : 0.86 + energy * 0.32 + breathing)

                Circle()
                    .fill(phase.tint.gradient)
                    .opacity(0.28)
                    .scaleEffect(reduceMotion ? 0.82 : 0.74 + energy * 0.18 + breathing / 2)

                if isWorking {
                    Circle()
                        .trim(from: 0, to: 0.28)
                        .stroke(phase.tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(reduceMotion ? 0 : time.truncatingRemainder(dividingBy: 1.2) / 1.2 * 360))
                        .scaleEffect(0.8)
                }

                Circle()
                    .fill(phase.tint.gradient)
                    .scaleEffect(0.62)
                    .shadow(color: phase.tint.opacity(0.45), radius: 18, y: 6)

                Image(systemName: phase.symbol)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        .animation(.smooth(duration: 0.12), value: level)
        .animation(.smooth, value: phase)
    }
}

extension VoiceAgent.Phase {
    var tint: Color {
        switch self {
        case .idle: .gray
        case .connecting: .gray
        case .listening: .blue
        case .transcribing: .indigo
        case .thinking: .purple
        case .speaking: .teal
        }
    }

    var symbol: String {
        switch self {
        case .idle: "waveform"
        case .connecting: "antenna.radiowaves.left.and.right"
        case .listening: "mic.fill"
        case .transcribing: "text.quote"
        case .thinking: "sparkles"
        case .speaking: "speaker.wave.2.fill"
        }
    }

    var title: String {
        switch self {
        case .idle: "Ready"
        case .connecting: "Connecting…"
        case .listening: "Listening…"
        case .transcribing: "Transcribing…"
        case .thinking: "Thinking…"
        case .speaking: "Speaking…"
        }
    }

    var hint: String {
        switch self {
        case .idle: "Start a conversation and talk naturally."
        case .connecting: "Warming up the connection to Gemini."
        case .listening: "Pause when you're done, or tap the orb to send."
        case .transcribing, .thinking, .speaking: "Tap the orb to interrupt."
        }
    }

    var orbAccessibilityLabel: String {
        switch self {
        case .listening: "Send what I said"
        case .transcribing, .thinking, .speaking: "Interrupt Gemini"
        case .idle, .connecting: "Voice status"
        }
    }
}

#Preview {
    HStack(spacing: 24) {
        OrbView(phase: .listening, level: 0.5)
        OrbView(phase: .thinking, level: 0)
        OrbView(phase: .speaking, level: 0.8)
    }
    .frame(height: 140)
    .padding()
}
