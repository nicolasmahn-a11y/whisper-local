import CoreGraphics
import Foundation

/// Where to take the screenshot that gives the rewording model context.
enum ScreenContext {
    static let cropSize = CGSize(width: 1280, height: 800)

    /// Top-left-origin global coordinates. Centred on the field, bottom edge 16 pt below it, extending
    /// upward, clamped inside the screen; a screen smaller than the crop is used whole in that dimension.
    static func cropRect(around field: CGRect, in screen: CGRect) -> CGRect {
        let width = min(cropSize.width, screen.width)
        let height = min(cropSize.height, screen.height)
        let x = min(max(field.midX - width / 2, screen.minX), screen.maxX - width)
        let y = min(max(field.maxY + 16 - height, screen.minY), screen.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
