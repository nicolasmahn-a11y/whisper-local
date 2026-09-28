#if canImport(Testing)
import Testing
import Foundation
@testable import WhisperLocal

struct TranscriptionClientTimeoutTests {
    @Test func zeroSecondsOfAudioIsSixtySecondTimeout() {
        let wav = WAV.encode(pcm16: Data())
        #expect(TranscriptionClient.timeout(forWAV: wav) == 60)
    }

    @Test func tenSecondsOfAudioIsEightySecondTimeout() {
        let wav = WAV.encode(pcm16: Data(count: 16_000 * 2 * 10))
        #expect(TranscriptionClient.timeout(forWAV: wav) == 80)
    }
}
#endif
