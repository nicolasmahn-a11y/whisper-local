import Foundation

struct CachedRecording: Equatable, Identifiable, Sendable {
    let id: String
    let url: URL
    let recordedAt: Date
    let duration: TimeInterval
}

/// Keeps finished recordings on disk for a while so a failed, doubtful or cancelled
/// take can be transcribed again instead of losing the audio.
final class RecordingCache {
    static let retention: TimeInterval = 15 * 60

    let directory: URL
    private let now: () -> Date
    private let files = FileManager.default

    static func defaultDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support
            .appendingPathComponent("WhisperLocal", isDirectory: true)
            .appendingPathComponent("Recordings", isDirectory: true)
    }

    /// Transcribed or cancelled recordings, kept apart so they don't count as unsent.
    static func recentDirectory() -> URL {
        defaultDirectory().deletingLastPathComponent().appendingPathComponent("Recent", isDirectory: true)
    }

    init(directory: URL, now: @escaping () -> Date = Date.init) {
        self.directory = directory
        self.now = now
    }

    func save(_ wav: Data) throws -> CachedRecording {
        try createDirectory()
        let milliseconds = Int64((now().timeIntervalSince1970 * 1000).rounded(.down))
        let id = "\(milliseconds)-\(UUID().uuidString)"
        let url = directory.appendingPathComponent(id + ".wav")
        try wav.write(to: url, options: .atomic)
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return CachedRecording(
            id: id, url: url,
            recordedAt: Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000),
            duration: WAV.duration(of: wav)
        )
    }

    func load(_ recording: CachedRecording) throws -> Data {
        try Data(contentsOf: recording.url)
    }

    func remove(_ recording: CachedRecording) {
        try? files.removeItem(at: recording.url)
    }

    /// Keeps the id, so the recording's age and retention carry over.
    func move(_ recording: CachedRecording, to destination: RecordingCache) throws -> CachedRecording {
        try destination.createDirectory()
        let url = destination.directory.appendingPathComponent(recording.url.lastPathComponent)
        try files.moveItem(at: recording.url, to: url)
        return CachedRecording(id: recording.id, url: url, recordedAt: recording.recordedAt, duration: recording.duration)
    }

    private func createDirectory() throws {
        guard !files.fileExists(atPath: directory.path) else { return }
        try files.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    /// Expired entries whose id is in `protecting` are kept on disk and still returned.
    func recordings(protecting ids: Set<String> = []) -> [CachedRecording] {
        guard let urls = try? files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        let now = now()
        var kept: [CachedRecording] = []
        for found in urls where found.pathExtension == "wav" {
            let id = found.deletingPathExtension().lastPathComponent
            let url = directory.appendingPathComponent(id + ".wav")
            guard let dash = id.firstIndex(of: "-"),
                  let milliseconds = Int64(id[..<dash])
            else { continue }
            let recordedAt = Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000)
            if now.timeIntervalSince(recordedAt) > Self.retention, !ids.contains(id) {
                try? files.removeItem(at: url)
                continue
            }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            kept.append(CachedRecording(
                id: id, url: url, recordedAt: recordedAt,
                duration: WAV.duration(byteCount: size)
            ))
        }
        return kept.sorted { ($0.recordedAt, $0.id) > ($1.recordedAt, $1.id) }
    }
}
