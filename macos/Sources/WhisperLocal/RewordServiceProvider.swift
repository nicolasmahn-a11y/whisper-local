import AppKit

/// Handles "Reword with Whisper Local" from the Services menu (NSServices in Info.plist).
final class RewordServiceProvider: NSObject {
    /// Returns nil when the request is ignored because a reword or dictation is in progress.
    private let reword: @MainActor (String) async throws -> String?

    init(reword: @escaping @MainActor (String) async throws -> String?) {
        self.reword = reword
    }

    @objc func rewordText(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let text = pboard.string(forType: .string) ?? ""
        let outcome = Outcome()
        let reword = reword
        Task.detached {
            let result: Result<String?, Error>
            do { result = .success(try await reword(text)) } catch { result = .failure(error) }
            await MainActor.run { outcome.result = result }
        }
        // Services are synchronous; keep the run loop turning so the overlay animates meanwhile.
        while outcome.result == nil {
            _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }
        switch outcome.result {
        case .success(let reworded?):
            pboard.clearContents()
            pboard.setString(reworded, forType: .string)
        case .failure(let failure):
            error.pointee = failure.localizedDescription as NSString
        default:
            error.pointee = "Rewording already in progress"
        }
    }

    private final class Outcome: @unchecked Sendable {
        var result: Result<String?, Error>?
    }
}
