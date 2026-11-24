import AppKit
import Foundation
import SwiftUI

enum OverlayMessage: Equatable {
    case error(String)
    case notice(String)
}

@MainActor
private final class OverlayDisplay: ObservableObject {
    @Published var state: DictationState = .idle
    @Published var level = 0.0
    @Published var keyName = "Right Option"
    @Published var message: OverlayMessage?
    @Published var listeningSince = Date()
    @Published var transcribingSince = Date()
    @Published var rewordingSince = Date()
    @Published var rewording = false
}

@MainActor
final class DictationOverlay {
    private let display = OverlayDisplay()
    private let panel: NSPanel
    private var visible = false
    private var visibilityChange = 0

    init() {
        let size = NSSize(width: 600, height: 72)
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = Theme.overlayWindowBackground
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.contentView = NSHostingView(rootView: OverlayView(display: display).frame(width: size.width, height: size.height))
    }

    func update(state: DictationState, level: Double, keyName: String, message: OverlayMessage?, rewording: Bool = false) {
        let stateChanged = display.state != state || display.rewording != rewording
        let listening = state == .listening || state == .handsFree
        if stateChanged {
            // Every recording starts from idle or transcribing, never from another listening state.
            if listening { display.listeningSince = Date() }
            if state == .transcribing && display.state != state { display.transcribingSince = Date() }
            if rewording && !display.rewording { display.rewordingSince = Date() }
            display.state = state
            display.rewording = rewording
        }
        display.level = listening ? display.level * 0.65 + level * 0.35 : 0
        if display.keyName != keyName { display.keyName = keyName }
        if display.message != message { display.message = message }

        let shouldShow = state != .idle || rewording || message != nil
        if shouldShow && visible && stateChanged { position() }
        guard shouldShow != visible else { return }
        visible = shouldShow
        visibilityChange += 1
        let change = visibilityChange
        if shouldShow {
            position()
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                self.panel.animator().alphaValue = 1
            }
        } else {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.15
                self.panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, !self.visible, self.visibilityChange == change else { return }
                    self.panel.orderOut(nil)
                }
            })
        }
    }

    private func position() {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let frame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(
            x: frame.midX - panel.frame.width / 2,
            y: frame.minY + 18
        ))
    }
}

private struct OverlayView: View {
    @ObservedObject var display: OverlayDisplay

    var body: some View {
        HStack(spacing: 12) {
            if case .error(let text) = display.message {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(DictationStyle.current(
                        state: display.state, enabled: true, hasProblem: true
                    ).color)
                MessageText(text: text)
            } else if case .notice(let text) = display.message, display.state == .idle, !display.rewording {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.green)
                MessageText(text: text)
            } else {
                switch display.state {
                case .listening, .handsFree:
                    let color = DictationStyle.current(state: display.state, enabled: true, hasProblem: false).color
                    TimedIndicator(since: display.listeningSince, label: "Listening") { edge in
                        LevelBars(level: display.level, color: color, edge: edge)
                    }
                    if display.state == .handsFree {
                        Capsule()
                            .fill(Theme.neutralMuted.opacity(0.4))
                            .frame(width: 1, height: 16)
                        Text("Tap \(display.keyName) to finish · Esc to cancel")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.neutralMuted)
                            .lineLimit(1)
                    }
                case .transcribing:
                    TimedIndicator(since: display.transcribingSince, label: "Transcribing") { edge in
                        BusyDots(color: busyColor, edge: edge)
                    }
                case .idle:
                    if display.rewording {
                        TimedIndicator(since: display.rewordingSince, label: "Rewording") { edge in
                            BusyDots(color: busyColor, edge: edge)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: Capsule())
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var busyColor: Color {
        DictationStyle.current(state: .transcribing, enabled: true, hasProblem: false).color
    }
}

/// The elapsed time framed by a mirrored pair of animated sides, so the indicator alone says
/// what is happening and the timer says for how long — no status words needed.
private struct TimedIndicator<Side: View>: View {
    let since: Date
    let label: String
    @ViewBuilder let side: (HorizontalEdge) -> Side

    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { context in
            let elapsed = RecordingFormat.elapsed(context.date.timeIntervalSince(since))
            HStack(spacing: 10) {
                side(.leading)
                Text(elapsed)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.neutralStrong)
                    .lineLimit(1)
                side(.trailing)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(label), \(elapsed)")
        }
    }
}

private struct MessageText: View {
    let text: String

    var body: some View {
        Text(text)
            .foregroundStyle(Theme.neutralStrong)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
    }
}

private struct LevelBars: View {
    let level: Double
    let color: Color
    let edge: HorizontalEdge
    /// Tallest next to the timer, so the voice reads as radiating outward from it.
    private let weightsFromTimer = [1.0, 0.78, 0.56, 0.36]

    var body: some View {
        let weights = edge == .leading ? weightsFromTimer.reversed() : weightsFromTimer
        HStack(alignment: .center, spacing: 4) {
            ForEach(weights.indices, id: \.self) { index in
                Capsule()
                    .fill(color)
                    .frame(width: 4, height: 4 + 25 * level * weights[index])
            }
        }
        .frame(height: 30)
        .animation(.easeOut(duration: 0.12), value: level)
    }
}

private struct BusyDots: View {
    let color: Color
    let edge: HorizontalEdge

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.16)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate * 3
            HStack(spacing: 6) {
                ForEach(0..<3) { index in
                    // Both sides pulse outward from the timer in step.
                    let distance = edge == .leading ? 2 - index : index
                    Circle()
                        .fill(color)
                        .frame(width: 6, height: 6)
                        .opacity(0.3 + 0.7 * (1 + sin(phase - Double(distance) * 0.8)) / 2)
                }
            }
        }
        .frame(height: 30)
    }
}
