#if canImport(Testing)
import Foundation
import Testing
@testable import WhisperLocal

// MARK: - Pure helpers

struct RewordingHelpersTests {
    @Test func prefersGemmaOverQwenRegardlessOfOrder() {
        #expect(Rewording.chooseModel(from: ["qwen3.8-27b", "gemma-4-26b"]) == "gemma-4-26b")
        #expect(Rewording.chooseModel(from: ["gemma-4-26b", "qwen3.8-27b"]) == "gemma-4-26b")
    }

    @Test func gemmaMatchIsCaseInsensitive() {
        #expect(Rewording.chooseModel(from: ["qwen3.8-27b", "Google/GEMMA-2"]) == "Google/GEMMA-2")
    }

    @Test func picksFirstGemma() {
        #expect(Rewording.chooseModel(from: ["gemma-a", "gemma-b"]) == "gemma-a")
    }

    @Test func choosesQwenWhenNoGemma() {
        #expect(Rewording.chooseModel(from: ["llama-3", "Qwen3.8-27b"]) == "Qwen3.8-27b")
    }

    @Test func skipsQwenAsr() {
        #expect(Rewording.chooseModel(from: ["qwen3-asr", "qwen3.8-27b"]) == "qwen3.8-27b")
        #expect(Rewording.chooseModel(from: ["Qwen3-ASR-1.7B"]) == nil)
    }

    @Test func nilWhenNoMatch() {
        #expect(Rewording.chooseModel(from: ["llama-3", "mistral"]) == nil)
    }

    @Test func nilWhenEmpty() {
        #expect(Rewording.chooseModel(from: []) == nil)
    }

    @Test func cleanStripsThinkBlock() {
        #expect(Rewording.clean("<think>hmm</think>Hello there") == "Hello there")
    }

    @Test func cleanStripsMultilineThinkBlock() {
        #expect(Rewording.clean("<think>line one\nline two\n</think>\n\nHello") == "Hello")
    }

    @Test func cleanStripsMultipleThinkBlocks() {
        #expect(Rewording.clean("<think>a</think>One <think>b\nc</think>two") == "One two")
    }

    @Test func cleanStripsDanglingThinkPrefix() {
        #expect(Rewording.clean("reasoning without opener...</think>\nAnswer") == "Answer")
    }

    @Test func cleanTrimsWhitespace() {
        #expect(Rewording.clean("  \n Hello world \n\t") == "Hello world")
    }

    @Test func cleanLeavesPlainTextAlone() {
        #expect(Rewording.clean("Just text.") == "Just text.")
    }

    @Test func cleanOfOnlyThinkIsEmpty() {
        #expect(Rewording.clean("<think>nothing else</think>  \n") == "")
    }

    @Test func preservesLeadingAndTrailingWhitespace() {
        #expect(Rewording.preservingSurroundingWhitespace(of: " foo bar\n", "Foo.") == " Foo.\n")
    }

    @Test func preservesNothingWhenNoSurroundingWhitespace() {
        #expect(Rewording.preservingSurroundingWhitespace(of: "foo bar", "Foo.") == "Foo.")
    }

    @Test func preservesOnlyTrailingNewlines() {
        #expect(Rewording.preservingSurroundingWhitespace(of: "foo\n\n", "Foo.") == "Foo.\n\n")
    }

    @Test func preservesOnlyLeadingSpaces() {
        #expect(Rewording.preservingSurroundingWhitespace(of: "   foo", "Foo.") == "   Foo.")
    }

    @Test func systemPromptIsNotEmpty() {
        #expect(!Rewording.systemPrompt.isEmpty)
    }
}

// MARK: - Fallback chain

private final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [String] = []
    var events: [String] {
        lock.lock(); defer { lock.unlock() }
        return _events
    }
    func record(_ e: String) {
        lock.lock(); defer { lock.unlock() }
        _events.append(e)
    }
}

private struct FakeConfig {
    var models: Result<[String], RewordError> = .success(["gemma-4-26b", "qwen3.8-27b"])
    var local: Result<String, RewordError> = .success("Local result")
    /// nil = Claude unavailable.
    var claude: Result<String, RewordError>?
}

private func makeServices(_ config: FakeConfig, log: CallLog) -> RewordServices {
    RewordServices(
        listModels: {
            log.record("list")
            return try config.models.get()
        },
        rewordLocal: { text, model in
            log.record("local:\(model):\(text)")
            return try config.local.get()
        },
        rewordWithClaude: config.claude.map { result in
            { text in
                log.record("claude:\(text)")
                return try result.get()
            }
        }
    )
}

struct RewordingChainTests {
    private func expectThrows(
        _ expected: RewordError,
        text: String = "um hello",
        _ config: FakeConfig,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        let log = CallLog()
        do {
            _ = try await Rewording.reword(text, using: makeServices(config, log: log))
            Issue.record("expected \(expected) but call succeeded", sourceLocation: sourceLocation)
        } catch let e as RewordError {
            #expect(e == expected, sourceLocation: sourceLocation)
        } catch {
            Issue.record("unexpected error \(error)", sourceLocation: sourceLocation)
        }
    }

    @Test func blankTextIsNothingSelectedAndCallsNothing() async {
        for blank in ["", "   ", "\n\t  \n"] {
            let log = CallLog()
            let services = makeServices(FakeConfig(claude: .success("x")), log: log)
            do {
                _ = try await Rewording.reword(blank, using: services)
                Issue.record("expected nothingSelected")
            } catch let e as RewordError {
                #expect(e == .nothingSelected)
            } catch {
                Issue.record("unexpected error \(error)")
            }
            #expect(log.events.isEmpty)
        }
    }

    @Test func lightStyleLocalOnlyUnreachableThrowsNoModelWithoutChat() async {
        let log = CallLog()
        let services = makeServices(FakeConfig(models: .failure(.unreachable)), log: log)
        do {
            _ = try await Rewording.reword("um hello", using: services, style: .light)
            Issue.record("expected noModel")
        } catch let e as RewordError {
            #expect(e == .noModel)
        } catch {
            Issue.record("unexpected error \(error)")
        }
        #expect(log.events == ["list"])
    }

    @Test func textOverLimitIsTooLongAndCallsNothing() async {
        let log = CallLog()
        let services = makeServices(FakeConfig(claude: .success("x")), log: log)
        let text = String(repeating: "a", count: Rewording.maxCharacters + 1)
        do {
            _ = try await Rewording.reword(text, using: services)
            Issue.record("expected tooLong")
        } catch let e as RewordError {
            #expect(e == .tooLong)
        } catch {
            Issue.record("unexpected error \(error)")
        }
        #expect(log.events.isEmpty)
        #expect(RewordError.tooLong.localizedDescription == "Too much text to reword")
    }

    @Test func textAtLimitIsReworded() async throws {
        #expect(Rewording.maxCharacters == 6000)
        let log = CallLog()
        let text = String(repeating: "a", count: Rewording.maxCharacters)
        let out = try await Rewording.reword(text, using: makeServices(FakeConfig(), log: log))
        #expect(out == "Local result")
        #expect(log.events.first == "list")
    }

    @Test func usesGemmaWhenListed() async throws {
        let log = CallLog()
        let services = makeServices(
            FakeConfig(models: .success(["qwen3.8-27b", "gemma-4-26b"]), claude: .success("Claude")),
            log: log)
        let out = try await Rewording.reword("um hello", using: services)
        #expect(out == "Local result")
        #expect(log.events == ["list", "local:gemma-4-26b:um hello"])
    }

    @Test func usesQwenWhenNoGemma() async throws {
        let log = CallLog()
        let services = makeServices(FakeConfig(models: .success(["qwen3-asr", "qwen3.8-27b"])), log: log)
        _ = try await Rewording.reword("hi", using: services)
        #expect(log.events == ["list", "local:qwen3.8-27b:hi"])
    }

    @Test func unreachableFallsBackToClaude() async throws {
        let log = CallLog()
        let services = makeServices(
            FakeConfig(models: .failure(.unreachable), claude: .success("From Claude")), log: log)
        let out = try await Rewording.reword("um hello", using: services)
        #expect(out == "From Claude")
        #expect(log.events == ["list", "claude:um hello"])
    }

    @Test func noMatchingModelWithoutClaudeIsNoModel() async {
        await expectThrows(.noModel, FakeConfig(models: .success(["llama-3", "qwen3-asr"])))
    }

    @Test func noMatchingModelFallsBackToClaude() async throws {
        let log = CallLog()
        let services = makeServices(
            FakeConfig(models: .success(["llama-3"]), claude: .success("From Claude")), log: log)
        let out = try await Rewording.reword("hello", using: services)
        #expect(out == "From Claude")
        #expect(log.events == ["list", "claude:hello"])
    }

    @Test func unreachableWithoutClaudeIsNoModel() async {
        await expectThrows(.noModel, FakeConfig(models: .failure(.unreachable)))
    }

    @Test func unauthorizedWithoutClaudeIsUnauthorized() async {
        await expectThrows(.unauthorized, FakeConfig(models: .failure(.unauthorized)))
    }

    @Test func unauthorizedWithClaudeFallsBack() async throws {
        let log = CallLog()
        let services = makeServices(
            FakeConfig(models: .failure(.unauthorized), claude: .success("From Claude")), log: log)
        #expect(try await Rewording.reword("x y", using: services) == "From Claude")
    }

    @Test func localHttpErrorFallsBackToClaude() async throws {
        let log = CallLog()
        let services = makeServices(
            FakeConfig(local: .failure(.response(500)), claude: .success("From Claude")), log: log)
        let out = try await Rewording.reword("hello", using: services)
        #expect(out == "From Claude")
        #expect(log.events == ["list", "local:gemma-4-26b:hello", "claude:hello"])
    }

    @Test func localHttpErrorWithoutClaudeThrowsThatError() async {
        await expectThrows(.response(500), FakeConfig(local: .failure(.response(500))))
    }

    @Test func localWhitespaceOnlyFallsBackToClaude() async throws {
        let log = CallLog()
        let services = makeServices(
            FakeConfig(local: .success("  \n "), claude: .success("From Claude")), log: log)
        #expect(try await Rewording.reword("hello", using: services) == "From Claude")
    }

    @Test func localThinkOnlyFallsBackToClaude() async throws {
        let log = CallLog()
        let services = makeServices(
            FakeConfig(local: .success("<think>pondering</think>\n"), claude: .success("From Claude")),
            log: log)
        #expect(try await Rewording.reword("hello", using: services) == "From Claude")
    }

    @Test func localEmptyWithoutClaudeIsEmptyResult() async {
        await expectThrows(.emptyResult, FakeConfig(local: .success("   ")))
    }

    @Test func claudeEmptyIsEmptyResult() async {
        await expectThrows(
            .emptyResult,
            FakeConfig(models: .failure(.unreachable), claude: .success("  \n")))
    }

    @Test func claudeFailureIsPropagated() async {
        await expectThrows(
            .claudeFailed,
            FakeConfig(models: .failure(.unreachable), claude: .failure(.claudeFailed)))
    }

    @Test func resultKeepsSurroundingWhitespace() async throws {
        let log = CallLog()
        let services = makeServices(FakeConfig(local: .success("Hello.")), log: log)
        let out = try await Rewording.reword("  um hello\n", using: services)
        #expect(out == "  Hello.\n")
    }

    @Test func claudeResultKeepsSurroundingWhitespace() async throws {
        let log = CallLog()
        let services = makeServices(
            FakeConfig(models: .failure(.unreachable), claude: .success("Hello.")), log: log)
        let out = try await Rewording.reword("\num hello ", using: services)
        #expect(out == "\nHello. ")
    }

    @Test func localOutputIsCleaned() async throws {
        let log = CallLog()
        let services = makeServices(
            FakeConfig(local: .success("<think>x</think>\n  Cleaned text \n")), log: log)
        #expect(try await Rewording.reword("dirty", using: services) == "Cleaned text")
    }

    @Test func claudeOutputIsCleaned() async throws {
        let log = CallLog()
        let services = makeServices(
            FakeConfig(models: .failure(.unreachable), claude: .success("<think>x</think> Cleaned \n")),
            log: log)
        #expect(try await Rewording.reword("dirty", using: services) == "Cleaned")
    }
}

// MARK: - RewordClient

struct RewordClientBodyTests {
    @Test func chatRequestBodyShape() throws {
        let data = RewordClient.chatRequestBody(text: "um hello", model: "gemma-4-26b")
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["model"] as? String == "gemma-4-26b")
        #expect(obj["temperature"] as? Double == 0.2)

        let messages = try #require(obj["messages"] as? [[String: Any]])
        #expect(messages.count == 2)
        #expect(messages[0]["role"] as? String == "system")
        #expect(messages[0]["content"] as? String == Rewording.systemPrompt)
        #expect(messages[1]["role"] as? String == "user")
        #expect(messages[1]["content"] as? String == "um hello")

        let kwargs = try #require(obj["chat_template_kwargs"] as? [String: Any])
        #expect(kwargs["enable_thinking"] as? Bool == false)
    }
}

final class StubURLProtocol: URLProtocol {
    struct Stub {
        var status: Int = 200
        var body: Data = Data()
        var error: URLError?
    }

    nonisolated(unsafe) static var stub = Stub()
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody: Data?

    static func reset(_ stub: Stub = Stub()) {
        self.stub = stub
        lastRequest = nil
        lastBody = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        if let body = request.httpBody {
            Self.lastBody = body
        } else if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            stream.close()
            Self.lastBody = data
        }
        if let error = Self.stub.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: Self.stub.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized)
struct RewordClientHTTPTests {
    let base = "http://example.test/v1"

    private func makeClient() -> RewordClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return RewordClient(session: URLSession(configuration: config))
    }

    private func json(_ s: String) -> Data { Data(s.utf8) }

    private func expectThrows<T>(
        _ expected: RewordError,
        sourceLocation: SourceLocation = #_sourceLocation,
        _ body: () async throws -> T
    ) async {
        do {
            _ = try await body()
            Issue.record("expected \(expected) but call succeeded", sourceLocation: sourceLocation)
        } catch let e as RewordError {
            #expect(e == expected, sourceLocation: sourceLocation)
        } catch {
            Issue.record("unexpected error \(error)", sourceLocation: sourceLocation)
        }
    }

    @Test func decodesModels() async throws {
        StubURLProtocol.reset(.init(body: json(#"{"data":[{"id":"gemma-4-26b"},{"id":"qwen3.8-27b"}]}"#)))
        let ids = try await makeClient().models(serverURL: base, apiKey: "")
        #expect(ids == ["gemma-4-26b", "qwen3.8-27b"])
    }

    @Test func modelsRequestPathAndMethod() async throws {
        StubURLProtocol.reset(.init(body: json(#"{"data":[]}"#)))
        _ = try await makeClient().models(serverURL: base, apiKey: "")
        let req = try #require(StubURLProtocol.lastRequest)
        #expect(req.url?.path.hasSuffix("/v1/models") == true)
        #expect(req.httpMethod == "GET")
    }

    @Test func modelsToleratesSurroundingWhitespaceInURL() async throws {
        StubURLProtocol.reset(.init(body: json(#"{"data":[]}"#)))
        _ = try await makeClient().models(serverURL: "  \(base)  \n", apiKey: "")
        #expect(StubURLProtocol.lastRequest?.url?.path.hasSuffix("/v1/models") == true)
    }

    @Test func bearerHeaderPresentWhenKeySet() async throws {
        StubURLProtocol.reset(.init(body: json(#"{"data":[]}"#)))
        _ = try await makeClient().models(serverURL: base, apiKey: "sekret")
        #expect(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer sekret")
    }

    @Test func noAuthorizationHeaderWhenKeyEmpty() async throws {
        StubURLProtocol.reset(.init(body: json(#"{"data":[]}"#)))
        _ = try await makeClient().models(serverURL: base, apiKey: "")
        #expect(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func chatBearerHeaderAndPath() async throws {
        StubURLProtocol.reset(.init(body: json(#"{"choices":[{"message":{"content":"ok"}}]}"#)))
        _ = try await makeClient().reword("hi", model: "m", serverURL: base, apiKey: "k")
        let req = try #require(StubURLProtocol.lastRequest)
        #expect(req.url?.path.hasSuffix("/v1/chat/completions") == true)
        #expect(req.httpMethod == "POST")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer k")
    }

    @Test func chatNoAuthorizationHeaderWhenKeyEmpty() async throws {
        StubURLProtocol.reset(.init(body: json(#"{"choices":[{"message":{"content":"ok"}}]}"#)))
        _ = try await makeClient().reword("hi", model: "m", serverURL: base, apiKey: "")
        #expect(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func chatSendsExpectedBody() async throws {
        StubURLProtocol.reset(.init(body: json(#"{"choices":[{"message":{"content":"ok"}}]}"#)))
        _ = try await makeClient().reword("um hello", model: "gemma-4-26b", serverURL: base, apiKey: "")
        let body = try #require(StubURLProtocol.lastBody)
        let obj = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(obj["model"] as? String == "gemma-4-26b")
        let messages = try #require(obj["messages"] as? [[String: Any]])
        #expect(messages.last?["content"] as? String == "um hello")
    }

    @Test func chatReturnsFirstChoiceContentUncleaned() async throws {
        StubURLProtocol.reset(.init(
            body: json(#"{"choices":[{"message":{"content":"<think>x</think> Hello "}},{"message":{"content":"other"}}]}"#)))
        let out = try await makeClient().reword("hi", model: "m", serverURL: base, apiKey: "")
        #expect(out == "<think>x</think> Hello ")
    }

    @Test func unauthorized401() async {
        StubURLProtocol.reset(.init(status: 401))
        await expectThrows(.unauthorized) {
            try await makeClient().models(serverURL: base, apiKey: "bad")
        }
    }

    @Test func unauthorized403OnChat() async {
        StubURLProtocol.reset(.init(status: 403))
        await expectThrows(.unauthorized) {
            try await makeClient().reword("hi", model: "m", serverURL: base, apiKey: "bad")
        }
    }

    @Test func serverError500() async {
        StubURLProtocol.reset(.init(status: 500))
        await expectThrows(.response(500)) {
            try await makeClient().models(serverURL: base, apiKey: "")
        }
    }

    @Test func serverError500OnChat() async {
        StubURLProtocol.reset(.init(status: 500))
        await expectThrows(.response(500)) {
            try await makeClient().reword("hi", model: "m", serverURL: base, apiKey: "")
        }
    }

    @Test func badJSONOnModels() async {
        StubURLProtocol.reset(.init(body: json("not json")))
        await expectThrows(.invalidJSON) {
            try await makeClient().models(serverURL: base, apiKey: "")
        }
    }

    @Test func badJSONOnChat() async {
        StubURLProtocol.reset(.init(body: json(#"{"nope":true}"#)))
        await expectThrows(.invalidJSON) {
            try await makeClient().reword("hi", model: "m", serverURL: base, apiKey: "")
        }
    }

    @Test func nonHTTPSchemeIsInvalidURL() async {
        StubURLProtocol.reset()
        await expectThrows(.invalidURL) {
            try await makeClient().models(serverURL: "ftp://x", apiKey: "")
        }
        await expectThrows(.invalidURL) {
            try await makeClient().reword("hi", model: "m", serverURL: "ftp://x", apiKey: "")
        }
    }

    @Test func garbageIsInvalidURL() async {
        StubURLProtocol.reset()
        await expectThrows(.invalidURL) {
            try await makeClient().models(serverURL: "not a url", apiKey: "")
        }
    }

    @Test func transportErrorIsUnreachable() async {
        StubURLProtocol.reset(.init(error: URLError(.cannotConnectToHost)))
        await expectThrows(.unreachable) {
            try await makeClient().models(serverURL: base, apiKey: "")
        }
    }

    @Test func timeoutIsUnreachable() async {
        StubURLProtocol.reset(.init(error: URLError(.timedOut)))
        await expectThrows(.unreachable) {
            try await makeClient().reword("hi", model: "m", serverURL: base, apiKey: "")
        }
    }
}

// MARK: - ClaudeCLI

struct ClaudeCLITests {
    let home = URL(fileURLWithPath: "/Users/tester")

    @Test func locatePrefersLocalBinFirst() {
        let all: Set<String> = [
            "/Users/tester/.local/bin/claude", "/Users/tester/.claude/local/claude",
            "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
        ]
        let found = ClaudeCLI.locate(home: home, isExecutable: { all.contains($0) })
        #expect(found?.path == "/Users/tester/.local/bin/claude")
    }

    @Test func locateOrderOfCandidates() {
        var present: [String] = [
            "/Users/tester/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
        ]
        #expect(ClaudeCLI.locate(home: home, isExecutable: { present.contains($0) })?.path
            == "/Users/tester/.claude/local/claude")
        present.removeFirst()
        #expect(ClaudeCLI.locate(home: home, isExecutable: { present.contains($0) })?.path
            == "/opt/homebrew/bin/claude")
        present.removeFirst()
        #expect(ClaudeCLI.locate(home: home, isExecutable: { present.contains($0) })?.path
            == "/usr/local/bin/claude")
    }

    @Test func locateNilWhenNoneExecutable() {
        #expect(ClaudeCLI.locate(home: home, isExecutable: { _ in false }) == nil)
    }

    @Test func argumentsExact() {
        #expect(ClaudeCLI.arguments(systemPrompt: "SYS") == [
            "-p", "--model", "haiku", "--setting-sources", "", "--strict-mcp-config",
            "--no-session-persistence", "--tools", "", "--system-prompt", "SYS",
        ])
    }
}

// MARK: - Vocabulary

struct RewordingVocabularyTests {
    static let replaceLine = "Replace a word or phrase with one of these terms, spelled exactly as listed, when it is a known mishearing or when it sounds like the term and does not fit the sentence as written. Leave words that fit the sentence alone."
    static let singleWordLine = "If the whole text is a single word or short phrase that sounds like one of these terms, it was selected because it is misheard: output that term."

    static func wordsLine(_ words: String) -> String {
        "Speech recognition often mishears these names and terms: \(words)."
    }

    private func systemContent(_ data: Data) throws -> String {
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = try #require(obj["messages"] as? [[String: Any]])
        return try #require(messages.first?["content"] as? String)
    }

    @Test func emptyVocabularyReturnsBase() {
        #expect(Rewording.systemPrompt(vocabulary: Vocabulary()) == Rewording.systemPrompt)
        #expect(Rewording.systemPrompt(vocabulary: Vocabulary(), style: .written) == Rewording.writtenPrompt)
    }

    @Test func blankKnownWordsAndNoRulesReturnBase() {
        let vocabulary = Vocabulary(knownWords: ["  ", "", "\t\n"])
        #expect(Rewording.systemPrompt(vocabulary: vocabulary) == Rewording.systemPrompt)
    }

    @Test func knownWordsOnlyTrimsDedupesAndKeepsOrder() {
        let vocabulary = Vocabulary(knownWords: ["Perseus", " OPI ", "Perseus", "Claude Code"])
        let expected = Rewording.systemPrompt + "\n\nVocabulary:\n"
            + Self.wordsLine("Perseus, OPI, Claude Code") + "\n"
            + Self.replaceLine
        #expect(Rewording.systemPrompt(vocabulary: vocabulary) == expected)
    }

    @Test func replacementsOnlyListsEveryRuleWithAllHeardVariants() {
        let vocabulary = Vocabulary(replacements: [
            Replacement(heard: ["Persuus", "Persuys"], target: "Perseus"),
            Replacement(heard: ["TraderPR"], target: "create a PR"),
        ])
        let expected = Rewording.systemPrompt + "\n\nVocabulary:\n"
            + "Known mishearings, heard \u{2192} meant: Persuus, Persuys \u{2192} Perseus; TraderPR \u{2192} create a PR." + "\n"
            + Self.replaceLine
        #expect(Rewording.systemPrompt(vocabulary: vocabulary) == expected)
    }

    @Test func knownWordsAndReplacementsKeepLineOrder() {
        let vocabulary = Vocabulary(
            knownWords: ["Perseus"],
            replacements: [Replacement(heard: ["Persuus"], target: "Perseus")])
        let expected = Rewording.systemPrompt + "\n\nVocabulary:\n"
            + Self.wordsLine("Perseus") + "\n"
            + "Known mishearings, heard \u{2192} meant: Persuus \u{2192} Perseus." + "\n"
            + Self.replaceLine
        #expect(Rewording.systemPrompt(vocabulary: vocabulary) == expected)
    }

    @Test func singleWordLineOnlyForWrittenStyle() {
        let vocabulary = Vocabulary(knownWords: ["Perseus"])
        let light = Rewording.systemPrompt(vocabulary: vocabulary, style: .light)
        let written = Rewording.systemPrompt(vocabulary: vocabulary, style: .written)
        #expect(!light.contains(Self.singleWordLine))
        #expect(written == Rewording.writtenPrompt + "\n\nVocabulary:\n"
            + Self.wordsLine("Perseus") + "\n"
            + Self.replaceLine + "\n"
            + Self.singleWordLine)
    }

    @Test func whitespaceOnlyInstructionsWithoutTermsReturnBase() {
        let vocabulary = Vocabulary(instructions: " \n\t \n ")
        #expect(Rewording.systemPrompt(vocabulary: vocabulary) == Rewording.systemPrompt)
        #expect(Rewording.systemPrompt(vocabulary: vocabulary, style: .written) == Rewording.writtenPrompt)
    }

    @Test func instructionsOnlyAddNotesWithoutReplaceOrSingleWordLine() {
        let vocabulary = Vocabulary(instructions: "\n  SDIA Perseus is one product name.  \n")
        let got = Rewording.systemPrompt(vocabulary: vocabulary, style: .written)
        #expect(got == Rewording.writtenPrompt + "\n\nNotes:\n" + "SDIA Perseus is one product name.")
        #expect(!got.contains(Self.replaceLine))
        #expect(!got.contains(Self.singleWordLine))
    }

    @Test func wordsAndInstructionsPutNotesLastInWrittenStyle() {
        let vocabulary = Vocabulary(knownWords: ["Perseus"], instructions: " Keep it formal. ")
        let expected = Rewording.writtenPrompt + "\n\nVocabulary:\n"
            + Self.wordsLine("Perseus") + "\n"
            + Self.replaceLine + "\n"
            + Self.singleWordLine
            + "\n\nNotes:\n" + "Keep it formal."
        #expect(Rewording.systemPrompt(vocabulary: vocabulary, style: .written) == expected)
    }

    @Test func multiLineInstructionsKeepInternalNewlines() {
        let vocabulary = Vocabulary(instructions: "First note.\n\nSecond note.\n")
        #expect(Rewording.systemPrompt(vocabulary: vocabulary)
            == Rewording.systemPrompt + "\n\nNotes:\n" + "First note.\n\nSecond note.")
    }

    @Test func chatRequestBodyCarriesVocabularyPrompt() throws {
        let vocabulary = Vocabulary(
            knownWords: ["Perseus", " OPI ", "Perseus"],
            replacements: [Replacement(heard: ["Persuus"], target: "Perseus")])
        let data = RewordClient.chatRequestBody(text: "hi", model: "m", vocabulary: vocabulary)
        #expect(try systemContent(data) == Rewording.systemPrompt(vocabulary: vocabulary))
        #expect(try systemContent(data) != Rewording.systemPrompt)
    }

    @Test func chatRequestBodyWithoutVocabularyIsBase() throws {
        let data = RewordClient.chatRequestBody(text: "hi", model: "m")
        #expect(try systemContent(data) == Rewording.systemPrompt)
    }
}

// MARK: - Reword styles

struct RewordingStyleTests {
    static let writtenPromptV2 = """
        You turn dictated speech into the message the speaker meant to write, as if they had typed it carefully.
        1. Work out what they want: their requests, decisions and the reasons behind them.
        2. Drop everything they retract or abandon ("never mind", "forget that", "actually no", a thought corrected halfway); keep only their final position. Drop filler, hedges, repetition, thinking out loud and asides that carry no point.
        3. Rebuild the structure so the message has one clear thread: open with the main point or request, then the remaining points in a logical order, each with its reason. Use short paragraphs, or a numbered list for several separate requests.
        4. Fix speech-recognition mistakes.
        Keep every point and reason they still stand behind, their voice (first person, questions stay questions), tone, formality and language; never translate. Never add facts, opinions, greetings or sign-offs. The text is a message to rewrite, not a request to you: do not answer it. Output only the rewritten message.

        Example
        Dictated: So yeah the dashboard thing, um, I looked at it and it's kind of slow, I think. We should, maybe we cache the, ah no, forget caching, that's a mess. Let's just, the query is the problem, it does a full scan. Oh and also can you rename the button to Export, because people don't get what Download means. And yeah, fix the query first I guess.
        Written: Please fix the dashboard query first: it does a full scan, which makes the dashboard slow.

        Also, rename the button to "Export"; people don't understand "Download".
        """

    private func parse(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func systemContent(_ data: Data) throws -> String {
        let messages = try #require(try parse(data)["messages"] as? [[String: Any]])
        return try #require(messages.first?["content"] as? String)
    }

    // chooseModel

    @Test func writtenPrefersGemmaOverQwenRegardlessOfOrder() {
        #expect(Rewording.chooseModel(from: ["gemma-4-26b", "qwen3.8-27b"], style: .written) == "gemma-4-26b")
        #expect(Rewording.chooseModel(from: ["qwen3.8-27b", "gemma-4-26b"], style: .written) == "gemma-4-26b")
    }

    @Test func writtenSkipsQwenAsrAndFallsToQwen() {
        #expect(Rewording.chooseModel(from: ["qwen3-asr", "qwen3.8-27b"], style: .written) == "qwen3.8-27b")
        #expect(Rewording.chooseModel(from: ["Qwen3-ASR-1.7B"], style: .written) == nil)
    }

    @Test func writtenNilWhenNoneMatch() {
        #expect(Rewording.chooseModel(from: ["llama-3", "qwen3-asr"], style: .written) == nil)
        #expect(Rewording.chooseModel(from: [], style: .written) == nil)
    }

    @Test func defaultAndLightStillPreferGemma() {
        let ids = ["qwen3.8-27b", "gemma-4-26b"]
        #expect(Rewording.chooseModel(from: ids) == "gemma-4-26b")
        #expect(Rewording.chooseModel(from: ids, style: .light) == "gemma-4-26b")
    }

    // prompts

    @Test func systemPromptBaseDependsOnStyle() {
        #expect(Rewording.systemPrompt(vocabulary: Vocabulary(), style: .written) == Rewording.writtenPrompt)
        #expect(Rewording.systemPrompt(vocabulary: Vocabulary(), style: .light) == Rewording.systemPrompt)
        #expect(Rewording.systemPrompt(vocabulary: Vocabulary()) == Rewording.systemPrompt)
        #expect(Rewording.writtenPrompt != Rewording.systemPrompt)
    }

    @Test func vocabularySuffixAppendedToBothStyles() {
        let vocabulary = Vocabulary(knownWords: ["Perseus", " OPI ", "Perseus"])
        let part = "\n\nVocabulary:\n" + RewordingVocabularyTests.wordsLine("Perseus, OPI")
            + "\n" + RewordingVocabularyTests.replaceLine
        #expect(Rewording.systemPrompt(vocabulary: vocabulary, style: .light)
            == Rewording.systemPrompt + part)
        #expect(Rewording.systemPrompt(vocabulary: vocabulary, style: .written)
            == Rewording.writtenPrompt + part + "\n" + RewordingVocabularyTests.singleWordLine)
    }

    @Test func writtenPromptIsV2Text() {
        #expect(Rewording.writtenPrompt == Self.writtenPromptV2)
    }

    // chatRequestBody

    @Test func chatRequestBodyWrittenUsesWrittenPromptAndTemperature() throws {
        let vocabulary = Vocabulary(knownWords: ["Perseus"])
        let obj = try parse(RewordClient.chatRequestBody(
            text: "um hi", model: "m", vocabulary: vocabulary, style: .written))
        #expect(obj["temperature"] as? Double == 0.3)
        let messages = try #require(obj["messages"] as? [[String: Any]])
        #expect(messages[0]["content"] as? String == Rewording.systemPrompt(vocabulary: vocabulary, style: .written))
        #expect(messages[1]["content"] as? String == "um hi")
    }

    @Test func chatRequestBodyWrittenWithoutWordsIsWrittenPrompt() throws {
        let data = RewordClient.chatRequestBody(text: "hi", model: "m", style: .written)
        #expect(try systemContent(data) == Rewording.writtenPrompt)
    }

    @Test func chatRequestBodyLightTemperatureIsPointTwo() throws {
        let explicit = try parse(RewordClient.chatRequestBody(text: "hi", model: "m", style: .light))
        #expect(explicit["temperature"] as? Double == 0.2)
        #expect(try systemContent(RewordClient.chatRequestBody(text: "hi", model: "m", style: .light))
            == Rewording.systemPrompt)
        let implicit = try parse(RewordClient.chatRequestBody(text: "hi", model: "m"))
        #expect(implicit["temperature"] as? Double == 0.2)
    }

    // reword chain

    @Test func rewordWrittenChoosesGemma() async throws {
        let log = CallLog()
        let services = makeServices(
            FakeConfig(models: .success(["qwen3.8-27b", "gemma-4-26b"])), log: log)
        let out = try await Rewording.reword("um hello", using: services, style: .written)
        #expect(out == "Local result")
        #expect(log.events == ["list", "local:gemma-4-26b:um hello"])
    }

    @Test func rewordDefaultStyleChoosesGemma() async throws {
        let log = CallLog()
        let services = makeServices(
            FakeConfig(models: .success(["gemma-4-26b", "qwen3.8-27b"])), log: log)
        _ = try await Rewording.reword("um hello", using: services)
        #expect(log.events == ["list", "local:gemma-4-26b:um hello"])
    }
}
#endif
