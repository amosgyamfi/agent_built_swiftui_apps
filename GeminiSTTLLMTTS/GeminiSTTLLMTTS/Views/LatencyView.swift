import SwiftUI

struct LatencyView: View {
    let metrics: VoiceAgent.TurnMetrics

    var body: some View {
        HStack(spacing: 0) {
            metric("Transcribe", metrics.transcription)
            Divider().frame(height: 28)
            metric("First token", metrics.firstToken)
            Divider().frame(height: 28)
            metric("Voice to voice", metrics.firstAudio)
        }
        .padding(.vertical, 8)
        .background(.fill.tertiary, in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }

    private func metric(_ title: String, _ duration: Duration?) -> some View {
        VStack(spacing: 2) {
            Text(duration.map(Self.format) ?? "—")
                .font(.callout.weight(.semibold).monospacedDigit())
                .contentTransition(.numericText())
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .animation(.smooth, value: duration)
    }

    nonisolated private static func format(_ duration: Duration) -> String {
        let milliseconds = Int((duration / .milliseconds(1)).rounded())
        return milliseconds < 1000
            ? "\(milliseconds) ms"
            : (Double(milliseconds) / 1000).formatted(.number.precision(.fractionLength(2))) + " s"
    }
}

#Preview {
    LatencyView(metrics: .init(
        transcription: .milliseconds(412),
        firstToken: .milliseconds(388),
        firstAudio: .milliseconds(1240)
    ))
    .padding()
}
