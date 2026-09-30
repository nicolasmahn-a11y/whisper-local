import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import ServiceManagement
import SwiftUI

enum SettingsPane: Equatable {
    case inputMonitoring
    case accessibility
    case microphone

    var url: URL? {
        let anchor: String
        switch self {
        case .inputMonitoring: anchor = "Privacy_ListenEvent"
        case .accessibility: anchor = "Privacy_Accessibility"
        case .microphone: anchor = "Privacy_Microphone"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
    }
}

struct Problem: Equatable {
    let text: String
    let pane: SettingsPane?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.text == rhs.text && lhs.pane == rhs.pane
    }
}

enum AppIssue: LocalizedError {
    case inputMonitoring
    case accessibility
    case microphone
    case clipboard
    case keyboardEvent
    case eventTap
    case apiKey
    case launchAtLogin
    case recordingMissing

    var errorDescription: String? {
        switch self {
        case .inputMonitoring: "Input Monitoring needed"
        case .accessibility: "Accessibility access needed"
        case .microphone: "Microphone access needed"
        case .clipboard: "Could not copy transcript"
        case .keyboardEvent: "Could not paste transcript"
        case .eventTap: "Could not monitor keyboard"
        case .apiKey: "Could not save API key"
        case .launchAtLogin: "Could not change launch at login"
        case .recordingMissing: "Recording no longer available"
        }
    }

    var pane: SettingsPane? {
        switch self {
        case .inputMonitoring, .eventTap: .inputMonitoring
        case .accessibility: .accessibility
        case .microphone: .microphone
        case .clipboard, .keyboardEvent, .apiKey, .launchAtLogin, .recordingMissing: nil
        }
    }
}

/// A transcription failed but its audio is in the recording cache.
struct RecordingSaved: Error {
    let underlying: Error
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var state: DictationState = .idle {
        didSet {
            if state != oldValue {
                level = 0
                lastLevelAt = nil
                updateOverlay()
            }
        }
    }
    @Published private(set) var recentTranscripts: [String] = []
    @Published private(set) var unsentRecordings: [CachedRecording] = []
    @Published private(set) var problem: Problem? = nil
    @Published private(set) var serverReachable: Bool? = nil
    @Published private(set) var launchAtLogin: Bool

    @Published var enabled: Bool {
        didSet {
            defaults.set(enabled, forKey: "enabled")
            dictation.enabled = enabled && permissionProblem == nil
        }
    }
    @Published var serverURL: String {
        didSet { defaults.set(serverURL, forKey: "serverURL") }
    }
    @Published var key: DictationKey {
        didSet {
            if handsFreeKey == key { handsFreeKey = nil }
            defaults.set(key.rawValue, forKey: "dictationKey")
            hotkey?.setKey(key)
            updateOverlay()
        }
    }
    @Published var handsFreeKey: DictationKey? {
        didSet {
            defaults.set(handsFreeKey?.rawValue ?? "", forKey: "handsFreeKey")
            hotkey?.setHandsFreeKey(handsFreeKey)
            dictation.usesDedicatedHandsFreeKey = handsFreeKey != nil
            updateOverlay()
        }
    }
    @Published var language: String {
        didSet { defaults.set(language, forKey: "language") }
    }
    @Published var knownWords: [String] {
        didSet { defaults.set(knownWords, forKey: "knownWords") }
    }
    @Published var replacements: [String] {
        didSet { defaults.set(replacements, forKey: "replacements") }
    }
    @Published var sounds: Bool {
        didSet { defaults.set(sounds, forKey: "sounds") }
    }
    @Published private(set) var apiKey: String

    private let defaults = UserDefaults.standard
    private lazy var recorder = AudioRecorder(onLevel: { [weak self] level in
        Task { @MainActor [weak self] in self?.receiveLevel(level) }
    })
    private let client = TranscriptionClient()
    private let cache = RecordingCache(directory: RecordingCache.defaultDirectory())
    private var overlay: DictationOverlay?
    private var hotkey: HotkeyMonitor?
    private var permissionProblem: Problem?
    private var transientProblem: Problem?
    private var clearProblemTask: Task<Void, Never>?
    private var notice: String?
    private var clearNoticeTask: Task<Void, Never>?
    private var uploadingIDs: Set<String> = []
    private var retryingIDs: Set<String> = [] {
        didSet { updateOverlay() }
    }
    private var level = 0.0
    private var lastLevelAt: TimeInterval?
    private var started = false
    private var refreshTask: Task<Void, Never>?

    private lazy var dictation: Dictation = {
        let dictation = Dictation(services: DictationServices(
            startRecording: { [recorder] in try recorder.start() },
            stopRecording: { [recorder] in try recorder.stop() },
            cancelRecording: { [recorder] in recorder.cancel() },
            transcribe: { [weak self] wav in
                guard let self else { throw CancellationError() }
                return try await self.transcribeKeepingAudio(wav)
            },
            paste: { text in try KeyboardPaste.paste(text) },
            cue: { [weak self] cue in self?.play(cue) },
            clock: { ProcessInfo.processInfo.systemUptime }
        ))
        dictation.enabled = enabled
        dictation.usesDedicatedHandsFreeKey = handsFreeKey != nil
        dictation.onState = { [weak self] in self?.state = $0 }
        dictation.onTranscript = { [weak self] text in
            guard let self else { return }
            self.recentTranscripts = Array(([text] + self.recentTranscripts).prefix(5))
        }
        dictation.onError = { [weak self] in self?.report($0) }
        return dictation
    }()

    init() {
        let stored = UserDefaults.standard
        enabled = stored.object(forKey: "enabled") as? Bool ?? true
        serverURL = stored.string(forKey: "serverURL") ?? "http://localhost:8178/v1"
        let storedKey = DictationKey(rawValue: stored.string(forKey: "dictationKey") ?? "") ?? .rightAlt
        key = storedKey
        let storedHandsFreeKey = DictationKey(rawValue: stored.string(forKey: "handsFreeKey") ?? "")
        handsFreeKey = storedHandsFreeKey == storedKey ? nil : storedHandsFreeKey
        language = stored.string(forKey: "language") ?? ""
        knownWords = stored.stringArray(forKey: "knownWords") ?? []
        replacements = stored.stringArray(forKey: "replacements") ?? []
        sounds = stored.object(forKey: "sounds") as? Bool ?? true
        apiKey = Keychain.apiKey() ?? ""
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled || status == .requiresApproval
        Task { [weak self] in await self?.start() }
    }

    func start() async {
        guard !started else { return }
        started = true
        _ = dictation
        overlay = DictationOverlay()
        updateOverlay()
        refreshRecordings()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self else { return }
                self.refreshRecordings()
            }
        }
        await refreshPermissions(prompt: true)
        await checkReachability()
        refreshRecordings()
        if !unsentRecordings.isEmpty { offerUnsentRecordings() }
    }

    func retry(_ recording: CachedRecording) async {
        _ = await retryRecording(recording)
    }

    func discard(_ recording: CachedRecording) {
        cache.remove(recording)
        refreshRecordings()
    }

    private func retryRecording(_ recording: CachedRecording) async -> Bool {
        guard !retryingIDs.contains(recording.id) else { return false }
        retryingIDs.insert(recording.id)
        defer { retryingIDs.remove(recording.id) }
        let wav: Data
        do {
            wav = try cache.load(recording)
        } catch {
            refreshRecordings()
            report(AppIssue.recordingMissing)
            return false
        }
        do {
            let text = try await send(wav)
            cache.remove(recording)
            refreshRecordings()
            if text.isEmpty {
                show(notice: "No speech in recording")
            } else {
                recentTranscripts = Array(([text] + recentTranscripts).prefix(5))
                if copy(text) { show(notice: "Transcript copied") }
            }
            return true
        } catch {
            if !FileManager.default.fileExists(atPath: recording.url.path) {
                guard (try? cache.save(wav)) != nil else {
                    refreshRecordings()
                    report(error)
                    return false
                }
            }
            refreshRecordings()
            report(RecordingSaved(underlying: error))
            return false
        }
    }

    private func transcribeKeepingAudio(_ wav: Data) async throws -> String {
        let saved = try? cache.save(wav)
        if let saved { uploadingIDs.insert(saved.id) }
        defer {
            if let saved { uploadingIDs.remove(saved.id) }
            refreshRecordings()
        }
        do {
            let text = try await send(wav)
            if let saved { cache.remove(saved) }
            return text
        } catch {
            guard let saved else { throw error }
            if !FileManager.default.fileExists(atPath: saved.url.path) {
                guard (try? cache.save(wav)) != nil else { throw error }
            }
            throw RecordingSaved(underlying: error)
        }
    }

    private func send(_ wav: Data) async throws -> String {
        let text = try await client.transcribe(
            wav: wav, serverURL: serverURL, apiKey: apiKey,
            language: language, knownWords: knownWords
        )
        return Replacements.apply(Replacements.rules(from: replacements), to: text)
    }

    private func refreshRecordings() {
        unsentRecordings = cache.recordings(protecting: uploadingIDs.union(retryingIDs))
            .filter { !uploadingIDs.contains($0.id) }
    }

    private func offerUnsentRecordings() {
        let recordings = unsentRecordings
        guard let newest = recordings.first, let oldest = recordings.last else { return }
        let alert = NSAlert()
        if recordings.count == 1 {
            alert.messageText = "Unsent recording found"
            alert.informativeText = "Audio recorded \(RecordingFormat.ago(newest.recordedAt)) "
                + "(\(RecordingFormat.elapsed(newest.duration))) wasn't transcribed. "
                + "The transcript will be copied to the clipboard."
        } else {
            alert.messageText = "\(recordings.count) unsent recordings found"
            alert.informativeText = "Audio recorded between \(RecordingFormat.ago(oldest.recordedAt)) "
                + "and \(RecordingFormat.ago(newest.recordedAt)) wasn't transcribed. "
                + "Each transcript will be copied to the clipboard."
        }
        alert.addButton(withTitle: "Transcribe")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Discard")
        alert.buttons.last?.hasDestructiveAction = true
        if #unavailable(macOS 15) {
            NSApp.activate(ignoringOtherApps: true)
        } else {
            NSApp.activate()
        }
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Task { [weak self] in
                for recording in recordings.reversed() {
                    guard let self, await self.retryRecording(recording) else { return }
                }
            }
        case .alertThirdButtonReturn:
            recordings.forEach(cache.remove)
            refreshRecordings()
        default:
            break
        }
    }

    func refreshPermissions(prompt: Bool = false) async {
        var canListen = CGPreflightListenEventAccess()
        if !canListen && prompt { canListen = CGRequestListenEventAccess() }

        let axOptions = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        let canPost = AXIsProcessTrustedWithOptions(axOptions)

        let microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        var canRecord = microphoneStatus == .authorized
        if microphoneStatus == .notDetermined && prompt {
            canRecord = await AVCaptureDevice.requestAccess(for: .audio)
        }

        if canListen {
            if hotkey == nil {
                hotkey = HotkeyMonitor(key: key, handsFreeKey: handsFreeKey) { [weak self] input in
                    guard let self else { return }
                    switch input {
                    case .pressed: self.dictation.pressed()
                    case .released: self.dictation.released()
                    case .handsFreePressed: self.dictation.handsFreePressed()
                    case .handsFreeReleased: self.dictation.handsFreeReleased()
                    case .otherKeyPressed: self.dictation.interrupted()
                    case .escapePressed:
                        self.dictation.escaped()
                        self.dictation.interrupted()
                    }
                }
            }
            if hotkey?.start() != true { permissionProblem = problem(for: .eventTap) }
            else if !canPost { permissionProblem = problem(for: .accessibility) }
            else if !canRecord { permissionProblem = problem(for: .microphone) }
            else { permissionProblem = nil }
        } else {
            hotkey?.stop()
            permissionProblem = problem(for: .inputMonitoring)
        }
        publishProblem()
        dictation.enabled = enabled && permissionProblem == nil
    }

    func checkReachability() async {
        serverReachable = nil
        serverReachable = await client.reachable(serverURL: serverURL)
    }

    func updateAPIKey(_ value: String) {
        do {
            try Keychain.setAPIKey(value)
            apiKey = value
        } catch {
            report(AppIssue.apiKey)
        }
    }

    func setLaunchAtLogin(_ value: Bool) {
        do {
            if value { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            let status = SMAppService.mainApp.status
            launchAtLogin = status == .enabled || status == .requiresApproval
        } catch {
            report(AppIssue.launchAtLogin)
        }
    }

    func copyTranscript(_ text: String) {
        _ = copy(text)
    }

    private func copy(_ text: String) -> Bool {
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(text, forType: .string) else {
            report(AppIssue.clipboard)
            return false
        }
        return true
    }

    func openProblemSettings() {
        guard let pane = problem?.pane, let url = pane.url else { return }
        NSWorkspace.shared.open(url)
    }

    private func report(_ error: Error) {
        let issue = error as? AppIssue
        let message: String
        switch error {
        case let saved as RecordingSaved:
            let reason = saved.underlying is SpeechError
                ? Self.message(for: saved.underlying) : "Transcription failed"
            message = "\(reason) — recording saved"
        default: message = Self.message(for: error)
        }
        if let issue, issue.pane != nil {
            permissionProblem = Problem(text: message, pane: issue.pane)
        }
        transientProblem = Problem(text: message, pane: nil)
        notice = nil
        clearNoticeTask?.cancel()
        let seconds = error is RecordingSaved ? 8 : 5
        clearProblemTask?.cancel()
        clearProblemTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.transientProblem = nil
            self?.publishProblem()
        }
        publishProblem()
    }

    private static func message(for error: Error) -> String {
        switch error {
        case let known as AppIssue: known.localizedDescription
        case let known as SpeechError: known.localizedDescription
        case let known as RecordingError: known.localizedDescription
        default: "Operation failed"
        }
    }

    private func show(notice text: String) {
        notice = text
        if transientProblem != nil {
            clearProblemTask?.cancel()
            transientProblem = nil
            publishProblem()
        }
        clearNoticeTask?.cancel()
        clearNoticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.notice = nil
            self?.updateOverlay()
        }
        updateOverlay()
    }

    private func publishProblem() {
        problem = permissionProblem ?? transientProblem
        updateOverlay()
    }

    private func receiveLevel(_ newLevel: Double) {
        guard state == .listening || state == .handsFree else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let lastLevelAt, now - lastLevelAt < 0.04 { return }
        lastLevelAt = now
        level = newLevel
        updateOverlay()
    }

    private func updateOverlay() {
        let message = transientProblem.map { OverlayMessage.error($0.text) }
            ?? notice.map { OverlayMessage.notice($0) }
        overlay?.update(
            state: state == .idle && !retryingIDs.isEmpty ? .transcribing : state,
            level: level, keyName: (handsFreeKey ?? key).title, message: message
        )
    }

    private func problem(for issue: AppIssue) -> Problem {
        Problem(text: issue.localizedDescription, pane: issue.pane)
    }

    private func play(_ cue: Cue) {
        guard sounds else { return }
        switch cue {
        case .start: playSound("Tink")
        case .stop: playSound("Pop")
        case .error:
            playSound("Basso")
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 220_000_000)
                self?.playSound("Basso")
            }
        }
    }

    private func playSound(_ name: String) {
        guard sounds else { return }
        (NSSound(named: NSSound.Name(name))?.copy() as? NSSound)?.play()
    }
}
