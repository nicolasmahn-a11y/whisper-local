#if canImport(Testing)
import Testing
@testable import WhisperLocal

struct KnownWordsTests {
    @Test func basicMultiLine() {
        #expect(KnownWords.parse("Qwen\nWhisper Local\nmacOS") == ["Qwen", "Whisper Local", "macOS"])
    }

    @Test func trimsWhitespace() {
        #expect(KnownWords.parse("  Qwen  \n\tWhisper Local\t") == ["Qwen", "Whisper Local"])
    }

    @Test func dropsEmptyAndBlankLines() {
        #expect(KnownWords.parse("Qwen\n\n   \nWhisper Local\n") == ["Qwen", "Whisper Local"])
    }

    @Test func emptyStringYieldsEmptyArray() {
        #expect(KnownWords.parse("") == [])
    }

    @Test func blankStringYieldsEmptyArray() {
        #expect(KnownWords.parse("   \n\t\n  ") == [])
    }

    @Test func crlfLineEndings() {
        #expect(KnownWords.parse("Qwen\r\nWhisper Local\r\nmacOS") == ["Qwen", "Whisper Local", "macOS"])
    }

    @Test func preservesInnerSpacesOfPhrases() {
        #expect(KnownWords.parse("Whisper   Local") == ["Whisper   Local"])
    }

    @Test func keepsOrderAndDuplicates() {
        #expect(KnownWords.parse("Qwen\nQwen\nmacOS") == ["Qwen", "Qwen", "macOS"])
    }

    @Test func formatJoinsWithNewline() {
        #expect(KnownWords.format(["Qwen", "Whisper Local", "macOS"]) == "Qwen\nWhisper Local\nmacOS")
    }

    @Test func formatEmptyIsEmptyString() {
        #expect(KnownWords.format([]) == "")
    }

    @Test func roundTripForCleanWords() {
        let words = ["Qwen", "Whisper Local", "macOS"]
        #expect(KnownWords.parse(KnownWords.format(words)) == words)
    }
}
#endif
