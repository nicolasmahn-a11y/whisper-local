import AppKit
import SwiftUI

/// Brings the Settings window to the front for an accessory app: the app becomes
/// a regular app (Dock, Cmd-Tab) while the window is open and reverts on close.
@MainActor
final class SettingsWindow {
    static let shared = SettingsWindow()

    private weak var window: NSWindow?
    private var closeObserver: NSObjectProtocol?

    func attach(_ window: NSWindow) {
        if self.window !== window {
            self.window = window
            removeObserver()
            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.didClose() }
            }
        }
        present()
    }

    func present() {
        NSApp.setActivationPolicy(.regular)
        if #unavailable(macOS 15) {
            NSApp.activate(ignoringOtherApps: true)
        } else {
            NSApp.activate()
        }
        guard let window else { return }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    private func didClose() {
        window = nil
        removeObserver()
        NSApp.setActivationPolicy(.accessory)
        NSApp.hide(nil)
        DispatchQueue.main.async { NSApp.unhideWithoutActivation() }
    }

    private func removeObserver() {
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
    }
}

/// Hands the hosting window to `SettingsWindow` once it exists.
struct SettingsWindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { WindowObservingView() }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class WindowObservingView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            SettingsWindow.shared.attach(window)
        }
    }
}
