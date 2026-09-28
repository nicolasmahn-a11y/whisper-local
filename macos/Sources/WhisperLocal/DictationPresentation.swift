import SwiftUI

struct DictationStyle {
    let symbol: String
    let color: Color
    let showsRecordingDot: Bool

    static func current(state: DictationState, enabled: Bool, hasProblem: Bool) -> Self {
        if !enabled { return Self(symbol: "mic.slash", color: Theme.neutralMuted, showsRecordingDot: false) }
        if hasProblem { return Self(symbol: "mic.slash.fill", color: Theme.amber, showsRecordingDot: false) }
        return switch state {
        case .idle: Self(symbol: "mic", color: Theme.neutralStrong, showsRecordingDot: false)
        case .listening: Self(symbol: "mic.fill", color: Theme.red, showsRecordingDot: true)
        case .handsFree: Self(symbol: "mic.fill", color: Theme.red, showsRecordingDot: true)
        case .transcribing: Self(symbol: "mic.fill", color: Theme.blue, showsRecordingDot: false)
        }
    }
}

enum RecordingFormat {
    /// "0:42", "12:05"
    static func elapsed(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return "\(total / 60):" + String(format: "%02d", total % 60)
    }

    /// "just now", "3 min ago"
    static func ago(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
        return RelativeDateTimeFormatter().localizedString(for: date, relativeTo: now)
    }

    static func label(for recording: CachedRecording, now: Date = Date()) -> String {
        "\(elapsed(recording.duration)) recording · \(ago(recording.recordedAt, now: now))"
    }
}
