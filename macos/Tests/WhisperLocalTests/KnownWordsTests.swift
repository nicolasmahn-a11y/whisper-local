#if canImport(Testing)
import Testing
@testable import WhisperLocal

struct KnownWordsTests {
    @Test func basicMultiLine() {
        #expect(KnownWords.parse("Qwen\nWhisper Local\nGNOME") == ["Qwen", "Whisper Local", "GNOME"])
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
        #expect(KnownWords.parse("Qwen\r\nWhisper Local\r\nGNOME") == ["Qwen", "Whisper Local", "GNOME"])
    }

    @Test func preservesInnerSpacesOfPhrases() {
        #expect(KnownWords.parse("Whisper   Local") == ["Whisper   Local"])
    }

    @Test func keepsOrderAndDuplicates() {
        #expect(KnownWords.parse("Qwen\nQwen\nGNOME") == ["Qwen", "Qwen", "GNOME"])
    }

    @Test func formatJoinsWithNewline() {
        #expect(KnownWords.format(["Qwen", "Whisper Local", "GNOME"]) == "Qwen\nWhisper Local\nGNOME")
    }

    @Test func formatEmptyIsEmptyString() {
        #expect(KnownWords.format([]) == "")
    }

    @Test func roundTripForCleanWords() {
        let words = ["Qwen", "Whisper Local", "GNOME"]
        #expect(KnownWords.parse(KnownWords.format(words)) == words)
    }
}
#endif
