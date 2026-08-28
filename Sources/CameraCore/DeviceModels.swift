import Foundation

public enum DeviceType: String, Codable, CaseIterable, Identifiable, Sendable {
    case camera
    case screen
    case microphone
    case systemAudioOutput

    public var id: String { rawValue }
}

public struct DeviceDescriptor: Equatable, Codable, Identifiable, Sendable {
    public let id: String
    public var name: String
    public var type: DeviceType

    public init(id: String, name: String, type: DeviceType) {
        self.id = id
        self.name = name
        self.type = type
    }
}

public struct DeviceInventory: Equatable, Sendable {
    public var cameras: [DeviceDescriptor]
    public var screens: [DeviceDescriptor]
    public var microphones: [DeviceDescriptor]
    public var audioOutputs: [DeviceDescriptor]
    /// IDs of devices backed by a mobile device (iPhone/iPad Continuity). They are
    /// selectable but must never be chosen as a default.
    public var mobileDeviceIDs: Set<String>

    public init(
        cameras: [DeviceDescriptor] = [],
        screens: [DeviceDescriptor] = [],
        microphones: [DeviceDescriptor] = [],
        audioOutputs: [DeviceDescriptor] = [],
        mobileDeviceIDs: Set<String> = []
    ) {
        self.cameras = cameras
        self.screens = screens
        self.microphones = microphones
        self.audioOutputs = audioOutputs
        self.mobileDeviceIDs = mobileDeviceIDs
    }

    public var selectableVideoInputs: [CaptureInputSelection] {
        let cameraInputs = cameras.map {
            CaptureInputSelection(id: $0.id, name: $0.name, type: .camera)
        }
        let screenInputs = screens.map {
            CaptureInputSelection(id: $0.id, name: $0.name, type: .screen)
        }

        return cameraInputs + screenInputs
    }

    public var selectableAudioSources: [AudioSourceSelection] {
        let micSources = microphones.map {
            AudioSourceSelection(id: $0.id, name: $0.name, kind: .microphone)
        }
        let outputSources = audioOutputs.map {
            AudioSourceSelection(id: $0.id, name: $0.name, kind: .systemOutput)
        }
        return micSources + outputSources
    }
}
