import AVFoundation
import Foundation

enum RecordingError: LocalizedError {
    case alreadyRecording
    case notRecording
    case unsupportedFormat
    case conversionFailed
    case noAudio

    var errorDescription: String? {
        switch self {
        case .alreadyRecording: "Already recording"
        case .notRecording: "No recording in progress"
        case .unsupportedFormat: "Microphone format unsupported"
        case .conversionFailed: "Audio conversion failed"
        case .noAudio: "No microphone audio captured"
        }
    }
}

final class AudioRecorder {
    /// Converts tap buffers to 16 kHz mono Int16. While recording, samples go into the recording;
    /// otherwise (warm) into the pre-roll buffer.
    private final class Capture {
        private let lock = NSLock()
        private let callbacks = DispatchGroup()
        private let converter: AVAudioConverter
        private let outputFormat: AVAudioFormat
        private let inputRate: Double
        private let onLevel: @Sendable (Double) -> Void
        private var bytes: Data?
        private var preRoll = PreRollBuffer(capacitySamples: AudioRecorder.preRollSamples)
        private var failed = false
        private var finished = false

        init(
            converter: AVAudioConverter,
            outputFormat: AVAudioFormat,
            inputRate: Double,
            onLevel: @escaping @Sendable (Double) -> Void
        ) {
            self.converter = converter
            self.outputFormat = outputFormat
            self.inputRate = inputRate
            self.onLevel = onLevel
        }

        var isRecording: Bool { lock.withLock { bytes != nil } }
        var hasFailed: Bool { lock.withLock { failed } }

        func receive(_ buffer: AVAudioPCMBuffer) {
            callbacks.enter()
            defer { callbacks.leave() }
            lock.lock()
            defer { lock.unlock() }
            guard !finished, !failed else { return }
            let capacity = AVAudioFrameCount(max(
                1_024,
                Int((Double(buffer.frameLength) * outputFormat.sampleRate / inputRate).rounded(.up)) + 64
            ))
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
                failed = true
                return
            }
            var supplied = false
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                if supplied {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                supplied = true
                inputStatus.pointee = .haveData
                return buffer
            }
            if conversionError != nil || status == .error {
                failed = true
                return
            }
            if bytes == nil {
                if output.frameLength > 0, let samples = output.int16ChannelData?[0] {
                    preRoll.append(Array(UnsafeBufferPointer(start: samples, count: Int(output.frameLength))))
                }
                return
            }
            if let level = Self.level(from: output) { onLevel(level) }
            append(output)
        }

        /// Starts recording, beginning with the pre-roll gathered while warm.
        func begin() {
            lock.lock()
            defer { lock.unlock() }
            bytes = preRoll.snapshot().withUnsafeBufferPointer { Data(buffer: $0) }
            preRoll.removeAll()
        }

        /// Ends the recording while the engine keeps running.
        func end() throws -> Data {
            lock.lock()
            defer { lock.unlock() }
            let recorded = bytes ?? Data()
            bytes = nil
            if failed { throw RecordingError.conversionFailed }
            if recorded.isEmpty { throw RecordingError.noAudio }
            return recorded
        }

        /// The engine stopped under a recording; the take is incomplete.
        func markFailed() {
            lock.withLock { failed = true }
        }

        func discard() {
            lock.withLock { bytes = nil }
        }

        func finish() throws -> Data {
            // The engine has stopped; finish any tap conversion before flushing its tail.
            callbacks.wait()
            lock.lock()
            defer { lock.unlock() }
            finished = true
            if failed { throw RecordingError.conversionFailed }
            while true {
                guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 1_024) else {
                    throw RecordingError.conversionFailed
                }
                var conversionError: NSError?
                let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                if conversionError != nil || status == .error { throw RecordingError.conversionFailed }
                append(output)
                if status == .endOfStream { break }
                guard status == .haveData, output.frameLength > 0 else { throw RecordingError.conversionFailed }
            }
            guard let bytes, !bytes.isEmpty else { throw RecordingError.noAudio }
            return bytes
        }

        private func append(_ output: AVAudioPCMBuffer) {
            if output.frameLength > 0, let samples = output.int16ChannelData?[0] {
                bytes?.append(Data(bytes: samples, count: Int(output.frameLength) * MemoryLayout<Int16>.size))
            }
        }

        private static func level(from buffer: AVAudioPCMBuffer) -> Double? {
            guard buffer.frameLength > 0, let samples = buffer.int16ChannelData?[0] else { return nil }
            let count = Int(buffer.frameLength)
            var sumOfSquares = 0.0
            for index in 0..<count {
                let sample = Double(samples[index]) / 32_768
                sumOfSquares += sample * sample
            }
            let rms = sqrt(sumOfSquares / Double(count))
            let decibels = 20 * log10(max(rms, 1e-9))
            return min(1, max(0, (decibels + 60) / 50))
        }
    }

    static let preRollSamples = 12_000

    private let onLevel: @Sendable (Double) -> Void
    private var engine: AVAudioEngine?
    private var capture: Capture?
    private var configurationObserver: NSObjectProtocol?
    /// Called on the main queue when a warm engine was shut down by a device change.
    var onCooledDown: () -> Void = {}

    init(onLevel: @escaping @Sendable (Double) -> Void = { _ in }) {
        self.onLevel = onLevel
    }

    /// The engine is running between recordings, filling the pre-roll.
    var isWarm: Bool { engine?.isRunning == true && capture?.isRecording == false }
    var isRecording: Bool { capture?.isRecording == true }

    func start() throws {
        if let engine, let capture {
            guard !capture.isRecording else { throw RecordingError.alreadyRecording }
            if engine.isRunning && !capture.hasFailed {
                capture.begin()
                return
            }
            tearDown()
        }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0,
              let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                channels: 1, interleaved: false
              ),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else { throw RecordingError.unsupportedFormat }

        let capture = Capture(
            converter: converter, outputFormat: outputFormat,
            inputRate: inputFormat.sampleRate, onLevel: onLevel
        )
        capture.begin()
        input.installTap(onBus: 0, bufferSize: 4_096, format: inputFormat) { buffer, _ in
            capture.receive(buffer)
        }
        do {
            try engine.start()
            self.engine = engine
            self.capture = capture
            configurationObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
            ) { [weak self] _ in
                guard let self, let capture = self.capture else { return }
                if capture.isRecording {
                    // stop() throws and tears down.
                    capture.markFailed()
                } else {
                    self.tearDown()
                    self.onCooledDown()
                }
            }
        } catch {
            input.removeTap(onBus: 0)
            engine.stop()
            throw error
        }
    }

    /// With `keepWarm`, the engine keeps running afterwards and fills the pre-roll.
    func stop(keepWarm: Bool = false) throws -> Data {
        guard let capture, capture.isRecording else { throw RecordingError.notRecording }
        if keepWarm {
            do {
                return WAV.encode(pcm16: try capture.end())
            } catch RecordingError.noAudio {
                throw RecordingError.noAudio
            } catch {
                tearDown()
                throw error
            }
        }
        tearDown()
        return WAV.encode(pcm16: try capture.finish())
    }

    func cancel(keepWarm: Bool = false) {
        guard let capture, capture.isRecording else { return }
        if keepWarm && !capture.hasFailed { capture.discard() }
        else { tearDown() }
    }

    /// Stops a warm engine; a running recording is left alone.
    func coolDown() {
        guard !isRecording else { return }
        tearDown()
    }

    private func tearDown() {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        capture = nil
    }
}
