import CameraCore
import Foundation
import Testing

@Suite("AudioMuxingPlanner")
struct AudioMuxingPlannerTests {
    @Test("prepare throws when no sources are enabled")
    func prepareThrowsWithoutEnabledSources() {
        let sources = [
            AudioSourceSelection(id: "mic", name: "Mic", kind: .microphone, gain: 1.0, isEnabled: false)
        ]

        #expect(throws: AudioMuxingError.noSourcesEnabled) {
            _ = try AudioMuxingPlanner.prepare(from: sources)
        }
    }

    @Test("prepare normalizes gains to one")
    func prepareNormalizesGains() throws {
        let sources = [
            AudioSourceSelection(id: "mic", name: "Mic", kind: .microphone, gain: 2.0, isEnabled: true),
            AudioSourceSelection(id: "output", name: "Output", kind: .systemOutput, gain: 1.0, isEnabled: true)
        ]

        let prepared = try AudioMuxingPlanner.prepare(from: sources)

        #expect(prepared.activeSourceIDs == ["mic", "output"])
        #expect(prepared.normalizedGains["mic"] == 2.0 / 3.0)
        #expect(prepared.normalizedGains["output"] == 1.0 / 3.0)
    }

    @Test("prepare clamps negative gains")
    func prepareClampsNegativeGains() throws {
        let sources = [
            AudioSourceSelection(id: "mic", name: "Mic", kind: .microphone, gain: -3.0, isEnabled: true),
            AudioSourceSelection(id: "out", name: "Out", kind: .systemOutput, gain: 1.0, isEnabled: true)
        ]

        let prepared = try AudioMuxingPlanner.prepare(from: sources)

        #expect(prepared.normalizedGains["mic"] == 0)
        #expect(prepared.normalizedGains["out"] == 1)
    }
}
