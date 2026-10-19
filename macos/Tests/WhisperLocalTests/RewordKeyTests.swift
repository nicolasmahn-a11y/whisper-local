#if canImport(Testing)
import Testing
@testable import WhisperLocal

@Suite struct RewordKeyTests {
    // Real events carry device-independent mask bits next to the side bit.
    static let cmdDown: UInt64 = 0x10 | 0x100000
    static let optDown: UInt64 = 0x40 | 0x80000
    static let shiftDown: UInt64 = 0x02 | 0x20000

    @Test func rightCommandTapEmitsRewordTapped() {
        var h = HotkeyInterpreter(selectedKey: .rightAlt, rewordKey: .rightCommand)
        #expect(h.receive(kind: .flagsChanged, code: 54, flags: Self.cmdDown) == nil)
        #expect(h.receive(kind: .flagsChanged, code: 54, flags: 0) == .rewordTapped)
    }

    @Test func rightCommandPlusLetterIsNotATap() {
        var h = HotkeyInterpreter(selectedKey: .rightAlt, rewordKey: .rightCommand)
        #expect(h.receive(kind: .flagsChanged, code: 54, flags: Self.cmdDown) == nil)
        #expect(h.receive(kind: .keyDown, code: 8, flags: Self.cmdDown) == .otherKeyPressed)
        #expect(h.receive(kind: .keyUp, code: 8, flags: Self.cmdDown) == nil)
        #expect(h.receive(kind: .flagsChanged, code: 54, flags: 0) == nil)
    }

    @Test func otherModifierDownWhileHeldCancelsTap() {
        var h = HotkeyInterpreter(selectedKey: .rightAlt, rewordKey: .rightCommand)
        #expect(h.receive(kind: .flagsChanged, code: 54, flags: Self.cmdDown) == nil)
        #expect(h.receive(kind: .flagsChanged, code: 56, flags: Self.cmdDown | Self.shiftDown) == .otherKeyPressed)
        #expect(h.receive(kind: .flagsChanged, code: 56, flags: Self.cmdDown) == nil)
        #expect(h.receive(kind: .flagsChanged, code: 54, flags: 0) == nil)
    }

    @Test func functionKeyTapEmitsRewordTapped() {
        var h = HotkeyInterpreter(selectedKey: .rightAlt, rewordKey: .f13)
        #expect(h.receive(kind: .keyDown, code: 105, flags: 0) == nil)
        #expect(h.receive(kind: .keyUp, code: 105, flags: 0) == .rewordTapped)
    }

    @Test func functionKeyRepeatIsIgnored() {
        var h = HotkeyInterpreter(selectedKey: .rightAlt, rewordKey: .f13)
        #expect(h.receive(kind: .keyDown, code: 105, flags: 0) == nil)
        #expect(h.receive(kind: .keyDown, code: 105, flags: 0, repeated: true) == nil)
        #expect(h.receive(kind: .keyUp, code: 105, flags: 0) == .rewordTapped)
    }

    @Test func functionKeyWithOtherKeyInBetweenIsNotATap() {
        var h = HotkeyInterpreter(selectedKey: .rightAlt, rewordKey: .f13)
        #expect(h.receive(kind: .keyDown, code: 105, flags: 0) == nil)
        #expect(h.receive(kind: .keyDown, code: 8, flags: 0) == .otherKeyPressed)
        #expect(h.receive(kind: .keyUp, code: 105, flags: 0) == nil)
    }

    @Test func twoTapsInARowBothFire() {
        var h = HotkeyInterpreter(selectedKey: .rightAlt, rewordKey: .rightCommand)
        for _ in 0..<2 {
            #expect(h.receive(kind: .flagsChanged, code: 54, flags: Self.cmdDown) == nil)
            #expect(h.receive(kind: .flagsChanged, code: 54, flags: 0) == .rewordTapped)
        }
    }

    @Test func cancelledTapDoesNotPoisonNextTap() {
        var h = HotkeyInterpreter(selectedKey: .rightAlt, rewordKey: .rightCommand)
        #expect(h.receive(kind: .flagsChanged, code: 54, flags: Self.cmdDown) == nil)
        #expect(h.receive(kind: .keyDown, code: 8, flags: Self.cmdDown) == .otherKeyPressed)
        #expect(h.receive(kind: .flagsChanged, code: 54, flags: 0) == nil)
        #expect(h.receive(kind: .flagsChanged, code: 54, flags: Self.cmdDown) == nil)
        #expect(h.receive(kind: .flagsChanged, code: 54, flags: 0) == .rewordTapped)
    }

    @Test func escapeStillReportedWhileRewordKeyHeld() {
        var h = HotkeyInterpreter(selectedKey: .rightAlt, rewordKey: .rightCommand)
        #expect(h.receive(kind: .flagsChanged, code: 54, flags: Self.cmdDown) == nil)
        #expect(h.receive(kind: .keyDown, code: 53, flags: Self.cmdDown) == .escapePressed)
        #expect(h.receive(kind: .flagsChanged, code: 54, flags: 0) == nil)
    }

    @Test func noRewordKeyLeavesKeyBehaviourUnchanged() {
        var h = HotkeyInterpreter(selectedKey: .rightAlt)
        #expect(h.receive(kind: .flagsChanged, code: 54, flags: Self.cmdDown) == .otherKeyPressed)
        #expect(h.receive(kind: .flagsChanged, code: 54, flags: 0) == nil)
    }

    @Test func rewordKeyCanBeChangedViaProperty() {
        var h = HotkeyInterpreter(selectedKey: .rightAlt)
        h.rewordKey = .f14
        #expect(h.receive(kind: .keyDown, code: 107, flags: 0) == nil)
        #expect(h.receive(kind: .keyUp, code: 107, flags: 0) == .rewordTapped)
        h.rewordKey = .rightCommand
        #expect(h.receive(kind: .flagsChanged, code: 54, flags: Self.cmdDown) == nil)
        #expect(h.receive(kind: .flagsChanged, code: 54, flags: 0) == .rewordTapped)
        h.rewordKey = nil
        #expect(h.receive(kind: .keyDown, code: 107, flags: 0) != .rewordTapped)
        #expect(h.receive(kind: .keyUp, code: 107, flags: 0) != .rewordTapped)
    }

    @Test func dictationKeyStillPressesAndReleasesWithRewordKeySet() {
        var h = HotkeyInterpreter(selectedKey: .rightAlt, rewordKey: .rightCommand)
        #expect(h.receive(kind: .flagsChanged, code: 61, flags: Self.optDown) == .pressed)
        #expect(h.receive(kind: .flagsChanged, code: 61, flags: 0) == .released)
    }

    @Test func shortHoldIsATap() {
        var h = HotkeyInterpreter(selectedKey: .rightAlt, rewordKey: .rightCommand)
        #expect(h.receive(kind: .flagsChanged, code: 54, flags: Self.cmdDown, time: 10) == nil)
        #expect(h.receive(kind: .flagsChanged, code: 54, flags: 0, time: 10.3) == .rewordTapped)
    }

    @Test func longHoldIsNotATap() {
        var h = HotkeyInterpreter(selectedKey: .rightAlt, rewordKey: .rightCommand)
        #expect(h.receive(kind: .flagsChanged, code: 54, flags: Self.cmdDown, time: 10) == nil)
        #expect(h.receive(kind: .flagsChanged, code: 54, flags: 0, time: 10.5) == nil)
        #expect(h.receive(kind: .flagsChanged, code: 54, flags: Self.cmdDown, time: 11) == nil)
        #expect(h.receive(kind: .flagsChanged, code: 54, flags: 0, time: 11.1) == .rewordTapped)
    }

    @Test func tapWhileOtherModifierAlreadyHeldIsNotATap() {
        var h = HotkeyInterpreter(selectedKey: .rightAlt, rewordKey: .rightCommand)
        let leftCmd: UInt64 = 0x08 | 0x100000
        #expect(h.receive(kind: .flagsChanged, code: 55, flags: leftCmd) == .otherKeyPressed)
        #expect(h.receive(kind: .flagsChanged, code: 54, flags: leftCmd | Self.cmdDown) == nil)
        #expect(h.receive(kind: .flagsChanged, code: 54, flags: leftCmd) == nil)
        #expect(h.receive(kind: .flagsChanged, code: 55, flags: 0) == nil)
        #expect(h.receive(kind: .flagsChanged, code: 54, flags: Self.cmdDown) == nil)
        #expect(h.receive(kind: .flagsChanged, code: 54, flags: 0) == .rewordTapped)
    }
}
#endif
