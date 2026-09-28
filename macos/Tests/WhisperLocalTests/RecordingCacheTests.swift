#if canImport(Testing)
import Testing
import Foundation
@testable import WhisperLocal

/// Mutable box so tests can advance "now" between calls.
private final class Clock: @unchecked Sendable {
    var date: Date
    init(_ date: Date) { self.date = date }
    func now() -> Date { date }
}

private func makeTempDirectory() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("RecordingCacheTests-\(UUID().uuidString)")
    return dir
}

private func withCache(
    startingAt date: Date = Date(timeIntervalSince1970: 1_700_000_000),
    _ body: (RecordingCache, Clock, URL) throws -> Void
) rethrows {
    let dir = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let clock = Clock(date)
    let cache = RecordingCache(directory: dir, now: clock.now)
    try body(cache, clock, dir)
}

private func pcm(seconds: Double, sampleRate: UInt32 = 16_000) -> Data {
    Data(count: Int(seconds * Double(sampleRate) * 2))
}

struct RecordingCacheTests {
    @Test func saveRecordingsRoundTrip() throws {
        try withCache { cache, clock, dir in
            let wav = WAV.encode(pcm16: pcm(seconds: 2))
            let entry = try cache.save(wav)

            #expect(entry.url.deletingLastPathComponent().standardizedFileURL.path == dir.standardizedFileURL.path)
            #expect(entry.url.lastPathComponent == "\(entry.id).wav")

            let entryMs = Int(entry.recordedAt.timeIntervalSince1970 * 1000)
            let expectedMs = Int(clock.date.timeIntervalSince1970 * 1000)
            #expect(entryMs == expectedMs)

            #expect(entry.duration == 2.0)

            let all = cache.recordings()
            #expect(all == [entry])
        }
    }

    @Test func newestFirstOrdering() throws {
        try withCache { cache, clock, _ in
            let wav = WAV.encode(pcm16: pcm(seconds: 1))

            clock.date = Date(timeIntervalSince1970: 1_700_000_000)
            let first = try cache.save(wav)

            clock.date = Date(timeIntervalSince1970: 1_700_000_100)
            let second = try cache.save(wav)

            clock.date = Date(timeIntervalSince1970: 1_700_000_200)
            let third = try cache.save(wav)

            #expect(cache.recordings() == [third, second, first])
        }
    }

    @Test func expiryKeepsAtExactlyRetentionBoundary() throws {
        try withCache { cache, clock, _ in
            let start = clock.date
            let wav = WAV.encode(pcm16: pcm(seconds: 1))
            let entry = try cache.save(wav)

            clock.date = start.addingTimeInterval(RecordingCache.retention)
            let remaining = cache.recordings()

            #expect(remaining == [entry])
            #expect(FileManager.default.fileExists(atPath: entry.url.path))
        }
    }

    @Test func expiryPurgesJustPastRetentionAndDeletesFile() throws {
        try withCache { cache, clock, _ in
            let start = clock.date
            let wav = WAV.encode(pcm16: pcm(seconds: 1))
            let entry = try cache.save(wav)
            #expect(FileManager.default.fileExists(atPath: entry.url.path))

            clock.date = start.addingTimeInterval(RecordingCache.retention + 1)
            let remaining = cache.recordings()

            #expect(remaining.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: entry.url.path))
        }
    }

    @Test func removeDeletesFileAndIsIdempotent() throws {
        try withCache { cache, _, _ in
            let wav = WAV.encode(pcm16: pcm(seconds: 1))
            let entry = try cache.save(wav)
            #expect(FileManager.default.fileExists(atPath: entry.url.path))

            cache.remove(entry)
            #expect(!FileManager.default.fileExists(atPath: entry.url.path))

            // Removing again must not crash or throw.
            cache.remove(entry)
        }
    }

    @Test func loadReturnsSavedBytes() throws {
        try withCache { cache, _, _ in
            let wav = WAV.encode(pcm16: pcm(seconds: 1))
            let entry = try cache.save(wav)

            let loaded = try cache.load(entry)
            #expect(loaded == wav)
        }
    }

    @Test func missingDirectoryYieldsEmptyList() throws {
        let dir = makeTempDirectory()
        // Note: never created.
        let cache = RecordingCache(directory: dir, now: Date.init)
        #expect(cache.recordings() == [])
    }

    @Test func foreignFilesAreIgnoredAndNotDeleted() throws {
        try withCache { cache, _, dir in
            let wav = WAV.encode(pcm16: pcm(seconds: 1))
            _ = try cache.save(wav)

            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let notesURL = dir.appendingPathComponent("notes.txt")
            let abcURL = dir.appendingPathComponent("abc.wav")
            try Data("hello".utf8).write(to: notesURL)
            try Data("hello".utf8).write(to: abcURL)

            let remaining = cache.recordings()
            #expect(remaining.count == 1)

            #expect(FileManager.default.fileExists(atPath: notesURL.path))
            #expect(FileManager.default.fileExists(atPath: abcURL.path))
        }
    }

    @Test func savedFilePermissionsAre0600() throws {
        try withCache { cache, _, _ in
            let wav = WAV.encode(pcm16: pcm(seconds: 1))
            let entry = try cache.save(wav)

            let attributes = try FileManager.default.attributesOfItem(atPath: entry.url.path)
            let permissions = attributes[.posixPermissions] as? NSNumber
            #expect(permissions?.intValue == 0o600)
        }
    }

    @Test func protectedExpiredEntryIsKeptAndReturned() throws {
        try withCache { cache, clock, _ in
            let wav = WAV.encode(pcm16: pcm(seconds: 1))
            let protected = try cache.save(wav)
            let unprotected = try cache.save(wav)
            clock.date = clock.date.addingTimeInterval(RecordingCache.retention + 1)

            #expect(cache.recordings(protecting: [protected.id]) == [protected])
            #expect(FileManager.default.fileExists(atPath: protected.url.path))
            #expect(!FileManager.default.fileExists(atPath: unprotected.url.path))

            #expect(cache.recordings() == [])
            #expect(!FileManager.default.fileExists(atPath: protected.url.path))
        }
    }
}

struct WAVDurationTests {
    @Test func oneSecondOfAudio() {
        let wav = WAV.encode(pcm16: Data(count: 32_000))
        #expect(WAV.duration(of: wav) == 1.0)
    }

    @Test func emptyPCMIsZeroDuration() {
        let wav = WAV.encode(pcm16: Data())
        #expect(WAV.duration(of: wav) == 0)
    }

    @Test func dataShorterThanHeaderIsZeroDuration() {
        let tooShort = Data(count: 43)
        #expect(WAV.duration(of: tooShort) == 0)
    }
}
#endif
