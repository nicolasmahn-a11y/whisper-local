#if canImport(Testing)
import Testing
@testable import WhisperLocal

struct ReplacementsTests {
    private func rule(_ heard: [String], _ target: String) -> Replacement {
        Replacement(heard: heard, target: target)
    }

    private func apply(_ lines: [String], _ text: String) -> String {
        Replacements.apply(Replacements.rules(from: lines), to: text)
    }

    @Test func parseSingleVariant() {
        #expect(Replacements.parse(line: "Persuys -> Persuus") == rule(["Persuys"], "Persuus"))
    }

    @Test func parseMultipleVariants() {
        #expect(Replacements.parse(line: "Persuys, Pursus, per size -> Persuus") == rule(["Persuys", "Pursus", "per size"], "Persuus"))
    }

    @Test func parseUnicodeArrow() {
        #expect(Replacements.parse(line: "Pursus, Persuys → Persuus") == rule(["Pursus", "Persuys"], "Persuus"))
    }

    @Test func parseTrimsEverything() {
        #expect(Replacements.parse(line: "  a  ,\tb\t  ->   Target  \t") == rule(["a", "b"], "Target"))
    }

    @Test func parseSplitsAtFirstArrow() {
        #expect(Replacements.parse(line: "a -> b -> c") == rule(["a"], "b -> c"))
    }

    @Test func parseFirstArrowWinsAcrossArrowKinds() {
        #expect(Replacements.parse(line: "a → b -> c") == rule(["a"], "b -> c"))
        #expect(Replacements.parse(line: "a -> b → c") == rule(["a"], "b → c"))
    }

    @Test func parseDropsEmptyVariants() {
        #expect(Replacements.parse(line: "a, , b,, ,c -> T") == rule(["a", "b", "c"], "T"))
    }

    @Test func parseKeepsInnerSpacesOfVariants() {
        #expect(Replacements.parse(line: "per   size -> Persuus") == rule(["per   size"], "Persuus"))
    }

    @Test func parseBlankLineIsNil() {
        #expect(Replacements.parse(line: "") == nil)
        #expect(Replacements.parse(line: "  \t ") == nil)
    }

    @Test func parseWithoutArrowIsNil() {
        #expect(Replacements.parse(line: "Persuys Persuus") == nil)
        #expect(Replacements.parse(line: "a - > b") == nil)
    }

    @Test func parseNoHeardVariantsIsNil() {
        #expect(Replacements.parse(line: "-> Persuus") == nil)
        #expect(Replacements.parse(line: "  , ,  -> Persuus") == nil)
        #expect(Replacements.parse(line: "→ Persuus") == nil)
    }

    @Test func parseEmptyTargetIsNil() {
        #expect(Replacements.parse(line: "Persuys ->") == nil)
        #expect(Replacements.parse(line: "Persuys ->   \t") == nil)
        #expect(Replacements.parse(line: "Persuys →") == nil)
    }

    @Test func rulesDropsNilsAndKeepsOrder() {
        let lines = ["a -> b", "", "junk", "c, d → e", "  ", "f ->"]
        #expect(Replacements.rules(from: lines) == [rule(["a"], "b"), rule(["c", "d"], "e")])
    }

    @Test func rulesFromEmptyIsEmpty() {
        #expect(Replacements.rules(from: []) == [])
    }

    @Test func applyReplacesVariant() {
        #expect(apply(["Persuys -> Persuus"], "I like Persuys a lot") == "I like Persuus a lot")
    }

    @Test func applyAnyVariantOfRule() {
        let lines = ["Persuys, Pursus, per size -> Persuus"]
        #expect(apply(lines, "Persuys, Pursus and per size") == "Persuus, Persuus and Persuus")
    }

    @Test func applyIsCaseInsensitive() {
        #expect(apply(["persuys -> Persuus"], "PERSUYS and Persuys and persuys") == "Persuus and Persuus and Persuus")
    }

    @Test func applyUsesTargetCasingVerbatim() {
        #expect(apply(["gnome -> GNOME"], "gnome Gnome") == "GNOME GNOME")
    }

    @Test func applyReplacesAllOccurrences() {
        #expect(apply(["a -> b"], "a a a") == "b b b")
    }

    @Test func applyMultipleRules() {
        #expect(apply(["cat -> dog", "red -> blue"], "red cat") == "blue dog")
    }

    @Test func applyWholeWordNotInsideLongerWord() {
        #expect(apply(["Persuus -> Perseus"], "Persuusian and unPersuus and Persuus2") == "Persuusian and unPersuus and Persuus2")
    }

    @Test func applyWholeWordNotAdjacentToDigit() {
        #expect(apply(["cat -> dog"], "3cat cat3 cat") == "3cat cat3 dog")
    }

    @Test func applyUnicodeLetterBoundaryPreventsMatch() {
        #expect(apply(["Persuus -> Perseus"], "Persuusé") == "Persuusé")
        #expect(apply(["Persuus -> Perseus"], "éPersuus") == "éPersuus")
        #expect(apply(["Persuus -> Perseus"], "Persuusé Persuus") == "Persuusé Perseus")
    }

    @Test func applyNonLatinLetterBoundary() {
        #expect(apply(["cat -> dog"], "catЖ Жcat cat") == "catЖ Жcat dog")
    }

    @Test func applyMatchesNextToPunctuation() {
        #expect(apply(["Persuus -> Perseus"], "Persuus, (Persuus) \"Persuus\". Persuus! -Persuus-") == "Perseus, (Perseus) \"Perseus\". Perseus! -Perseus-")
    }

    @Test func applyMatchesAtStartAndEnd() {
        #expect(apply(["a -> b"], "a") == "b")
        #expect(apply(["a -> b"], "a x a") == "b x b")
    }

    @Test func applyMatchesNextToNewline() {
        #expect(apply(["a -> b"], "x\na\ny") == "x\nb\ny")
    }

    @Test func applyWhitespaceRunMatchesInsideVariant() {
        let lines = ["Persuus Map -> PersuusMap"]
        #expect(apply(lines, "Persuus  Map") == "PersuusMap")
        #expect(apply(lines, "Persuus\nMap") == "PersuusMap")
        #expect(apply(lines, "Persuus \t\n Map") == "PersuusMap")
        #expect(apply(lines, "Persuus Map") == "PersuusMap")
    }

    @Test func applyWhitespaceVariantNeedsWhitespace() {
        #expect(apply(["per size -> Persuus"], "persize") == "persize")
    }

    @Test func applyMetacharactersAreLiteral() {
        #expect(apply(["TL;DR -> too long"], "TL;DR: x") == "too long: x")
        #expect(apply(["C++ -> C plus plus"], "I write C++ daily") == "I write C plus plus daily")
        #expect(apply(["a.b -> X"], "a.b axb") == "X axb")
        #expect(apply(["(x) -> Y"], "call (x) now") == "call Y now")
        #expect(apply(["a|b -> Z"], "a b a|b") == "a b Z")
        #expect(apply(["[q] -> R"], "[q] q") == "R q")
        #expect(apply(["a* -> S"], "aaa a*") == "aaa S")
    }

    @Test func applyMetacharacterBoundaries() {
        #expect(apply(["C++ -> Cpp"], "C++11") == "C++11")
        #expect(apply(["C++ -> Cpp"], "xC++") == "xC++")
    }

    @Test func applyTargetIsLiteralDollarAndBackslash() {
        #expect(apply(["cost -> $1"], "the cost") == "the $1")
        #expect(apply(["cost -> $0 and $&"], "cost") == "$0 and $&")
        #expect(apply(["path -> C:\\dir\\1"], "path") == "C:\\dir\\1")
        #expect(apply(["nl -> a\\nb"], "nl") == "a\\nb")
    }

    @Test func applyLongestVariantWinsAcrossRules() {
        let lines = ["Persuus -> Perseus", "Persuus Map -> PerseusMap"]
        #expect(apply(lines, "the Persuus Map") == "the PerseusMap")
    }

    @Test func applyLongestWinsRegardlessOfRuleOrder() {
        let lines = ["Persuus Map -> PerseusMap", "Persuus -> Perseus"]
        #expect(apply(lines, "the Persuus Map and Persuus") == "the PerseusMap and Perseus")
    }

    @Test func applyLongestWinsWithinRule() {
        #expect(apply(["a, a b -> X"], "a b") == "X")
    }

    @Test func applySinglePassNoChaining() {
        #expect(apply(["a -> b", "b -> c"], "a") == "b")
        #expect(apply(["a -> b", "b -> c"], "a b") == "b c")
    }

    @Test func applyTargetContainingHeardIsNotRescanned() {
        #expect(apply(["cat -> cat cat"], "cat") == "cat cat")
    }

    @Test func applyNoRulesLeavesTextUnchanged() {
        #expect(Replacements.apply([], to: "Hello  world\n") == "Hello  world\n")
    }

    @Test func applyNoMatchLeavesTextUnchanged() {
        #expect(apply(["zzz -> y"], "Hello  world\n") == "Hello  world\n")
    }

    @Test func applyEmptyTextIsEmpty() {
        #expect(apply(["a -> b"], "") == "")
    }

    @Test func applyOnlyInvalidLinesLeavesTextUnchanged() {
        #expect(apply(["", "junk", "a ->"], "a junk") == "a junk")
    }

    @Test func applyPreservesSurroundingWhitespace() {
        #expect(apply(["a -> b"], "  a \n a\t") == "  b \n b\t")
    }
    @Test func applyCombiningMarkBeforeIsPartOfWord() {
        #expect(apply(["cat -> dog"], "e\u{0301}cat") == "e\u{0301}cat")
    }

    @Test func applyCombiningMarkAfterIsPartOfWord() {
        #expect(apply(["Persuus -> Perseus"], "Persuus\u{0301}") == "Persuus\u{0301}")
    }

    @Test func applySameVariantInTwoRulesFirstWins() {
        #expect(apply(["a -> first", "a -> second"], "a") == "first")
    }

    @Test func applyMatchesNextToEmoji() {
        #expect(apply(["cat -> dog"], "🎉cat🎉") == "🎉dog🎉")
    }

    @Test func applyPunctuationOnlyVariant() {
        #expect(apply(["... -> ellipsis"], "wait ... what") == "wait ellipsis what")
    }
}
#endif
