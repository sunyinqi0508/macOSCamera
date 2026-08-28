import CameraCore
import Foundation
import Testing

@Suite("DeviceInventory")
struct DeviceInventoryTests {
    @Test("selectableVideoInputs combines cameras and screens")
    func selectableVideoInputsContainsCameraAndScreen() {
        let inventory = DeviceInventory(
            cameras: [DeviceDescriptor(id: "cam-1", name: "FaceTime", type: .camera)],
            screens: [DeviceDescriptor(id: "100", name: "Built-in Display", type: .screen)]
        )

        let inputs = inventory.selectableVideoInputs
        #expect(inputs.count == 2)
        #expect(inputs.first(where: { $0.type == .camera })?.id == "cam-1")
        #expect(inputs.first(where: { $0.type == .screen })?.id == "100")
    }

    @Test("selectableAudioSources maps microphones and outputs")
    func selectableAudioSourcesMapsDevices() {
        let inventory = DeviceInventory(
            microphones: [DeviceDescriptor(id: "mic-1", name: "Mic", type: .microphone)],
            audioOutputs: [DeviceDescriptor(id: "out-1", name: "Output", type: .systemAudioOutput)]
        )

        let sources = inventory.selectableAudioSources
        #expect(sources.count == 2)
        #expect(sources.first(where: { $0.kind == .microphone })?.id == "mic-1")
        #expect(sources.first(where: { $0.kind == .systemOutput })?.id == "out-1")
    }
}
