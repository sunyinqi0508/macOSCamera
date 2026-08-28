import CameraCore
import Foundation
import Testing

@Suite("CaptureStateMachine")
struct CaptureStateMachineTests {
    @Test("start preview then start recording then stop recording")
    func previewToRecordFlow() throws {
        var machine = CaptureStateMachine()

        try machine.transition(.startPreview(sourceID: "cam-1"))
        #expect(machine.state == .previewing(sourceID: "cam-1"))

        try machine.transition(.startRecording)
        #expect(machine.state == .recording(sourceID: "cam-1"))

        try machine.transition(.stopRecording)
        #expect(machine.state == .previewing(sourceID: "cam-1"))
    }

    @Test("starting recording from idle throws")
    func recordingFromIdleThrows() {
        var machine = CaptureStateMachine()

        #expect(throws: CaptureStateError.previewRequired) {
            try machine.transition(.startRecording)
        }
    }

    @Test("stopping recording when not recording throws")
    func stopRecordingWithoutActiveRecordThrows() throws {
        var machine = CaptureStateMachine()
        try machine.transition(.startPreview(sourceID: "cam-1"))

        #expect(throws: CaptureStateError.notRecording) {
            try machine.transition(.stopRecording)
        }
    }
}
