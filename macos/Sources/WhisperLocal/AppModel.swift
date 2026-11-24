import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import OSLog
import ServiceManagement
import SwiftUI

/// `log stream --predicate 'subsystem == "io.github.nicolasmahn.WhisperLocal"'` shows how long qwen3-omni-30b took, or why it failed.
private let heardLog = Logger(subsystem: "io.github.nicolasmahn.WhisperLocal", category: "heard")

enum SettingsPane: Equatable {
    case inputMonitoring
    case accessibility
    case microphone
    case screenRecording

    var url: URL? {
        let anchor: String
        switch self {
        case .inputMonitoring: anchor = "Privacy_ListenEvent"
        case .accessibility: anchor = "Privacy_Accessibility"
        case .microphone: anchor = "Privacy_Microphone"
        case .screenRecording: anchor = "Privacy_ScreenCapture"
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
                if state != .idle { dictationActivity += 1 }
                level = 0
                lastLevelAt = nil
                updateOverlay()
            }
        }
    }
    @Published private(set) var unsentRecordings: [CachedRecording] = []
    @Published private(set) var recentRecordings: [CachedRecording] = []
    @Published private(set) var problem: Problem? = nil
    /// Separate from `problem`: screenshots are optional, so dictation and the menu bar icon stay normal.
    @Published private(set) var screenProblem: Problem? = nil
    @Published private(set) var serverReachable: Bool? = nil
    @Published private(set) var launchAtLogin: Bool

    @Published var enabled: Bool {
        didSet {
            defaults.set(enabled, forKey: "enabled")
            dictation.enabled = enabled && permissionProblem == nil
            if !enabled { coolDownMic() }
        }
    }
    @Published var serverURL: String {
        didSet { defaults.set(serverURL, forKey: "serverURL") }
    }
    @Published var key: DictationKey {
        didSet {
            if handsFreeKey == key { handsFreeKey = nil }
            if rewordKey == key { rewordKey = nil }
            defaults.set(key.rawValue, forKey: "dictationKey")
            hotkey?.setKey(key)
            updateOverlay()
        }
    }
    @Published var handsFreeKey: DictationKey? {
        didSet {
            if rewordKey != nil, rewordKey == handsFreeKey { rewordKey = nil }
            defaults.set(handsFreeKey?.rawValue ?? "", forKey: "handsFreeKey")
            hotkey?.setHandsFreeKey(handsFreeKey)
            dictation.usesDedicatedHandsFreeKey = handsFreeKey != nil
            updateOverlay()
        }
    }
    @Published var rewordKey: DictationKey? {
        didSet {
            defaults.set(rewordKey?.rawValue ?? "", forKey: "rewordKey")
            hotkey?.setRewordKey(rewordKey)
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
    @Published var rewordInstructions: String {
        didSet { defaults.set(rewordInstructions, forKey: "rewordInstructions") }
    }
    @Published var keepMicReady: Bool {
        didSet {
            defaults.set(keepMicReady, forKey: "keepMicReady")
            if !keepMicReady { coolDownMic() }
        }
    }
    @Published private(set) var micWarm = false
    @Published var sounds: Bool {
        didSet { defaults.set(sounds, forKey: "sounds") }
    }
    @Published private(set) var apiKey: String
    @Published var rewordServerURL: String {
        didSet {
            defaults.set(rewordServerURL, forKey: "rewordServerURL")
            rewordModels.removeAll()
        }
    }
    @Published var rewordScreenshot: Bool {
        didSet {
            defaults.set(rewordScreenshot, forKey: "rewordScreenshot")
            refreshScreenProblem()
        }
    }
    @Published var cleanupScreenshot: Bool {
        didSet {
            defaults.set(cleanupScreenshot, forKey: "cleanupScreenshot")
            refreshScreenProblem()
        }
    }
    @Published var rewordWholeField: Bool {
        didSet { defaults.set(rewordWholeField, forKey: "rewordWholeField") }
    }
    @Published var autoReword: Bool {
        didSet { defaults.set(autoReword, forKey: "autoReword") }
    }
    @Published var rewordClaudeFallback: Bool {
        didSet { defaults.set(rewordClaudeFallback, forKey: "rewordClaudeFallback") }
    }
    @Published private(set) var rewordAPIKey: String
    @Published private(set) var adminAPIKey: String

    private let defaults = UserDefaults.standard
    private lazy var recorder = AudioRecorder(onLevel: { [weak self] level in
        Task { @MainActor [weak self] in self?.receiveLevel(level) }
    })
    private let client = TranscriptionClient()
    private let rewordClient = RewordClient()
    private let rewordModels = RewordModelCache()
    private var servicesProvider: RewordServiceProvider?
    private var rewordInFlight = false
    private var dictationActivity = 0
    private var showsRewording = false {
        didSet { updateOverlay() }
    }
    /// Unsent: transcription failed.
    private let cache = RecordingCache(directory: RecordingCache.defaultDirectory())
    /// Transcribed or cancelled, so a bad transcript or an accidental cancel can be redone.
    private let recent = RecordingCache(directory: RecordingCache.recentDirectory())
    /// Shorter cancelled takes are mostly accidental taps, e.g. of an Option shortcut.
    private static let minimumKeptSeconds: TimeInterval = 2
    private var overlay: DictationOverlay?
    private var hotkey: HotkeyMonitor?
    private var permissionProblem: Problem?
    private var transientProblem: Problem?
    private var clearProblemTask: Task<Void, Never>?
    private var notice: String?
    /// One notice per outage of the heard-dictation path; cleared when it works again.
    private var heardNoticeShown = false
    private var clearNoticeTask: Task<Void, Never>?
    private var uploadingIDs: Set<String> = []
    private var retryingIDs: Set<String> = [] {
        didSet { updateOverlay() }
    }
    private var level = 0.0
    private var lastLevelAt: TimeInterval?
    private var started = false
    private var refreshTask: Task<Void, Never>?
    private typealias ScreenTask = Task<Result<Data, ScreenCapture.Failure>, Never>
    /// One entry per finished recording, in job order; nil when no screenshot is taken.
    private var jobScreens: [ScreenTask?] = []
    private var lastRecordingEnded: TimeInterval?
    private var coolDownTask: Task<Void, Never>?

    private lazy var dictation: Dictation = {
        let dictation = Dictation(services: DictationServices(
            startRecording: { [recorder] in try recorder.start() },
            stopRecording: { [weak self, recorder] in
                defer { self?.recordingEnded() }
                let wav = try recorder.stop(keepWarm: self?.keepsMicWarm ?? false)
                self?.queueDictationScreen(for: wav)
                return wav
            },
            cancelRecording: { [weak self, recorder] in
                defer { self?.recordingEnded() }
                // Same warm-or-tear-down handling as `cancel`, but the audio survives.
                guard let wav = try? recorder.stop(keepWarm: self?.keepsMicWarm ?? false) else { return }
                self?.keepCancelled(wav)
            },
            transcribe: { [weak self] wav in
                guard let self else { throw CancellationError() }
                let screen = self.jobScreens.isEmpty ? nil : self.jobScreens.removeFirst()
                return try await self.transcribeKeepingAudio(wav, screen: screen)
            },
            paste: { text in try KeyboardPaste.paste(text) },
            cue: { [weak self] cue in self?.play(cue) },
            clock: { ProcessInfo.processInfo.systemUptime }
        ), postRollSeconds: 0.3)
        dictation.enabled = enabled
        dictation.usesDedicatedHandsFreeKey = handsFreeKey != nil
        dictation.onState = { [weak self] in self?.state = $0 }
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
        let resolvedHandsFreeKey = storedHandsFreeKey == storedKey ? nil : storedHandsFreeKey
        handsFreeKey = resolvedHandsFreeKey
        let storedRewordKey = stored.string(forKey: "rewordKey").map { DictationKey(rawValue: $0) } ?? .rightCommand
        rewordKey = storedRewordKey == storedKey || storedRewordKey == resolvedHandsFreeKey ? nil : storedRewordKey
        language = stored.string(forKey: "language") ?? ""
        knownWords = stored.stringArray(forKey: "knownWords") ?? []
        replacements = stored.stringArray(forKey: "replacements") ?? []
        rewordInstructions = stored.string(forKey: "rewordInstructions") ?? ""
        sounds = stored.object(forKey: "sounds") as? Bool ?? true
        keepMicReady = stored.object(forKey: "keepMicReady") as? Bool ?? false
        apiKey = Keychain.apiKey() ?? ""
        rewordServerURL = stored.string(forKey: "rewordServerURL") ?? "http://localhost:8400/v1"
        rewordWholeField = stored.object(forKey: "rewordWholeField") as? Bool ?? true
        rewordScreenshot = stored.object(forKey: "rewordScreenshot") as? Bool ?? true
        cleanupScreenshot = stored.object(forKey: "cleanupScreenshot") as? Bool ?? true
        autoReword = stored.object(forKey: "autoReword") as? Bool ?? false
        rewordClaudeFallback = stored.object(forKey: "rewordClaudeFallback") as? Bool ?? true
        rewordAPIKey = Keychain.value(for: "rewordAPIKey") ?? ""
        adminAPIKey = Keychain.value(for: "adminAPIKey") ?? ""
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled || status == .requiresApproval
        Task { [weak self] in await self?.start() }
    }

    func start() async {
        guard !started else { return }
        started = true
        _ = dictation
        recorder.onCooledDown = { [weak self] in MainActor.assumeIsolated { self?.coolDownMic() } }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.scheduleCoolDown() } }
        overlay = DictationOverlay()
        updateOverlay()
        servicesProvider = RewordServiceProvider { [weak self] text in
            try await self?.rewordForService(text)
        }
        NSApp.servicesProvider = servicesProvider
        NSUpdateDynamicServices()
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
            let text = try await send(wav, screen: nil)
            keepAsRecent(recording)
            refreshRecordings()
            if text.isEmpty {
                show(notice: "No speech in recording")
            } else {
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

    private func transcribeKeepingAudio(_ wav: Data, screen: ScreenTask?) async throws -> String {
        let saved = try? cache.save(wav)
        if let saved { uploadingIDs.insert(saved.id) }
        defer {
            if let saved { uploadingIDs.remove(saved.id) }
            refreshRecordings()
        }
        do {
            let text = try await send(wav, screen: screen)
            if let saved { keepAsRecent(saved) }
            return text
        } catch {
            guard let saved else { throw error }
            if !FileManager.default.fileExists(atPath: saved.url.path) {
                guard (try? cache.save(wav)) != nil else { throw error }
            }
            throw RecordingSaved(underlying: error)
        }
    }

    /// A model can return a plausible but wrong transcript, so the audio stays for "Transcribe Again".
    private func keepAsRecent(_ recording: CachedRecording) {
        guard (try? cache.move(recording, to: recent)) == nil else { return }
        // Left in place it would count as unsent and prompt for a retry it doesn't need.
        cache.remove(recording)
    }

    /// Another key or Esc cancels mid-sentence; the speech may still be wanted.
    private func keepCancelled(_ wav: Data) {
        guard WAV.duration(of: wav) >= Self.minimumKeptSeconds, (try? recent.save(wav)) != nil else { return }
        refreshRecordings()
        // The recording is listed either way; an error still on screen matters more.
        guard transientProblem == nil else { return }
        show(notice: "Recording cancelled · kept in menu")
    }

    /// Whisper, not the heard model: that model may be what produced the bad transcript.
    /// The recording stays in recent, so it can be tried again.
    func transcribeAgain(_ recording: CachedRecording) async {
        guard !retryingIDs.contains(recording.id) else { return }
        retryingIDs.insert(recording.id)
        defer { retryingIDs.remove(recording.id) }
        let wav: Data
        do {
            wav = try recent.load(recording)
        } catch {
            refreshRecordings()
            return report(AppIssue.recordingMissing)
        }
        do {
            let text = try await sendToSpeechServer(wav, screen: nil)
            if text.isEmpty {
                show(notice: "No speech in recording")
            } else if copy(text) {
                show(notice: "Transcript copied")
            }
        } catch {
            report(error)
        }
    }

    /// Taken when a dictation finishes, while its target field still has focus, for that job's model requests.
    private func queueDictationScreen(for wav: Data) {
        let used = autoReword || WAV.duration(of: wav) <= HeardDictation.maxSeconds
        jobScreens.append(cleanupScreenshot && used ? Task { await ScreenCapture.focusedArea() } : nil)
    }

    private func send(_ wav: Data, screen: ScreenTask?) async throws -> String {
        let rules = Replacements.rules(from: replacements)
        if WAV.duration(of: wav) <= HeardDictation.maxSeconds {
            let shot = await screen?.value
            noteScreenFailure(shot)
            let request = HeardRequest(
                wav: wav, language: language, vocabulary: vocabulary,
                style: autoReword ? .cleanedUp : .verbatim, screenshot: try? shot?.get()
            )
            let start = Date()
            do {
                let heard = try await rewordClient.transcribe(
                    request, serverURL: rewordServerURL, apiKey: rewordAPIKey
                )
                heardLog.info("heard in \(Date().timeIntervalSince(start), format: .fixed(precision: 1)) s")
                // An empty answer may be a model that missed the audio, not silence; Whisper decides.
                if !heard.isEmpty {
                    heardNoticeShown = false
                    return Replacements.apply(rules, to: heard)
                }
            } catch RewordError.response(503) {
                startHeardModel()
            } catch let error as RewordError where error == .unauthorized || error == .invalidURL {
                showHeardNotice("\(error.localizedDescription) — using Whisper")
            } catch {
                // Whisper below still delivers the dictation.
                heardLog.error("heard failed after \(Date().timeIntervalSince(start), format: .fixed(precision: 1)) s: \(error.localizedDescription, privacy: .public)")
            }
            // URLSession reports cancellation as a transport error, so check before falling back.
            try Task.checkCancellation()
        }
        return try await sendToSpeechServer(wav, screen: screen)
    }

    /// Whisper, then cleanup when "Clean up every dictation" is on.
    private func sendToSpeechServer(_ wav: Data, screen: ScreenTask?) async throws -> String {
        let rules = Replacements.rules(from: replacements)
        let text = try await client.transcribe(
            wav: wav, serverURL: serverURL, apiKey: apiKey,
            language: language, knownWords: knownWords
        )
        let replaced = Replacements.apply(rules, to: text)
        guard autoReword, !replaced.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              replaced.count <= Rewording.maxCharacters else { return replaced }
        let shot = await screen?.value
        do {
            let cleaned = try await Rewording.reword(
                replaced, using: rewordServices(style: .light, chatTimeout: 15, claude: false), style: .light,
                screenshot: try? shot?.get()
            )
            noteScreenFailure(shot)
            return Replacements.apply(rules, to: cleaned)
        } catch {
            // Cleanup is best effort: keep the raw transcript.
            try Task.checkCancellation()
            return replaced
        }
    }

    private var warmPolicy: WarmMicPolicy {
        WarmMicPolicy(enabled: keepMicReady && enabled && permissionProblem == nil)
    }

    /// "Stop keeping microphone ready" during a recording: don't keep the mic warm after it.
    private var coolDownRequested = false

    private var keepsMicWarm: Bool {
        let now = Date().timeIntervalSince1970
        return !coolDownRequested && warmPolicy.shouldBeWarm(lastRecordingEnded: now, now: now)
    }

    private func recordingEnded() {
        lastRecordingEnded = Date().timeIntervalSince1970
        coolDownRequested = false
        micWarm = recorder.isWarm
        scheduleCoolDown()
    }

    /// Wall-clock time, so system sleep counts toward the hour.
    private func scheduleCoolDown() {
        coolDownTask?.cancel()
        guard micWarm else { return }
        coolDownTask = Task { [weak self] in
            while !Task.isCancelled {
                // A running recording reschedules when it ends.
                guard let self, !self.recorder.isRecording else { return }
                let remaining = self.warmSecondsLeft()
                guard remaining > 0 else { return self.coolDownMic() }
                try? await Task.sleep(for: .seconds(remaining))
            }
        }
    }

    private func warmSecondsLeft() -> TimeInterval {
        let now = Date().timeIntervalSince1970
        guard let lastRecordingEnded, recorder.isWarm,
              warmPolicy.shouldBeWarm(lastRecordingEnded: lastRecordingEnded, now: now) else { return 0 }
        return warmPolicy.coolDownAt(lastRecordingEnded: lastRecordingEnded) - now
    }

    func coolDownMic() {
        coolDownTask?.cancel()
        coolDownTask = nil
        if recorder.isRecording { coolDownRequested = true }
        recorder.coolDown()
        micWarm = false
    }

    private func refreshRecordings() {
        unsentRecordings = cache.recordings(protecting: uploadingIDs.union(retryingIDs))
            .filter { !uploadingIDs.contains($0.id) }
        recentRecordings = recent.recordings(protecting: retryingIDs)
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
                hotkey = HotkeyMonitor(key: key, handsFreeKey: handsFreeKey, rewordKey: rewordKey) { [weak self] input in
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
                    case .rewordTapped:
                        Task { await self.rewordSelection() }
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
        refreshScreenProblem()
        publishProblem()
        dictation.enabled = enabled && permissionProblem == nil
        if !dictation.enabled { coolDownMic() }
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

    func updateRewordAPIKey(_ value: String) {
        do {
            try Keychain.set(value, for: "rewordAPIKey")
            rewordAPIKey = value
            rewordModels.removeAll()
        } catch {
            report(AppIssue.apiKey)
        }
    }

    func updateAdminAPIKey(_ value: String) {
        do {
            try Keychain.set(value, for: "adminAPIKey")
            adminAPIKey = value
        } catch {
            report(AppIssue.apiKey)
        }
    }

    /// The gateway answers 503 while the model is off; start it so later dictations use it again.
    /// Errors are notices, not problems: this dictation still succeeds through Whisper.
    private func startHeardModel() {
        let serverURL = rewordServerURL, adminKey = adminAPIKey
        guard !adminKey.isEmpty else { return }
        Task { [weak self] in
            do {
                try await ModelControl().start(HeardDictation.model, serverURL: serverURL, adminKey: adminKey)
                self?.showHeardNotice("Starting \(HeardDictation.model); using Whisper meanwhile")
            } catch ModelStartError.busy {
                // An earlier dictation already started it.
            } catch {
                self?.showHeardNotice(error.localizedDescription)
            }
        }
    }

    /// Every dictation in an outage hits the same error; say it once, and never over a live problem,
    /// which a notice would clear.
    private func showHeardNotice(_ text: String) {
        guard !heardNoticeShown, transientProblem == nil else { return }
        heardNoticeShown = true
        show(notice: text)
    }

    /// Reword key tapped: copy the selection (or the whole field), reword it, paste the result over it.
    func rewordSelection() async {
        guard !rewordInFlight, state == .idle, retryingIDs.isEmpty else { return }
        rewordInFlight = true
        defer {
            rewordInFlight = false
            showsRewording = false
        }
        guard await waitForModifiersReleased() else { return }
        let app = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let pasteboard = NSPasteboard.general
        let clipboard = pasteboard.string(forType: .string)
        let clipboardChange = pasteboard.changeCount
        var selectedAll = false
        let capture = rewordScreenshot ? Task { await ScreenCapture.focusedArea() } : nil
        do {
            let text = try await copySelection(selectedAll: &selectedAll)
            let shot = await capture?.value
            let activity = dictationActivity
            let result = try await reword(text, screenshot: try? shot?.get())
            noteScreenFailure(shot)
            // A dictation or another app now owns the focus; don't paste into it.
            if dictationActivity != activity || state != .idle
                || NSWorkspace.shared.frontmostApplication?.processIdentifier != app {
                if copy(result) { show(notice: "Reworded text copied") }
            } else {
                try KeyboardPaste.paste(result)
            }
        } catch {
            if pasteboard.changeCount != clipboardChange, let clipboard {
                pasteboard.clearContents()
                pasteboard.setString(clipboard, forType: .string)
            }
            if selectedAll, NSWorkspace.shared.frontmostApplication?.processIdentifier == app {
                try? KeyboardPaste.collapseSelection()
            }
            failReword(error)
        }
    }

    /// Services menu: returns nil when ignored because a reword or dictation is in progress.
    private func rewordForService(_ text: String) async throws -> String? {
        guard !rewordInFlight, state == .idle, retryingIDs.isEmpty else { return nil }
        rewordInFlight = true
        defer {
            rewordInFlight = false
            showsRewording = false
        }
        do {
            return try await reword(text)
        } catch {
            failReword(error)
            throw error
        }
    }

    private func reword(_ text: String, screenshot: Data? = nil) async throws -> String {
        showsRewording = true
        return try await Rewording.reword(
            Replacements.apply(Replacements.rules(from: replacements), to: text),
            using: rewordServices(style: .written), style: .written, screenshot: screenshot
        )
    }

    private func rewordServices(
        style: RewordStyle, chatTimeout: TimeInterval = 60, claude useClaude: Bool = true
    ) -> RewordServices {
        let client = rewordClient, serverURL = rewordServerURL, apiKey = rewordAPIKey
        let vocabulary = vocabulary
        let claude = useClaude && rewordClaudeFallback ? ClaudeCLI.locate() : nil
        let cache = rewordModels
        return RewordServices(
            listModels: {
                if let cached = cache[serverURL, style] { return [cached] }
                let ids = try await client.models(serverURL: serverURL, apiKey: apiKey)
                cache[serverURL, style] = Rewording.chooseModel(from: ids, style: style)
                return ids
            },
            rewordLocal: { text, model, screenshot in
                do {
                    return try await client.reword(
                        text, model: model, serverURL: serverURL, apiKey: apiKey,
                        vocabulary: vocabulary, style: style, timeout: chatTimeout, screenshot: screenshot
                    )
                } catch let error as RewordError where error != .unreachable {
                    cache[serverURL, style] = nil
                    throw error
                }
            },
            rewordWithClaude: claude.map { executable in
                { text in try await ClaudeCLI.reword(text, executable: executable, vocabulary: vocabulary, style: style) }
            }
        )
    }

    private var vocabulary: Vocabulary {
        Vocabulary(
            knownWords: knownWords, replacements: Replacements.rules(from: replacements),
            instructions: rewordInstructions)
    }

    /// So the synthetic ⌘C isn't merged with held modifiers.
    private func waitForModifiersReleased() async -> Bool {
        let held: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand, .maskShift]
        for _ in 0..<15 {
            if CGEventSource.flagsState(.combinedSessionState).isDisjoint(with: held) { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    private func copySelection(selectedAll: inout Bool) async throws -> String {
        if let text = try await copyCurrentSelection() { return text }
        // Only select all in a text field; elsewhere ⌘A would select a whole page or file list.
        guard rewordWholeField, FocusedElement.isEditableText() != false else { throw RewordError.nothingSelected }
        try KeyboardPaste.selectAll()
        selectedAll = true
        try? await Task.sleep(for: .milliseconds(50))
        guard let text = try await copyCurrentSelection() else { throw RewordError.nothingSelected }
        return text
    }

    private func copyCurrentSelection() async throws -> String? {
        let pasteboard = NSPasteboard.general
        let before = pasteboard.changeCount
        try KeyboardPaste.copySelection()
        for _ in 0..<25 where pasteboard.changeCount == before {
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard pasteboard.changeCount != before, let text = pasteboard.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return text
    }

    /// Missing permission shows as a menu line instead of a notice on every reword.
    private func noteScreenFailure(_ shot: Result<Data, ScreenCapture.Failure>?) {
        switch shot {
        case .failure(.permission)?: refreshScreenProblem()
        case .failure(.capture)?: show(notice: "Sent without screen — screen capture failed")
        default: break
        }
    }

    private func refreshScreenProblem() {
        let needed = (rewordScreenshot || cleanupScreenshot) && !CGPreflightScreenCaptureAccess()
        screenProblem = needed
            ? Problem(text: "Screen Recording needed for screenshots", pane: .screenRecording) : nil
    }

    private func failReword(_ error: Error) {
        report(error)
        play(.error)
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
        case let known as RewordError: known.localizedDescription
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
            level: level, keyName: (handsFreeKey ?? key).title, message: message,
            rewording: showsRewording
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
