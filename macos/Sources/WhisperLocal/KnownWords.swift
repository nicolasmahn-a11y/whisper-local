import Foundation

enum KnownWords {
    /// One word or phrase per line; trims whitespace, drops empty lines.
    static func parse(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Inverse for display: joins with "\n".
    static func format(_ words: [String]) -> String {
        words.joined(separator: "\n")
    }
}
