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
            if let screenProblem = model.screenProblem, let url = screenProblem.pane?.url {
                Button(screenProblem.text) { NSWorkspace.shared.open(url) }
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
}
