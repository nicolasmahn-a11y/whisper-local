import Foundation

enum ClaudeCLI {
    static func locate(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)
    ) -> URL? {
        let candidates = [
            home.appending(path: ".local/bin/claude"),
            home.appending(path: ".claude/local/claude"),
            URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
            URL(fileURLWithPath: "/usr/local/bin/claude"),
        ]
        return candidates.first { isExecutable($0.path) }
    }

    static func arguments(systemPrompt: String) -> [String] {
        [
            "-p", "--model", "haiku", "--setting-sources", "", "--strict-mcp-config",
            "--no-session-persistence", "--tools", "", "--system-prompt", systemPrompt,
        ]
    }

    static func reword(
        _ text: String, executable: URL, knownWords: [String] = [], style: RewordStyle = .light
    ) async throws -> String {
        _ = ignoreSIGPIPE
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments(systemPrompt: Rewording.systemPrompt(knownWords: knownWords, style: style))
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.environment = environment(for: executable)
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw RewordError.claudeFailed }
        let once = Once()
        return try await withCheckedThrowingContinuation { continuation in
            let finish = { (result: Result<String, Error>) in once.run { continuation.resume(with: result) } }
            let queue = DispatchQueue.global(qos: .userInitiated)
            queue.async {
                try? input.fileHandleForWriting.write(contentsOf: Data(text.utf8))
                try? input.fileHandleForWriting.close()
            }
            queue.async {
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                finish(process.terminationReason == .exit && process.terminationStatus == 0
                    ? .success(String(decoding: data, as: UTF8.self))
                    : .failure(RewordError.claudeFailed))
            }
            // Escalate to SIGKILL, then give up even if a stray child still holds stdout open.
            queue.asyncAfter(deadline: .now() + 90) {
                if process.isRunning { process.terminate() }
                queue.asyncAfter(deadline: .now() + 2) {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    queue.asyncAfter(deadline: .now() + 1) { finish(.failure(RewordError.claudeFailed)) }
                }
            }
        }
    }

    /// GUI apps get a minimal PATH; script installs of the CLI need node next to it.
    private static func environment(for executable: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = [
            executable.deletingLastPathComponent().path, "\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin",
            environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin",
        ]
        environment["PATH"] = path.joined(separator: ":")
        return environment
    }

    private static let ignoreSIGPIPE: Void = { signal(SIGPIPE, SIG_IGN) }()

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false

        func run(_ body: () -> Void) {
            lock.lock()
            defer { lock.unlock() }
            guard !done else { return }
            done = true
            body()
        }
    }
}
