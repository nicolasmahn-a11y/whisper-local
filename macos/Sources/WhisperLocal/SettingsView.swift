import AppKit
import SwiftUI

/// Toolbar-tabbed settings, each tab a short grouped form so the window stays
/// screen-sized instead of one long scroll.
struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        TabView {
            GeneralPane(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
            DictationPane(model: model)
                .tabItem { Label("Dictation", systemImage: "mic") }
            VocabularyPane(model: model)
                .tabItem { Label("Vocabulary", systemImage: "character.book.closed") }
            RewordingPane(model: model)
                .tabItem { Label("Rewording", systemImage: "wand.and.stars") }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: 500)
        .background(SettingsWindowAccessor())
        .task {
            await model.refreshPermissions()
            await model.checkReachability()
        }
    }
}

private struct GeneralPane: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section {
                Toggle("Enabled", isOn: $model.enabled)
            } footer: {
                Text("Turns the dictation and reword keys off without quitting.")
            }
            Section {
                Toggle("Sounds", isOn: $model.sounds)
                Toggle("Launch at login", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct DictationPane: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section("Speech server") {
                TextField("Server URL", text: $model.serverURL, prompt: Text("http://localhost:8178/v1"))
                    .onSubmit { Task { await model.checkReachability() } }
                SecureField("API key", text: Binding(
                    get: { model.apiKey },
                    set: { model.updateAPIKey($0) }
                ), prompt: Text("Optional"))
                connectionRow
            }
            Section("Keys") {
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
            }
            Section {
                TextField("Language", text: $model.language, prompt: Text("Auto-detect"))
            }
            Section {
                Toggle("Keep microphone ready for an hour after dictating", isOn: $model.keepMicReady)
            } footer: {
                Text("Catches the first word when you start speaking just before the key. The microphone stays on (orange dot in the menu bar) until an hour after the last dictation.")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
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

private struct RewordingPane: View {
    @ObservedObject var model: AppModel
    @State private var claudeAvailable = false

    var body: some View {
        Form {
            Section {
                Picker("Reword key", selection: $model.rewordKey) {
                    Text("None").tag(Optional<DictationKey>.none)
                    ForEach(DictationKey.allCases.filter { $0 != model.key && $0 != model.handsFreeKey }) { key in
                        Text(key.title).tag(Optional<DictationKey>.some(key))
                    }
                }
                Toggle("Reword whole field when nothing is selected", isOn: $model.rewordWholeField)
            } header: {
                Text("Reword")
            } footer: {
                Text(rewordFooter)
            }
            Section {
                Toggle("Clean up every dictation", isOn: $model.autoReword)
            } header: {
                Text("Cleanup")
            } footer: {
                Text("Light cleanup by the model server. Adds a few seconds; the raw transcript is pasted if cleanup fails.")
            }
            Section {
                TextField("Server URL", text: $model.rewordServerURL, prompt: Text("http://localhost:8400/v1"))
                SecureField("API key", text: Binding(
                    get: { model.rewordAPIKey },
                    set: { model.updateRewordAPIKey($0) }
                ), prompt: Text("Optional"))
                Toggle("Fall back to Claude Haiku", isOn: $model.rewordClaudeFallback)
            } header: {
                Text("Model server")
            } footer: {
                Text(claudeAvailable
                    ? "The fallback sends the text to Anthropic through the claude CLI."
                    : "Fallback unavailable: claude CLI not found.")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { claudeAvailable = ClaudeCLI.locate() != nil }
    }

    private var rewordFooter: String {
        let service = "Services › Reword with Whisper Local in the right-click menu"
        guard let key = model.rewordKey else {
            return "To rewrite selected text as if you had typed it, use \(service)."
        }
        return "Tap \(key.title) to rewrite the selected text as if you had typed it, or use \(service)."
    }
}

private struct VocabularyPane: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section {
                VocabularyList(lines: $model.knownWords) { line, remove in
                    KnownWordRow(line: line, remove: remove)
                } add: { add in
                    AddWordRow(add: add)
                }
            } header: {
                header("Known words", count: model.knownWords.count)
            } footer: {
                Text("Sent to the speech server as context so names and jargon are recognised.")
            }
            Section {
                VocabularyList(lines: $model.replacements) { line, remove in
                    ReplacementRow(line: line, remove: remove)
                } add: { add in
                    AddReplacementRow(add: add)
                }
            } header: {
                header("Replacements", count: model.replacements.count)
            } footer: {
                Text("Applied to every transcript, so words you pronounce differently come out right. Variants are comma-separated.")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func header(_ title: String, count: Int) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text("\(count)").foregroundStyle(.secondary).monospacedDigit()
        }
    }
}

/// Entries as rows that scroll past a bounded height, plus an add row; the stored
/// array stays one string per entry.
private struct VocabularyList<Row: View, Add: View>: View {
    @Binding var lines: [String]
    @ViewBuilder let row: (Binding<String>, @escaping () -> Void) -> Row
    @ViewBuilder let add: (@escaping (String) -> Void) -> Add

    private static var rowHeight: CGFloat { 28 }
    private static var maxHeight: CGFloat { 252 }

    var body: some View {
        if !lines.isEmpty {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(lines.indices, id: \.self) { index in
                        row(line(at: index)) { lines.remove(at: index) }
                            .id(lines[index])
                            .frame(height: Self.rowHeight)
                        if index < lines.count - 1 { Divider() }
                    }
                }
            }
            .scrollDisabled(false)
            .frame(height: min(CGFloat(lines.count) * Self.rowHeight, Self.maxHeight))
        }
        add { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !lines.contains(trimmed) else { return }
            lines.append(trimmed)
        }
    }

    /// Bounds-checked: a row can still render during the update that removes it.
    private func line(at index: Int) -> Binding<String> {
        Binding(
            get: { index < lines.count ? lines[index] : "" },
            set: { if index < lines.count { lines[index] = $0 } }
        )
    }
}

/// Minus button that appears on hover, the grouped-form stand-in for swipe-to-delete.
private struct RemovableRow<Content: View>: View {
    let remove: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 8) {
            content()
            Button(action: remove) {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .opacity(hovered ? 1 : 0)
            .accessibilityLabel("Remove")
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
    }
}

/// Edits a local copy and stores on Return, so the row keeps focus while typing.
private struct KnownWordRow: View {
    @Binding var line: String
    let remove: () -> Void
    @State private var text: String

    init(line: Binding<String>, remove: @escaping () -> Void) {
        _line = line
        self.remove = remove
        _text = State(initialValue: line.wrappedValue)
    }

    var body: some View {
        RemovableRow(remove: remove) {
            TextField("Word", text: $text)
                .labelsHidden()
                .textFieldStyle(.plain)
                .onSubmit {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty { remove() } else { line = trimmed }
                }
        }
    }
}

private struct AddWordRow: View {
    let add: (String) -> Void
    @State private var text = ""

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.circle").foregroundStyle(.secondary)
            TextField("Add word", text: $text, prompt: Text("Add word or phrase…"))
                .labelsHidden()
                .textFieldStyle(.plain)
                .onSubmit {
                    add(text)
                    text = ""
                }
        }
    }
}

/// Edits the two halves of a rule; local copies keep the row stable while one half
/// is momentarily empty, and the stored line is rewritten only from a complete rule.
private struct ReplacementRow: View {
    @Binding var line: String
    let remove: () -> Void
    @State private var heard: String
    @State private var target: String

    init(line: Binding<String>, remove: @escaping () -> Void) {
        _line = line
        self.remove = remove
        let rule = Replacements.parse(line: line.wrappedValue)
        _heard = State(initialValue: rule?.heard.joined(separator: ", ") ?? line.wrappedValue)
        _target = State(initialValue: rule?.target ?? "")
    }

    var body: some View {
        RemovableRow(remove: remove) {
            ReplacementFields(heard: $heard, target: $target)
                .onSubmit(store)
        }
    }

    private func store() {
        guard let rule = Replacements.parse(line: Replacements.line(heard: heard, target: target)) else { return }
        line = Replacements.line(heard: rule.heard.joined(separator: ", "), target: rule.target)
    }
}

private struct AddReplacementRow: View {
    let add: (String) -> Void
    @State private var heard = ""
    @State private var target = ""

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.circle").foregroundStyle(.secondary)
            ReplacementFields(heard: $heard, target: $target)
                .onSubmit {
                    let line = Replacements.line(heard: heard, target: target)
                    guard Replacements.parse(line: line) != nil else { return }
                    add(line)
                    heard = ""
                    target = ""
                }
        }
    }
}

/// "heard variants → result" as two fields around a subdued arrow.
private struct ReplacementFields: View {
    @Binding var heard: String
    @Binding var target: String

    var body: some View {
        HStack(spacing: 8) {
            TextField("Heard as", text: $heard, prompt: Text("Heard as, or as"))
            Image(systemName: "arrow.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
            TextField("Result", text: $target, prompt: Text("Result"))
        }
        .labelsHidden()
        .textFieldStyle(.plain)
    }
}
