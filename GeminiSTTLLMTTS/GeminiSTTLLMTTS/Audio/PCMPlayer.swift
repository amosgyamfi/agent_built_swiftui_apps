import AVFoundation

/// Plays streamed 24 kHz 16-bit PCM chunks back-to-back as soon as they arrive.
nonisolated final class PCMPlayer: @unchecked Sendable {
    static let sampleRate = 24_000.0

    let levels: AsyncStream<Float>

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: PCMPlayer.sampleRate, channels: 1)!
    private let levelContinuation: AsyncStream<Float>.Continuation
    private let lock = NSLock()

    // Guarded by `lock`.
    private var pendingBuffers = 0
    private var generation = 0
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var wantsRunning = false
    private var isGraphReady = false
    private var configurationObserver: NSObjectProtocol?

    init() {
        (levels, levelContinuation) = AsyncStream.makeStream(of: Float.self, bufferingPolicy: .bufferingNewest(1))
        engine.attach(node)
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.restartAfterConfigurationChange()
        }
    }

    deinit {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
    }

    func start() throws {
        lock.withLock { wantsRunning = true }
        try prepareGraphIfNeeded()
        guard !engine.isRunning else { return }
        engine.prepare()
        try engine.start()
    }

    func shutdown() {
        lock.withLock { wantsRunning = false }
        stopPlayback()
        engine.stop()
    }

    func enqueue(_ pcm: Data) throws {
        guard let buffer = makeBuffer(pcm) else { return }
        do {
            if !engine.isRunning {
                try engine.start()
            }
            let bufferGeneration = lock.withLock {
                pendingBuffers += 1
                return generation
            }
            node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                self?.bufferFinished(generation: bufferGeneration)
            }
            if !node.isPlaying {
                try node.playAudio()
            }
        } catch {
            stopPlayback()
            throw error
        }
    }

    /// Suspends until every scheduled buffer has been heard (or playback was stopped).
    func waitUntilIdle() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if pendingBuffers == 0 {
                lock.unlock()
                continuation.resume()
            } else {
                idleWaiters.append(continuation)
                lock.unlock()
            }
        }
    }

    /// Drops all queued audio immediately (used for interruptions).
    func stopPlayback() {
        let waiters = lock.withLock {
            generation += 1
            pendingBuffers = 0
            defer { idleWaiters.removeAll() }
            return idleWaiters
        }
        node.stop()
        waiters.forEach { $0.resume() }
        levelContinuation.yield(0)
    }

    private func bufferFinished(generation bufferGeneration: Int) {
        let waiters: [CheckedContinuation<Void, Never>] = lock.withLock {
            guard bufferGeneration == generation, pendingBuffers > 0 else { return [] }
            pendingBuffers -= 1
            guard pendingBuffers == 0 else { return [] }
            defer { idleWaiters.removeAll() }
            return idleWaiters
        }
        waiters.forEach { $0.resume() }
    }

    /// Connects the player and installs the output meter once; both can fail on iOS 27+.
    private func prepareGraphIfNeeded() throws {
        guard !lock.withLock({ isGraphReady }) else { return }
        try engine.connectNode(node, to: engine.mainMixerNode, format: format)
        let continuation = levelContinuation
        try engine.mainMixerNode.installTapOrThrow(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
            guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
            var sum: Float = 0
            for index in 0..<Int(buffer.frameLength) {
                sum += samples[index] * samples[index]
            }
            let rms = (sum / Float(buffer.frameLength)).squareRoot()
            let db = 20 * log10(max(rms, 1e-6))
            continuation.yield(min(max((db + 55) / 45, 0), 1))
        }
        lock.withLock { isGraphReady = true }
    }

    private func restartAfterConfigurationChange() {
        guard lock.withLock({ wantsRunning }), !engine.isRunning else { return }
        try? engine.start()
    }

    private func makeBuffer(_ pcm: Data) -> AVAudioPCMBuffer? {
        let frameCount = pcm.count / MemoryLayout<Int16>.size
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)),
              let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        pcm.withUnsafeBytes { raw in
            for index in 0..<frameCount {
                let sample = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self))
                channel[index] = Float(sample) / 32_768
            }
        }
        return buffer
    }
}
