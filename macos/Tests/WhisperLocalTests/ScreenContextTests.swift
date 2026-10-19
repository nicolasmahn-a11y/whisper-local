#if canImport(Testing)
import CoreGraphics
import Testing
@testable import WhisperLocal

struct ScreenContextTests {
    let screen = CGRect(x: 0, y: 0, width: 2560, height: 1440)

    @Test func cropSizeIs1280By800() {
        #expect(ScreenContext.cropSize == CGSize(width: 1280, height: 800))
    }

    @Test func centredHorizontallyAndBottomAlignedWithMargin() {
        let field = CGRect(x: 1000, y: 900, width: 400, height: 60)
        let rect = ScreenContext.cropRect(around: field, in: screen)
        #expect(rect.size == ScreenContext.cropSize)
        #expect(rect.midX == field.midX)
        #expect(rect.maxY == field.maxY + 16)
        #expect(rect.minY == field.maxY + 16 - 800)
    }

    @Test func clampsAtLeftEdge() {
        let field = CGRect(x: 10, y: 900, width: 200, height: 40)
        let rect = ScreenContext.cropRect(around: field, in: screen)
        #expect(rect.minX == 0)
        #expect(rect.width == 1280)
        #expect(rect.maxY == field.maxY + 16)
    }

    @Test func clampsAtRightEdge() {
        let field = CGRect(x: 2400, y: 900, width: 150, height: 40)
        let rect = ScreenContext.cropRect(around: field, in: screen)
        #expect(rect.maxX == screen.maxX)
        #expect(rect.width == 1280)
    }

    @Test func clampsAtTopEdge() {
        let field = CGRect(x: 1000, y: 100, width: 400, height: 40)
        let rect = ScreenContext.cropRect(around: field, in: screen)
        #expect(rect.minY == 0)
        #expect(rect.height == 800)
        #expect(rect.midX == field.midX)
    }

    @Test func fieldNearBottomEdgeClampsToScreenBottom() {
        let field = CGRect(x: 1000, y: 1420, width: 400, height: 20)
        let rect = ScreenContext.cropRect(around: field, in: screen)
        #expect(rect.maxY == screen.maxY)
        #expect(rect.height == 800)
        #expect(rect.minY == screen.maxY - 800)
    }

    @Test func screenNarrowerThanCropUsesFullWidth() {
        let small = CGRect(x: 0, y: 0, width: 1000, height: 1440)
        let field = CGRect(x: 400, y: 900, width: 200, height: 40)
        let rect = ScreenContext.cropRect(around: field, in: small)
        #expect(rect.minX == 0)
        #expect(rect.width == 1000)
        #expect(rect.height == 800)
    }

    @Test func screenShorterThanCropUsesFullHeight() {
        let small = CGRect(x: 0, y: 0, width: 2560, height: 600)
        let field = CGRect(x: 1000, y: 400, width: 400, height: 40)
        let rect = ScreenContext.cropRect(around: field, in: small)
        #expect(rect.minY == 0)
        #expect(rect.height == 600)
        #expect(rect.width == 1280)
    }

    @Test func screenSmallerThanCropInBothDimensionsIsFullScreen() {
        let small = CGRect(x: 0, y: 0, width: 800, height: 500)
        let rect = ScreenContext.cropRect(
            around: CGRect(x: 300, y: 400, width: 100, height: 30), in: small)
        #expect(rect == small)
    }

    @Test func respectsScreenWithNonZeroOrigin() {
        let secondary = CGRect(x: 2560, y: -200, width: 1920, height: 1080)
        let field = CGRect(x: 2570, y: 500, width: 100, height: 30)
        let rect = ScreenContext.cropRect(around: field, in: secondary)
        #expect(rect.minX == secondary.minX)
        #expect(secondary.contains(rect))
    }
}
#endif
