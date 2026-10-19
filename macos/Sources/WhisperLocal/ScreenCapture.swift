import AppKit
import ApplicationServices
import ScreenCaptureKit

/// Screenshot of the area around the focused text field, as context for the rewording model.
@MainActor
enum ScreenCapture {
    enum Failure: Error {
        case permission
        case capture
    }

    private static var requestedAccess = false

    /// PNG of at most 1280×800 px (the crop size in points). Leaves out this app's own windows (the overlay).
    static func focusedArea() async -> Result<Data, Failure> {
        guard CGPreflightScreenCaptureAccess() else {
            if !requestedAccess {
                requestedAccess = true
                CGRequestScreenCaptureAccess()
            }
            return .failure(.permission)
        }
        guard let target = focusedFrame(),
              let displayID = display(containing: CGPoint(x: target.midX, y: target.midY))
        else { return .failure(.capture) }
        let bounds = CGDisplayBounds(displayID)
        let crop = ScreenContext.cropRect(around: target, in: bounds)
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                return .failure(.capture)
            }
            let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
            let configuration = SCStreamConfiguration()
            configuration.sourceRect = crop.offsetBy(dx: -bounds.minX, dy: -bounds.minY)
            configuration.width = Int(crop.width)
            configuration.height = Int(crop.height)
            configuration.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                return .failure(.capture)
            }
            return .success(png)
        } catch {
            return .failure(.capture)
        }
    }

    /// The focused element's frame, else the frontmost window's; top-left global coordinates.
    private static func focusedFrame() -> CGRect? {
        if let element = attribute(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute),
           let frame = frame(of: element) {
            return frame
        }
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let window = attribute(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute)
        else { return nil }
        return frame(of: window)
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var position = CGPoint.zero
        var size = CGSize.zero
        guard let positionValue = axValue(element, kAXPositionAttribute),
              let sizeValue = axValue(element, kAXSizeAttribute),
              AXValueGetValue(positionValue, .cgPoint, &position),
              AXValueGetValue(sizeValue, .cgSize, &size),
              size.width > 0, size.height > 0
        else { return nil }
        return CGRect(origin: position, size: size)
    }

    private static func axValue(_ element: AXUIElement, _ name: String) -> AXValue? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return (value as! AXValue)
    }

    private static func display(containing point: CGPoint) -> CGDirectDisplayID? {
        var displayID = CGDirectDisplayID()
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(point, 1, &displayID, &count) == .success, count > 0 else { return nil }
        return displayID
    }
}
