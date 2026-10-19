import Foundation

/// Whether the microphone stays open after dictating, so the next recording can start with pre-roll.
struct WarmMicPolicy {
    var enabled: Bool
    var window: TimeInterval = 3600

    /// lastRecordingEnded nil = no recording yet in this app run → false.
    func shouldBeWarm(lastRecordingEnded: TimeInterval?, now: TimeInterval) -> Bool {
        guard enabled, let lastRecordingEnded else { return false }
        return now >= lastRecordingEnded && now - lastRecordingEnded < window
    }

    func coolDownAt(lastRecordingEnded: TimeInterval) -> TimeInterval {
        lastRecordingEnded + window
    }
}
