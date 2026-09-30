import Foundation

struct Replacement: Equatable {
    /// Variants as the model writes them, trimmed and non-empty.
    var heard: [String]
    /// Intended text, inserted as is.
    var target: String
}

enum Replacements {
    /// One rule per line: `heard1, heard2 -> Target` (also accepts `→`).
    static func parse(line: String) -> Replacement? {
        guard let arrow = [line.range(of: "->"), line.range(of: "→")]
            .compactMap({ $0 }).min(by: { $0.lowerBound < $1.lowerBound })
        else { return nil }
        let heard = line[..<arrow.lowerBound].split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let target = line[arrow.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !heard.isEmpty, !target.isEmpty else { return nil }
        return Replacement(heard: heard, target: target)
    }

    /// Parses each line and drops the ones that aren't rules, keeping order.
    static func rules(from lines: [String]) -> [Replacement] {
        lines.compactMap { parse(line: $0) }
    }

    /// Whole-word, case-insensitive, single pass; the longest heard variant wins.
    static func apply(_ rules: [Replacement], to text: String) -> String {
        var variants: [Variant] = []
        for rule in rules {
            for heard in rule.heard {
                let words = heard.split(whereSeparator: \.isWhitespace).map(String.init)
                if !words.isEmpty {
                    variants.append(Variant(order: variants.count, words: words, target: rule.target))
                }
            }
        }
        guard !variants.isEmpty else { return text }
        variants.sort { $0.length != $1.length ? $0.length > $1.length : $0.order < $1.order }

        // One capture group per variant, so the match maps straight back to its target.
        let alternation = variants.map(\.pattern).joined(separator: "|")
        let pattern = "(?<![\\p{L}\\p{N}\\p{M}])(?:\(alternation))(?![\\p{L}\\p{N}\\p{M}])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }

        let source = text as NSString
        var result = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            guard let group = (1..<match.numberOfRanges).first(where: { match.range(at: $0).location != NSNotFound })
            else { continue }
            result += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += variants[group - 1].target
            cursor = match.range.location + match.range.length
        }
        return result + source.substring(from: cursor)
    }

    private struct Variant {
        let order: Int
        let words: [String]
        let target: String
        let length: Int

        init(order: Int, words: [String], target: String) {
            self.order = order
            self.words = words
            self.target = target
            length = words.joined(separator: " ").count
        }

        var pattern: String {
            "(" + words.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "\\s+") + ")"
        }
    }
}
