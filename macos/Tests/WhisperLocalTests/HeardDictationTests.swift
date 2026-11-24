#if canImport(Testing)
import Foundation
import Testing
@testable import WhisperLocal

private func tinyWAV(seconds: Double = 1) -> Data {
    WAV.encode(pcm16: Data(count: Int(seconds * 16_000) * 2))
}

// MARK: - Prompts

struct HeardDictationPromptTests {
    @Test func autoLanguageKeepsSpokenLanguageAndNeverTranslates() {
        let text = HeardDictation.instruction(language: "")
        #expect(text.contains("language"))
        #expect(text.lowercased().contains("never translate"))
    }

    @Test func englishCodeBecomesEnglishName() {
        #expect(HeardDictation.instruction(language: "en").contains("in English into English text"))
    }

    @Test func germanCodeBecomesGermanName() {
        #expect(HeardDictation.instruction(language: "de").contains("German"))
    }

    @Test func unknownLanguagePassesThroughAsTyped() {
        #expect(HeardDictation.instruction(language: "Klingon-ish").contains("Klingon-ish"))
    }

    @Test func instructionAlwaysAsksForDigits() {
        for language in ["", "en", "Klingon-ish"] {
            #expect(HeardDictation.instruction(language: language).contains("digits"))
        }
    }

    @Test func systemPromptIncludesKnownWords() {
        let request = HeardRequest(
            wav: tinyWAV(), vocabulary: Vocabulary(knownWords: ["Kubernetes", "Traversals"]))
        let prompt = HeardDictation.systemPrompt(for: request)
        #expect(prompt.contains("Kubernetes"))
        #expect(prompt.contains("Traversals"))
    }

    @Test func systemPromptMentionsScreenshotOnlyWithOne() {
        let without = HeardDictation.systemPrompt(for: HeardRequest(wav: tinyWAV()))
        let with = HeardDictation.systemPrompt(for: HeardRequest(wav: tinyWAV(), screenshot: Data([1, 2, 3])))
        #expect(!without.lowercased().contains("screenshot"))
        #expect(with.lowercased().contains("screenshot"))
    }

    @Test func cleanedUpDiffersFromVerbatimAndMentionsFillers() {
        let verbatim = HeardDictation.systemPrompt(for: HeardRequest(wav: tinyWAV(), style: .verbatim))
        let cleaned = HeardDictation.systemPrompt(for: HeardRequest(wav: tinyWAV(), style: .cleanedUp))
        #expect(verbatim != cleaned)
        #expect(cleaned.lowercased().contains("filler"))
    }
}

// MARK: - Runaway

struct HeardDictationRunawayTests {
    @Test func limitIsFortyCharactersPerSecondPlusTwoHundred() {
        let limit = Int(2.0 * 40) + 200
        #expect(!HeardDictation.isRunaway(String(repeating: "a", count: limit), seconds: 2))
        #expect(HeardDictation.isRunaway(String(repeating: "a", count: limit + 1), seconds: 2))
    }

    @Test func emptyOutputIsNeverRunaway() {
        #expect(!HeardDictation.isRunaway("", seconds: 0))
    }
}

// MARK: - Truncation

struct HeardDictationTruncationTests {
    @Test func tooFewCharactersForLongClipIsTruncated() {
        #expect(HeardDictation.isTruncated("Hello", seconds: 60))
        #expect(HeardDictation.isTruncated("", seconds: 30))
    }

    @Test func boundaryIsOneCharacterPerSecond() {
        #expect(HeardDictation.isTruncated(String(repeating: "a", count: 59), seconds: 60))
        #expect(!HeardDictation.isTruncated(String(repeating: "a", count: 60), seconds: 60))
    }

    @Test func clipsUnderTenSecondsAreNeverTruncated() {
        #expect(!HeardDictation.isTruncated("Hi", seconds: 9.9))
        #expect(!HeardDictation.isTruncated("", seconds: 0))
    }

    @Test func whitespaceDoesNotCount() {
        #expect(HeardDictation.isTruncated("a b c d e f g h i", seconds: 10))
    }

    @Test func languagesWithoutSpacesAreNotFlagged() {
        #expect(!HeardDictation.isTruncated("今天我们讨论一下这个项目的进展情况", seconds: 15))
    }
}

// MARK: - Request body

struct HeardRequestBodyTests {
    private func decode(_ request: HeardRequest) throws -> [String: Any] {
        let data = RewordClient.heardRequestBody(request)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func userParts(_ obj: [String: Any]) throws -> [[String: Any]] {
        let messages = try #require(obj["messages"] as? [[String: Any]])
        #expect(messages.count == 2)
        #expect(messages[1]["role"] as? String == "user")
        return try #require(messages[1]["content"] as? [[String: Any]])
    }

    @Test func setsModelWithoutTemplateOptions() throws {
        let obj = try decode(HeardRequest(wav: tinyWAV()))
        #expect(obj["model"] as? String == "qwen3-omni-30b")
        #expect(obj["chat_template_kwargs"] == nil)
    }

    @Test func systemMessageComesFirst() throws {
        let obj = try decode(HeardRequest(wav: tinyWAV()))
        let messages = try #require(obj["messages"] as? [[String: Any]])
        #expect(messages.first?["role"] as? String == "system")
    }

    @Test func withoutScreenshotPartsAreTextThenAudio() throws {
        let wav = tinyWAV()
        let parts = try userParts(try decode(HeardRequest(wav: wav)))
        #expect(parts.map { $0["type"] as? String } == ["text", "input_audio"])
        let audio = try #require(parts[1]["input_audio"] as? [String: Any])
        #expect(audio["data"] as? String == wav.base64EncodedString())
        #expect(audio["format"] as? String == "wav")
    }

    @Test func withScreenshotImageComesFirst() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let parts = try userParts(try decode(HeardRequest(wav: tinyWAV(), screenshot: png)))
        #expect(parts.map { $0["type"] as? String } == ["image_url", "text", "input_audio"])
        let image = try #require(parts[0]["image_url"] as? [String: Any])
        let url = try #require(image["url"] as? String)
        #expect(url == "data:image/png;base64," + png.base64EncodedString())
    }

    @Test func textPartCarriesInstruction() throws {
        let parts = try userParts(try decode(HeardRequest(wav: tinyWAV(), language: "de")))
        let text = try #require(parts[0]["text"] as? String)
        #expect(text == HeardDictation.instruction(language: "de"))
    }
}

// MARK: - transcribe over HTTP

// Nested in RewordClientHTTPTests: suites sharing StubURLProtocol's static state run one at a time only
// under one serialized parent.
extension RewordClientHTTPTests {
@Suite
struct HeardTranscribeHTTPTests {
    let base = "http://example.test/v1"

    private func makeClient() -> RewordClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return RewordClient(session: URLSession(configuration: config))
    }

    private func completion(_ content: String) -> Data {
        let obj: [String: Any] = ["choices": [["message": ["content": content]]]]
        return try! JSONSerialization.data(withJSONObject: obj)
    }

    private func expectThrows(
        _ expected: RewordError, seconds: Double = 1, sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        do {
            _ = try await makeClient().transcribe(
                HeardRequest(wav: tinyWAV(seconds: seconds)), serverURL: base, apiKey: "k")
            Issue.record("expected \(expected) but call succeeded", sourceLocation: sourceLocation)
        } catch let e as RewordError {
            #expect(e == expected, sourceLocation: sourceLocation)
        } catch {
            Issue.record("unexpected error \(error)", sourceLocation: sourceLocation)
        }
    }

    @Test func postsToChatCompletionsWithBearer() async throws {
        StubURLProtocol.reset(.init(body: completion("hello")))
        _ = try await makeClient().transcribe(HeardRequest(wav: tinyWAV()), serverURL: base, apiKey: "sekret")
        let req = try #require(StubURLProtocol.lastRequest)
        #expect(req.httpMethod == "POST")
        #expect(req.url?.absoluteString == "http://example.test/v1/chat/completions")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer sekret")
    }

    @Test func returnsCleanedContent() async throws {
        StubURLProtocol.reset(.init(body: completion("<think>hmm</think>  Hello there \n")))
        let out = try await makeClient().transcribe(HeardRequest(wav: tinyWAV()), serverURL: base, apiKey: "")
        #expect(out == "Hello there")
    }

    @Test func silenceYieldsEmptyString() async throws {
        StubURLProtocol.reset(.init(body: completion("")))
        let out = try await makeClient().transcribe(HeardRequest(wav: tinyWAV(seconds: 10)), serverURL: base, apiKey: "")
        #expect(out.isEmpty)
    }

    @Test func modelOffIs503() async {
        StubURLProtocol.reset(.init(status: 503))
        await expectThrows(.response(503))
    }

    @Test func badKeyIsUnauthorized() async {
        StubURLProtocol.reset(.init(status: 401))
        await expectThrows(.unauthorized)
    }

    @Test func overlongOutputForShortClipIsRunaway() async {
        StubURLProtocol.reset(.init(body: completion(String(repeating: "word ", count: 100))))
        await expectThrows(.runaway)
    }

    @Test func oneWordForLongClipIsTruncated() async {
        StubURLProtocol.reset(.init(body: completion("Hello")))
        await expectThrows(.truncated, seconds: 10)
    }
}
}

// MARK: - ModelControl

struct ModelStartURLTests {
    @Test func dropsTrailingV1() throws {
        let url = try ModelControl.startURL("gemma-4-12b", serverURL: "https://x.example/v1")
        #expect(url.absoluteString == "https://x.example/admin/models/gemma-4-12b/start")
    }

    @Test func keepsPortAndPrefixAndToleratesTrailingSlash() throws {
        let url = try ModelControl.startURL("gemma-4-12b", serverURL: "https://x.example:8443/llm/v1/")
        #expect(url.absoluteString == "https://x.example:8443/llm/admin/models/gemma-4-12b/start")
    }

    @Test func plainHTTPToRemoteHostNeedsHTTPS() {
        #expect(throws: ModelStartError.needsHTTPS) {
            try ModelControl.startURL("gemma-4-12b", serverURL: "http://fedora.local:8400/v1")
        }
    }

    @Test func plainHTTPToLoopbackIsAllowed() throws {
        for host in ["localhost", "127.0.0.1", "[::1]"] {
            let url = try ModelControl.startURL("gemma-4-12b", serverURL: "http://\(host):8400/v1")
            #expect(url.absoluteString == "http://\(host):8400/admin/models/gemma-4-12b/start")
        }
    }

    @Test func otherSchemesAreInvalid() {
        #expect(throws: ModelStartError.invalidURL) {
            try ModelControl.startURL("gemma-4-12b", serverURL: "ftp://x.example/v1")
        }
    }
}

extension RewordClientHTTPTests {
@Suite
struct ModelStartHTTPTests {
    let base = "https://x.example/v1"

    private func makeControl() -> ModelControl {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return ModelControl(session: URLSession(configuration: config))
    }

    private func expectThrows(_ expected: ModelStartError, sourceLocation: SourceLocation = #_sourceLocation) async {
        do {
            try await makeControl().start("gemma-4-12b", serverURL: base, adminKey: "admin")
            Issue.record("expected \(expected) but call succeeded", sourceLocation: sourceLocation)
        } catch let e as ModelStartError {
            #expect(e == expected, sourceLocation: sourceLocation)
        } catch {
            Issue.record("unexpected error \(error)", sourceLocation: sourceLocation)
        }
    }

    @Test func postsWithAdminKeyAndNeverReplaces() async throws {
        StubURLProtocol.reset(.init(status: 202, body: Data(#"{"model":"gemma-4-12b","action":"start"}"#.utf8)))
        try await makeControl().start("gemma-4-12b", serverURL: base, adminKey: "admin")
        let req = try #require(StubURLProtocol.lastRequest)
        #expect(req.httpMethod == "POST")
        #expect(req.value(forHTTPHeaderField: "x-api-key") == "admin")
        #expect(req.url?.path == "/admin/models/gemma-4-12b/start")
        #expect(req.url?.query?.contains("replace") != true)
    }

    @Test func conflictListingModelsReportsWouldStop() async {
        let body = #"{"error":{"message":"would stop","would_stop":["gemma-4-26b"]}}"#
        StubURLProtocol.reset(.init(status: 409, body: Data(body.utf8)))
        await expectThrows(.wouldStop(["gemma-4-26b"]))
    }

    @Test func conflictWithoutWouldStopIsBusy() async {
        let body = #"{"error":{"message":"gemma-4-12b is busy: start"}}"#
        StubURLProtocol.reset(.init(status: 409, body: Data(body.utf8)))
        await expectThrows(.busy)
    }

    @Test func forbiddenIsUnauthorized() async {
        StubURLProtocol.reset(.init(status: 403))
        await expectThrows(.unauthorized)
    }

    @Test func serverErrorCarriesStatus() async {
        StubURLProtocol.reset(.init(status: 500))
        await expectThrows(.response(500))
    }

    @Test func transportErrorIsUnreachable() async {
        StubURLProtocol.reset(.init(error: URLError(.timedOut)))
        await expectThrows(.unreachable)
    }
}
}
#endif
