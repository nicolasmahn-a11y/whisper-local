import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

enum DictationKey: String, CaseIterable, Identifiable {
    case rightAlt = "right_alt"
    case rightCommand = "right_cmd"
    case rightControl = "right_ctrl"
    case rightShift = "right_shift"
    case f13, f14, f15

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rightAlt: "Right Option"
        case .rightCommand: "Right Command"
        case .rightControl: "Right Control"
        case .rightShift: "Right Shift"
        case .f13: "F13"
        case .f14: "F14"
        case .f15: "F15"
        }
    }

    var keyCode: Int {
        switch self {
        case .rightAlt: 61
        case .rightCommand: 54
        case .rightControl: 62
        case .rightShift: 60
        case .f13: 105
        case .f14: 107
        case .f15: 113
        }
    }

    var sideFlag: UInt64? {
        switch self {
        case .rightAlt: 0x40
        case .rightCommand: 0x10
        case .rightControl: 0x2000
        case .rightShift: 0x04
        case .f13, .f14, .f15: nil
        }
    }
}

enum HotkeyInput: Equatable {
    case pressed
    case released
    case handsFreePressed
    case handsFreeReleased
    case otherKeyPressed
    case escapePressed
    case rewordTapped
}

enum HotkeyEventKind {
    case flagsChanged
    case keyDown
    case keyUp
}

struct HotkeyInterpreter {
    var selectedKey: DictationKey
    var handsFreeKey: DictationKey?
    var rewordKey: DictationKey? {
        didSet { activeRewordKey = nil }
    }
    private var activeDictationKey: DictationKey?
    private var activeHandsFreeKey: DictationKey?
    private var activeRewordKey: DictationKey?
    private var rewordInterrupted = false
    private var rewordPressedAt: TimeInterval = 0
    /// Holding the reword key longer than this is not a tap.
    static let tapLimit: TimeInterval = 0.4

    init(selectedKey: DictationKey, handsFreeKey: DictationKey? = nil, rewordKey: DictationKey? = nil) {
        self.selectedKey = selectedKey
        self.handsFreeKey = handsFreeKey
        self.rewordKey = rewordKey
    }

    /// `time` is the event time in seconds; only differences matter.
    mutating func receive(
        kind: HotkeyEventKind, code: Int, flags: UInt64, repeated: Bool = false, time: TimeInterval = 0
    ) -> HotkeyInput? {
        if let key = activeRewordKey, code != key.keyCode,
           kind == .keyDown || (kind == .flagsChanged && Self.isModifierDown(code: code, flags: flags)) {
            rewordInterrupted = true
        }
        if code == 53, kind == .keyDown {
            return repeated ? nil : .escapePressed
        }
        if let key = activeDictationKey, code == key.keyCode {
            if key.isReleased(kind: kind, flags: flags) {
                activeDictationKey = nil
                return .released
            }
            return nil
        }
        if let key = activeHandsFreeKey, code == key.keyCode {
            if key.isReleased(kind: kind, flags: flags) {
                activeHandsFreeKey = nil
                return .handsFreeReleased
            }
            return nil
        }
        if code == selectedKey.keyCode {
            if selectedKey.isPressed(kind: kind, flags: flags, repeated: repeated) {
                activeDictationKey = selectedKey
                return .pressed
            }
            return nil
        }
        if let handsFreeKey, code == handsFreeKey.keyCode {
            if handsFreeKey.isPressed(kind: kind, flags: flags, repeated: repeated) {
                activeHandsFreeKey = handsFreeKey
                return .handsFreePressed
            }
            return nil
        }
        if let rewordKey, code == rewordKey.keyCode {
            if activeRewordKey != nil {
                guard rewordKey.isReleased(kind: kind, flags: flags) else { return nil }
                activeRewordKey = nil
                return rewordInterrupted || time - rewordPressedAt > Self.tapLimit ? nil : .rewordTapped
            }
            if rewordKey.isPressed(kind: kind, flags: flags, repeated: repeated) {
                activeRewordKey = rewordKey
                rewordPressedAt = time
                // Part of a chord when another modifier is already held.
                let others = Self.modifierSideFlags.filter { $0.key != 63 && $0.value != rewordKey.sideFlag }
                rewordInterrupted = others.values.contains { flags & $0 != 0 }
            }
            return nil
        }
        if kind == .keyDown {
            return .otherKeyPressed
        }
        if kind == .flagsChanged, Self.isModifierDown(code: code, flags: flags) {
            return .otherKeyPressed
        }
        return nil
    }

    private static func isModifierDown(code: Int, flags: UInt64) -> Bool {
        // Caps Lock toggles its flag on each press, including when turning it off.
        if code == 57 { return true }
        guard let sideFlag = modifierSideFlags[code] else { return false }
        return flags & sideFlag != 0
    }

    private static let modifierSideFlags: [Int: UInt64] = [
        61: 0x40, 54: 0x10, 62: 0x2000, 60: 0x04,
        58: 0x20, 55: 0x08, 59: 0x01, 56: 0x02,
        63: CGEventFlags.maskSecondaryFn.rawValue,
    ]
}

private extension DictationKey {
    func isPressed(kind: HotkeyEventKind, flags: UInt64, repeated: Bool) -> Bool {
        if let sideFlag { return kind == .flagsChanged && flags & sideFlag != 0 }
        return kind == .keyDown && !repeated
    }

    func isReleased(kind: HotkeyEventKind, flags: UInt64) -> Bool {
        if let sideFlag { return kind == .flagsChanged && flags & sideFlag == 0 }
        return kind == .keyUp
    }
}

private let syntheticEventTag: Int64 = 0x57484C5041535445

final class HotkeyMonitor {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var interpreter: HotkeyInterpreter
    private let onInput: @MainActor (HotkeyInput) -> Void

    init(
        key: DictationKey, handsFreeKey: DictationKey? = nil, rewordKey: DictationKey? = nil,
        onInput: @escaping @MainActor (HotkeyInput) -> Void
    ) {
        interpreter = HotkeyInterpreter(selectedKey: key, handsFreeKey: handsFreeKey, rewordKey: rewordKey)
        self.onInput = onInput
    }

    func setKey(_ key: DictationKey) { interpreter.selectedKey = key }
    func setHandsFreeKey(_ key: DictationKey?) { interpreter.handsFreeKey = key }
    func setRewordKey(_ key: DictationKey?) { interpreter.rewordKey = key }

    func start() -> Bool {
        guard tap == nil else { return true }
        let mask: CGEventMask = [CGEventType.flagsChanged, .keyDown, .keyUp]
            .reduce(0) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: hotkeyCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else { return false }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, CFRunLoopMode.commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        return true
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, CFRunLoopMode.commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        source = nil
        tap = nil
    }

    fileprivate func reenable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    fileprivate func receive(type: CGEventType, event: CGEvent) {
        guard event.getIntegerValueField(.eventSourceUserData) != syntheticEventTag else { return }
        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags.rawValue
        let kind: HotkeyEventKind
        switch type {
        case .flagsChanged: kind = .flagsChanged
        case .keyDown: kind = .keyDown
        case .keyUp: kind = .keyUp
        default: return
        }
        let input = interpreter.receive(
            kind: kind, code: code, flags: flags,
            repeated: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
            time: ProcessInfo.processInfo.systemUptime
        )
        // The tap is on the main run loop; update key state before another task resumes.
        if let input { MainActor.assumeIsolated { onInput(input) } }
    }

    deinit { stop() }
}

private let hotkeyCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    if type == .tapDisabledByTimeout {
        monitor.reenable()
    } else if type == .flagsChanged || type == .keyDown || type == .keyUp {
        monitor.receive(type: type, event: event)
    }
    return Unmanaged.passUnretained(event)
}

enum KeyboardPaste {
    static func paste(_ text: String) throws {
        guard AXIsProcessTrusted() else { throw AppIssue.accessibility }
        let clipboard = NSPasteboard.general
        clipboard.clearContents()
        guard clipboard.setString(text, forType: .string) else { throw AppIssue.clipboard }
        try post(virtualKey: 9)
    }

    /// Cmd+C into the frontmost app; flags are explicit so held modifiers don't leak in.
    static func copySelection() throws {
        guard AXIsProcessTrusted() else { throw AppIssue.accessibility }
        try post(virtualKey: 8)
    }

    static func selectAll() throws {
        guard AXIsProcessTrusted() else { throw AppIssue.accessibility }
        try post(virtualKey: 0)
    }

    /// Right Arrow, collapsing a selection so the next keystroke doesn't replace it.
    static func collapseSelection() throws {
        try post(virtualKey: 124, flags: [])
    }

    private static func post(virtualKey: CGKeyCode, flags: CGEventFlags = .maskCommand) throws {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: virtualKey, keyDown: down) else {
                throw AppIssue.keyboardEvent
            }
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: syntheticEventTag)
            event.post(tap: .cghidEventTap)
        }
    }
}

enum FocusedElement {
    /// nil when Accessibility can't tell (some Electron apps).
    static func isEditableText() -> Bool? {
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &focused
        ) == .success, let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        var role: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
           let role = role as? String,
           [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField"].contains(role) {
            return true
        }
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, kAXSelectedTextRangeAttribute as CFString, &settable) == .success
            && settable.boolValue
    }
}
