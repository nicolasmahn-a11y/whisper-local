import Foundation

enum WAV {
    static func encode(pcm16: Data, sampleRate: UInt32 = 16_000) -> Data {
        var wav = Data(capacity: 44 + pcm16.count)
        wav.append(contentsOf: "RIFF".utf8)
        wav.appendLittleEndian(UInt32(36 + pcm16.count))
        wav.append(contentsOf: "WAVEfmt ".utf8)
        wav.appendLittleEndian(UInt32(16))
        wav.appendLittleEndian(UInt16(1))
        wav.appendLittleEndian(UInt16(1))
        wav.appendLittleEndian(sampleRate)
        wav.appendLittleEndian(sampleRate * 2)
        wav.appendLittleEndian(UInt16(2))
        wav.appendLittleEndian(UInt16(16))
        wav.append(contentsOf: "data".utf8)
        wav.appendLittleEndian(UInt32(pcm16.count))
        wav.append(pcm16)
        return wav
    }

    /// Seconds of audio in a WAV produced by `encode` (16 kHz mono PCM16, 44-byte header).
    /// Returns 0 for data shorter than the header.
    static func duration(of wav: Data, sampleRate: UInt32 = 16_000) -> TimeInterval {
        duration(byteCount: wav.count, sampleRate: sampleRate)
    }

    static func duration(byteCount: Int, sampleRate: UInt32 = 16_000) -> TimeInterval {
        guard byteCount > 44, sampleRate > 0 else { return 0 }
        return TimeInterval(byteCount - 44) / (TimeInterval(sampleRate) * 2)
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
