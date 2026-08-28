import CameraCore
import Foundation
import Testing

@Suite("AudioSourceMerger")
struct AudioSourceMergerTests {
    private let mic1 = AudioSourceSelection(id: "mic-1", name: "Built-in Mic", kind: .microphone)
    private let mic2 = AudioSourceSelection(id: "mic-2", name: "USB Mic", kind: .microphone)
    private let output = AudioSourceSelection(id: "out-1", name: "Speakers", kind: .systemOutput)

    @Test("first population enables only the first microphone")
    func firstPopulationEnablesDefaultMicrophone() {
        let merged = AudioSourceMerger.merge(existing: [], discovered: [mic1, mic2, output])

        #expect(merged.count == 3)
        #expect(merged[0].isEnabled)
        #expect(!merged[1].isEnabled)
        #expect(!merged[2].isEnabled)
    }

    @Test("existing state survives a merge and stale devices are dropped")
    func existingStateSurvivesMerge() {
        var tunedMic = mic2
        tunedMic.isEnabled = true
        tunedMic.gain = 1.5
        var staleMic = AudioSourceSelection(id: "gone", name: "Unplugged", kind: .microphone)
        staleMic.isEnabled = true

        let merged = AudioSourceMerger.merge(
            existing: [tunedMic, staleMic],
            discovered: [mic1, mic2, output]
        )

        #expect(merged.map(\.id) == ["mic-1", "mic-2", "out-1"])
        let kept = merged.first(where: { $0.id == "mic-2" })
        #expect(kept?.isEnabled == true)
        #expect(kept?.gain == 1.5)
        // Newly appeared devices arrive disabled.
        #expect(merged.first(where: { $0.id == "mic-1" })?.isEnabled == false)
    }

    @Test("losing the only enabled microphone promotes a surviving one")
    func losingEnabledMicrophonePromotesSurvivor() {
        var vanished = AudioSourceSelection(id: "gone", name: "Unplugged", kind: .microphone)
        vanished.isEnabled = true
        var disabledSurvivor = mic1
        disabledSurvivor.isEnabled = false

        let merged = AudioSourceMerger.merge(
            existing: [vanished, disabledSurvivor],
            discovered: [mic1, output]
        )

        #expect(merged.first(where: { $0.kind == .microphone })?.isEnabled == true)
    }

    @Test("mobile-backed microphones are never enabled by default")
    func mobileMicrophonesNeverDefault() {
        let phoneMic = AudioSourceSelection(id: "phone-mic", name: "iPhone Microphone", kind: .microphone)

        // First population: the phone is listed first but the local mic wins.
        let initial = AudioSourceMerger.merge(
            existing: [],
            discovered: [phoneMic, mic1, output],
            mobileSourceIDs: ["phone-mic"]
        )
        #expect(initial.first(where: { $0.id == "phone-mic" })?.isEnabled == false)
        #expect(initial.first(where: { $0.id == "mic-1" })?.isEnabled == true)

        // Survivor promotion: losing the enabled mic never promotes the phone.
        var vanished = AudioSourceSelection(id: "gone", name: "Unplugged", kind: .microphone)
        vanished.isEnabled = true
        let promoted = AudioSourceMerger.merge(
            existing: [vanished],
            discovered: [phoneMic, mic1],
            mobileSourceIDs: ["phone-mic"]
        )
        #expect(promoted.first(where: { $0.id == "phone-mic" })?.isEnabled == false)
        #expect(promoted.first(where: { $0.id == "mic-1" })?.isEnabled == true)
    }

    @Test("deliberately disabled microphones stay disabled")
    func deliberatelyDisabledStaysDisabled() {
        var disabled1 = mic1
        disabled1.isEnabled = false
        var disabled2 = mic2
        disabled2.isEnabled = false

        let merged = AudioSourceMerger.merge(
            existing: [disabled1, disabled2],
            discovered: [mic1, mic2]
        )

        #expect(merged.allSatisfy { !$0.isEnabled })
    }
}
