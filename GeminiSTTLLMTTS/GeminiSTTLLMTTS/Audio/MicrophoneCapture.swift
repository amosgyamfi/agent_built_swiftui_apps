import AVFoundation

/// Captures microphone audio as 16 kHz mono PCM and ends the utterance with energy-based voice activity detection.
nonisolated final class MicrophoneCapture: @unchecked Sendable {
    enum Event: Sendable {
        case level(Float)
        case speechStarted
        case utterance(wav: Data)
        case noSpeech
    }

    enum CaptureError: LocalizedError {
        case inputUnavailable

        var errorDescription: String? { "No microphone input is available." }
    }

    struct VoiceActivity {
        /// Absolute floor for speech so quiet rooms don't trigger on breathing.
        var minimumSpeechDB: Float = -48
        /// How far above the tracked noise floor a frame must be to count as speech.
        var speechMarginDB: Float = 12
        var minimumSpeech: TimeInterval = 0.15
        var endOfSpeechSilence: TimeInterval = 0.7
        var preRoll: TimeInterval = 0.4
        var maximumUtterance: TimeInterval = 30
        var noSpeechTimeout: TimeInterval = 15
    }

    static let sampleRate = 16_000.0

    var voiceActivity = VoiceActivity()

    private let engine = AVAudioEngine()
    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: MicrophoneCapture.sampleRate,
        channels: 1,
        interleaved: true
    )!
    private let lock = NSLock()

    // Guarded by `lock`; mutated from the realtime tap.
    private var continuation: AsyncStream<Event>.Continuation?
    private var converter: AVAudioConverter?
    private var pcm = Data()
    private var heardSpeech = false
    private var speechRun: TimeInterval = 0
    private var silenceRun: TimeInterval = 0
    private var elapsed: TimeInterval = 0
    private var utteranceDuration: TimeInterval = 0
    private var noiseFloorDB: Float = -55

    func start() throws -> AsyncStream<Event> {
        stop()

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw CaptureError.inputUnavailable
        }

        let (stream, continuation) = AsyncStream.makeStream(of: Event.self)
        lock.withLock {
            self.continuation = continuation
            self.converter = converter
            pcm = Data()
            heardSpeech = false
            speechRun = 0
            silenceRun = 0
            elapsed = 0
            utteranceDuration = 0
            noiseFloorDB = -55
        }

        do {
            try input.installTapOrThrow(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
                self?.process(buffer)
            }
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            lock.withLock { self.continuation = nil }
            throw error
        }
        return stream
    }

    /// Ends the current utterance immediately, e.g. when the user taps "done".
    func finishNow() {
        lock.withLock { finishLocked() }
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning {
            engine.stop()
        }
        lock.withLock {
            continuation?.finish()
            continuation = nil
            converter = nil
        }
    }

    // MARK: - Realtime processing

    private func process(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard let converter, let continuation else { return }

        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }

        var supplied = false
        var conversionError: NSError?
        converter.convert(to: converted, error: &conversionError) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard conversionError == nil, converted.frameLength > 0,
              let samples = converted.int16ChannelData?[0] else { return }

        let frameCount = Int(converted.frameLength)
        let duration = Double(frameCount) / outputFormat.sampleRate
        let levelDB = Self.rmsDB(samples, count: frameCount)
        continuation.yield(.level(Self.normalizedLevel(levelDB)))

        pcm.append(Data(bytes: samples, count: frameCount * MemoryLayout<Int16>.size))
        elapsed += duration
        if heardSpeech { utteranceDuration += duration }

        let threshold = max(voiceActivity.minimumSpeechDB, noiseFloorDB + voiceActivity.speechMarginDB)
        if levelDB > threshold {
            speechRun += duration
            silenceRun = 0
            if !heardSpeech, speechRun >= voiceActivity.minimumSpeech {
                heardSpeech = true
                utteranceDuration = speechRun
                continuation.yield(.speechStarted)
            }
        } else {
            silenceRun += duration
            if !heardSpeech { speechRun = 0 }
            // Fall quickly toward quieter frames, rise slowly so steady background noise is learned.
            let rate: Float = levelDB < noiseFloorDB ? 0.3 : 0.02
            noiseFloorDB += (levelDB - noiseFloorDB) * rate
        }

        if !heardSpeech {
            trimToPreRoll()
            if elapsed >= voiceActivity.noSpeechTimeout { finishLocked() }
            return
        }

        if silenceRun >= voiceActivity.endOfSpeechSilence || utteranceDuration >= voiceActivity.maximumUtterance {
            finishLocked()
        }
    }

    private func finishLocked() {
        guard let continuation else { return }
        if heardSpeech {
            trimTrailingSilence()
            continuation.yield(.utterance(wav: WAVEncoder.wav(fromPCM16: pcm, sampleRate: Int(outputFormat.sampleRate))))
        } else {
            continuation.yield(.noSpeech)
        }
        continuation.finish()
        self.continuation = nil
    }

    private func trimToPreRoll() {
        let keep = byteCount(for: voiceActivity.preRoll)
        if pcm.count > keep {
            pcm = Data(pcm.suffix(keep))
        }
    }

    private func trimTrailingSilence() {
        let excess = byteCount(for: max(0, silenceRun - 0.2))
        if excess > 0, pcm.count > excess {
            pcm.removeLast(excess)
        }
    }

    private func byteCount(for seconds: TimeInterval) -> Int {
        Int(seconds * outputFormat.sampleRate) * MemoryLayout<Int16>.size
    }

    private static func rmsDB(_ samples: UnsafePointer<Int16>, count: Int) -> Float {
        var sum: Float = 0
        for index in 0..<count {
            let sample = Float(samples[index]) / Float(Int16.max)
            sum += sample * sample
        }
        let rms = (sum / Float(max(count, 1))).squareRoot()
        return 20 * log10(max(rms, 1e-6))
    }

    private static func normalizedLevel(_ db: Float) -> Float {
        min(max((db + 60) / 50, 0), 1)
    }
}

nonisolated enum WAVEncoder {
    static func wav(fromPCM16 pcm: Data, sampleRate: Int, channels: Int = 1) -> Data {
        var data = Data(capacity: 44 + pcm.count)
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let bytesPerSample = 2
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + pcm.count))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(channels))
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * channels * bytesPerSample))
        append(UInt16(channels * bytesPerSample))
        append(UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(pcm.count))
        data.append(pcm)
        return data
    }
}
