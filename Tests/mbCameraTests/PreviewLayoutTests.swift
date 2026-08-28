import CoreGraphics
import Testing
@testable import mbCamera

@Suite("PreviewLayout")
struct PreviewLayoutTests {
    @Test("aspect fit uses full width when container is taller than media")
    func aspectFitUsesFullWidth() {
        let rect = PreviewLayout.aspectFitRect(
            containerSize: CGSize(width: 1000, height: 800),
            aspectRatio: 16.0 / 9.0
        )

        #expect(rect.width == 1000)
        #expect(abs(rect.height - 562.5) < 0.001)
        #expect(abs(rect.origin.y - 118.75) < 0.001)
    }

    @Test("aspect fit uses full height when container is wider than media")
    func aspectFitUsesFullHeight() {
        let rect = PreviewLayout.aspectFitRect(
            containerSize: CGSize(width: 1200, height: 600),
            aspectRatio: 4.0 / 3.0
        )

        #expect(rect.height == 600)
        #expect(abs(rect.width - 800) < 0.001)
        #expect(abs(rect.origin.x - 200) < 0.001)
    }

    @Test("invalid inputs return zero rect")
    func invalidInputsReturnZeroRect() {
        #expect(
            PreviewLayout.aspectFitRect(containerSize: .zero, aspectRatio: 1.0) == .zero
        )
        #expect(
            PreviewLayout.aspectFitRect(containerSize: CGSize(width: 100, height: 100), aspectRatio: 0) == .zero
        )
    }
}
