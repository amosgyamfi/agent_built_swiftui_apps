import AVFoundation

nonisolated extension AVAudioNode {
    /// Throwing tap installation. The iOS 27 SDK exposes the error-returning variant only as a refined-for-Swift symbol.
    func installTapOrThrow(
        onBus bus: AVAudioNodeBus,
        bufferSize: AVAudioFrameCount,
        format: AVAudioFormat?,
        block: @escaping AVAudioNodeTapBlock
    ) throws {
        try __installTap(onBus: bus, bufferSize: bufferSize, format: format, error: (), block: block)
    }
}
