#if canImport(Testing)
import Foundation
import Testing
@testable import WhisperLocal

struct PreRollBufferTests {
    private func ramp(_ range: ClosedRange<Int>) -> [Int16] {
        range.map { Int16($0) }
    }

    @Test func startsEmptyAndKeepsCapacity() {
        let buf = PreRollBuffer(capacitySamples: 10)
        #expect(buf.capacitySamples == 10)
        #expect(buf.count == 0)
        #expect(buf.snapshot() == [])
    }

    @Test func appendUnderCapacityKeepsAll() {
        var buf = PreRollBuffer(capacitySamples: 10)
        buf.append(ramp(1...4))
        #expect(buf.count == 4)
        #expect(buf.snapshot() == ramp(1...4))
    }

    @Test func appendExactlyCapacity() {
        var buf = PreRollBuffer(capacitySamples: 5)
        buf.append(ramp(1...5))
        #expect(buf.count == 5)
        #expect(buf.snapshot() == ramp(1...5))
    }

    @Test func appendOverCapacityDropsOldest() {
        var buf = PreRollBuffer(capacitySamples: 5)
        buf.append(ramp(1...3))
        buf.append(ramp(4...7))
        #expect(buf.count == 5)
        #expect(buf.snapshot() == ramp(3...7))
    }

    @Test func singleAppendLargerThanCapacityKeepsNewestTail() {
        var buf = PreRollBuffer(capacitySamples: 4)
        buf.append(ramp(1...10))
        #expect(buf.count == 4)
        #expect(buf.snapshot() == ramp(7...10))
    }

    @Test func largeAppendReplacesExistingContent() {
        var buf = PreRollBuffer(capacitySamples: 4)
        buf.append([100, 101])
        buf.append(ramp(1...9))
        #expect(buf.snapshot() == ramp(6...9))
    }

    @Test func manySmallAppendsWrapInOrder() {
        var buf = PreRollBuffer(capacitySamples: 7)
        for i in 1...50 { buf.append([Int16(i)]) }
        #expect(buf.count == 7)
        #expect(buf.snapshot() == ramp(44...50))
    }

    @Test func manyUnevenAppendsWrapInOrder() {
        var buf = PreRollBuffer(capacitySamples: 8)
        var next = 1
        for size in [3, 1, 5, 2, 7, 4, 1, 6, 3] {
            buf.append(ramp(next...(next + size - 1)))
            next += size
        }
        let last = next - 1
        #expect(buf.count == 8)
        #expect(buf.snapshot() == ramp((last - 7)...last))
    }

    @Test func appendEmptyIsNoOp() {
        var buf = PreRollBuffer(capacitySamples: 5)
        buf.append(ramp(1...3))
        buf.append([])
        #expect(buf.snapshot() == ramp(1...3))
    }

    @Test func snapshotDoesNotMutate() {
        var buf = PreRollBuffer(capacitySamples: 5)
        buf.append(ramp(1...3))
        _ = buf.snapshot()
        #expect(buf.snapshot() == ramp(1...3))
        #expect(buf.count == 3)
    }

    @Test func removeAllEmptiesButKeepsCapacity() {
        var buf = PreRollBuffer(capacitySamples: 5)
        buf.append(ramp(1...9))
        buf.removeAll()
        #expect(buf.count == 0)
        #expect(buf.snapshot() == [])
        #expect(buf.capacitySamples == 5)
    }

    @Test func usableAfterRemoveAll() {
        var buf = PreRollBuffer(capacitySamples: 4)
        buf.append(ramp(1...9))
        buf.removeAll()
        buf.append([1, 2])
        #expect(buf.snapshot() == [1, 2])
        buf.append(ramp(3...6))
        #expect(buf.snapshot() == ramp(3...6))
    }

    @Test func capacityZeroHoldsNothing() {
        var buf = PreRollBuffer(capacitySamples: 0)
        buf.append(ramp(1...5))
        buf.append([9])
        #expect(buf.capacitySamples == 0)
        #expect(buf.count == 0)
        #expect(buf.snapshot() == [])
        buf.removeAll()
        #expect(buf.count == 0)
    }

    @Test func appCapacityHoldsThreeQuartersSecond() {
        var buf = PreRollBuffer(capacitySamples: 12_000)
        buf.append([Int16](repeating: 1, count: 20_000))
        #expect(buf.count == 12_000)
    }
}

struct WarmMicPolicyTests {
    @Test func disabledIsNeverWarm() {
        let p = WarmMicPolicy(enabled: false)
        #expect(p.shouldBeWarm(lastRecordingEnded: 100, now: 101) == false)
    }

    @Test func noRecordingYetIsNotWarm() {
        let p = WarmMicPolicy(enabled: true)
        #expect(p.shouldBeWarm(lastRecordingEnded: nil, now: 100) == false)
    }

    @Test func withinWindowIsWarm() {
        let p = WarmMicPolicy(enabled: true)
        #expect(p.shouldBeWarm(lastRecordingEnded: 1000, now: 1000 + 1800))
        #expect(p.shouldBeWarm(lastRecordingEnded: 1000, now: 1000 + 3599.9))
    }

    @Test func immediatelyAfterRecordingIsWarm() {
        let p = WarmMicPolicy(enabled: true)
        #expect(p.shouldBeWarm(lastRecordingEnded: 1000, now: 1000))
    }

    @Test func exactlyAtWindowIsNotWarm() {
        let p = WarmMicPolicy(enabled: true)
        #expect(p.shouldBeWarm(lastRecordingEnded: 1000, now: 1000 + 3600) == false)
    }

    @Test func pastWindowIsNotWarm() {
        let p = WarmMicPolicy(enabled: true)
        #expect(p.shouldBeWarm(lastRecordingEnded: 1000, now: 1000 + 7200) == false)
    }

    @Test func nowBeforeLastIsNotWarm() {
        let p = WarmMicPolicy(enabled: true)
        #expect(p.shouldBeWarm(lastRecordingEnded: 1000, now: 999) == false)
    }

    @Test func defaultWindowIsOneHour() {
        let p = WarmMicPolicy(enabled: true)
        #expect(p.window == 3600)
    }

    @Test func coolDownAtIsLastPlusWindow() {
        let p = WarmMicPolicy(enabled: true)
        #expect(p.coolDownAt(lastRecordingEnded: 1000) == 4600)
    }

    @Test func customWindow() {
        var p = WarmMicPolicy(enabled: true)
        p.window = 60
        #expect(p.shouldBeWarm(lastRecordingEnded: 10, now: 69.9))
        #expect(p.shouldBeWarm(lastRecordingEnded: 10, now: 70) == false)
        #expect(p.coolDownAt(lastRecordingEnded: 10) == 70)
    }

    @Test func coolDownAtIsExactBoundaryOfShouldBeWarm() {
        var p = WarmMicPolicy(enabled: true)
        p.window = 90
        let last: TimeInterval = 500
        let end = p.coolDownAt(lastRecordingEnded: last)
        #expect(p.shouldBeWarm(lastRecordingEnded: last, now: end - 0.001))
        #expect(p.shouldBeWarm(lastRecordingEnded: last, now: end) == false)
    }
}
#endif
