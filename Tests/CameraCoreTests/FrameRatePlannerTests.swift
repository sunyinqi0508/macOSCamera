import CameraCore
import Foundation
import Testing

@Suite("FrameRatePlanner")
struct FrameRatePlannerTests {
    @Test("requested rate is kept when a range covers it")
    func requestedRateKeptWhenSupported() {
        let resolved = FrameRatePlanner.resolve(requested: 30, supported: [1.0...60.0])
        #expect(resolved == 30.0)
    }

    @Test("unsupported rate clamps to the nearest achievable value")
    func unsupportedRateClamps() {
        #expect(FrameRatePlanner.resolve(requested: 60, supported: [1.0...30.0]) == 30.0)
        #expect(FrameRatePlanner.resolve(requested: 10, supported: [24.0...30.0]) == 24.0)
    }

    @Test("nearest range wins across disjoint ranges")
    func nearestRangeWins() {
        let resolved = FrameRatePlanner.resolve(requested: 50, supported: [1.0...30.0, 55.0...60.0])
        #expect(resolved == 55.0)
    }

    @Test("no ranges means no change")
    func emptyRangesReturnNil() {
        #expect(FrameRatePlanner.resolve(requested: 30, supported: []) == nil)
    }
}
