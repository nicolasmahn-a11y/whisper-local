import AppKit
import SwiftUI

@main
struct WhisperLocalApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra(content: {
            MenuContent(model: model)
        }, label: {
            let style = DictationStyle.current(
                state: model.state, enabled: model.enabled, hasProblem: model.problem != nil
            )
            HStack(spacing: 3) {
                Image(systemName: style.symbol)
                    .foregroundStyle(style.color)
                if style.showsRecordingDot {
                    Circle()
                        .fill(style.color)
                        .frame(width: 5, height: 5)
                } else if model.state == .idle && !model.unsentRecordings.isEmpty {
                    Circle()
                        .fill(Theme.amber)
                        .frame(width: 5, height: 5)
                }
            }
            .accessibilityLabel("Whisper Local")
        })
        Settings { SettingsView(model: model) }
    }
}

private struct MenuContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Group {
            Toggle("Enabled", isOn: $model.enabled)
            if model.recentTranscripts.isEmpty {
                Text("No transcript yet")
            } else {
                ForEach(model.recentTranscripts.indices, id: \.self) { index in
                    let transcript = model.recentTranscripts[index]
                    Button(label(for: transcript)) {
                        model.copyTranscript(transcript)
                    }
                }
            }
            if !model.unsentRecordings.isEmpty {
                Section("Unsent recordings") {
                    ForEach(model.unsentRecordings) { recording in
                        Menu(RecordingFormat.label(for: recording)) {
                            Button("Transcribe and Copy") { Task { await model.retry(recording) } }
                            Button("Discard") { model.discard(recording) }
                        }
                    }
                }
            }
            if let problem = model.problem {
                if problem.pane == nil {
                    Text(problem.text)
                } else {
                    Button(problem.text) { model.openProblemSettings() }
                }
            }
            if model.micWarm {
                Button("Stop keeping microphone ready") { model.coolDownMic() }
            }
            Button("Settings…") {
                openSettings()
                SettingsWindow.shared.present()
            }
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .task { await model.refreshPermissions() }
    }

    private func label(for transcript: String) -> String {
        let text = transcript.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return text.count > 80 ? String(text.prefix(80)) + "…" : text
    }
}

/// One entry per line, stored as the non-blank lines.
private struct LinesEditor: View {
    let label: String
    @Binding var lines: [String]
    @State private var text = ""

    var body: some View {
        TextEditor(text: $text)
            .font(.body)
            .scrollContentBackground(.hidden)
            .padding(6)
            .frame(height: 90)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            .accessibilityLabel(label)
            .onAppear { text = KnownWords.format(lines) }
            .onChange(of: text) { _, value in lines = KnownWords.parse(value) }
    }
}

private struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section("Server") {
                TextField("Server URL", text: $model.serverURL, prompt: Text("http://localhost:8178/v1"))
                    .onSubmit { Task { await model.checkReachability() } }
                SecureField("API key", text: Binding(
                    get: { model.apiKey },
                    set: { model.updateAPIKey($0) }
                ), prompt: Text("Optional"))
                connectionRow
            }
            Section("Dictation") {
                Picker("Dictation key", selection: $model.key) {
                    ForEach(DictationKey.allCases) { key in
                        Text(key.title).tag(key)
                    }
                }
                Picker("Hands-free", selection: $model.handsFreeKey) {
                    Text("Double-tap \(model.key.title)").tag(Optional<DictationKey>.none)
                    ForEach(DictationKey.allCases.filter { $0 != model.key }) { key in
                        Text(key.title).tag(Optional<DictationKey>.some(key))
                    }
                }
                TextField("Language", text: $model.language, prompt: Text("Auto-detect"))
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Keep microphone ready for an hour after dictating", isOn: $model.keepMicReady)
                    Text("Catches the first word when you start speaking just before the key. The microphone stays on (the system's orange microphone dot) until an hour after the last dictation.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                LinesEditor(label: "Known words", lines: $model.knownWords)
            } header: {
                Text("Known words")
            } footer: {
                Text("One word or phrase per line. Sent to the server as context to improve recognition of names and jargon.")
            }
            Section {
                LinesEditor(label: "Replacements", lines: $model.replacements)
            } header: {
                Text("Replacements")
            } footer: {
                Text("One rule per line, like `Persuus, Pursus -> Perseus`. Applied to every transcript, so words you pronounce differently come out right.")
            }
            Section {
                Picker("Reword key", selection: $model.rewordKey) {
                    Text("None").tag(Optional<DictationKey>.none)
                    ForEach(DictationKey.allCases.filter { $0 != model.key && $0 != model.handsFreeKey }) { key in
                        Text(key.title).tag(Optional<DictationKey>.some(key))
                    }
                }
                Toggle("Reword whole field when nothing is selected", isOn: $model.rewordWholeField)
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Clean up every dictation", isOn: $model.autoReword)
                    Text("Uses the rewording server's light cleanup. Adds a few seconds; the raw transcript is pasted if cleanup fails.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                TextField("Server URL", text: $model.rewordServerURL, prompt: Text("http://localhost:8400/v1"))
                SecureField("API key", text: Binding(
                    get: { model.rewordAPIKey },
                    set: { model.updateRewordAPIKey($0) }
                ), prompt: Text("Optional"))
                Toggle("Fall back to Claude Haiku", isOn: $model.rewordClaudeFallback)
            } header: {
                Text("Rewording")
            } footer: {
                Text((model.rewordKey.map { "Tap \($0.title) to rewrite the selected text as if you had typed it, or " }
                    ?? "To rewrite selected text as if you had typed it, ")
                    + "use Services › Reword with Whisper Local in the right-click menu. "
                    + (ClaudeCLI.locate() == nil
                        ? "claude CLI not found, so there is no Claude fallback."
                        : "The Claude fallback sends the text to Anthropic via the claude CLI."))
            }
            Section("General") {
                Toggle("Sounds", isOn: $model.sounds)
                Toggle("Launch at login", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 480)
        .background(SettingsWindowAccessor())
        .onAppear { SettingsWindow.shared.present() }
        .task {
            await model.refreshPermissions()
            await model.checkReachability()
        }
    }

    private var connectionRow: some View {
        HStack(spacing: 8) {
            Group {
                if let reachable = model.serverReachable {
                    Circle()
                        .fill(reachable ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                } else {
                    ProgressView().controlSize(.mini)
                }
            }
            .frame(width: 16, height: 16)
            Text(connectionText)
            Spacer()
            Button("Check connection") { Task { await model.checkReachability() } }
        }
    }

    private var connectionText: String {
        switch model.serverReachable {
        case true: "Server reachable"
        case false: "Server unreachable"
        case nil: "Checking server…"
        }
    }
}
