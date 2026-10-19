import AppKit
import SwiftUI

/// Brings the Settings window to the front for an accessory app: the app becomes
/// a regular app (Dock, Cmd-Tab) while the window is open and reverts on close.
@MainActor
final class SettingsWindow {
    static let shared = SettingsWindow()

    /// Kept across close: SwiftUI keeps the Settings window alive for reopening, so
    /// the hosting view does not move windows again. A freed window re-attaches.
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

    /// Deferred one turn of the run loop: a menu bar extra action runs while the
    /// status menu is still tracking, and AppKit returns focus to the previously
    /// active app when tracking ends, which undoes an activation made inside the action.
    func present() {
        NSApp.setActivationPolicy(.regular)
        DispatchQueue.main.async { self.raise() }
    }

    private func raise() {
        NSApp.activate(ignoringOtherApps: true)
        guard let window else { return }
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
    }

    private func didClose() {
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
