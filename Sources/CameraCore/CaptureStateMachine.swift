import Foundation

public enum CaptureSessionState: Equatable, Sendable {
    case idle
    case previewing(sourceID: String)
    case recording(sourceID: String)
}

public enum CaptureAction: Sendable {
    case startPreview(sourceID: String)
    case stopPreview
    case startRecording
    case stopRecording
}

public enum CaptureStateError: Error, Equatable {
    case previewRequired
    case recordingAlreadyInProgress
    case notRecording
}

public struct CaptureStateMachine: Sendable {
    public private(set) var state: CaptureSessionState

    public init(state: CaptureSessionState = .idle) {
        self.state = state
    }

    @discardableResult
    public mutating func transition(_ action: CaptureAction) throws -> CaptureSessionState {
        switch (state, action) {
        case (_, .startPreview(let sourceID)):
            state = .previewing(sourceID: sourceID)

        case (.idle, .startRecording):
            throw CaptureStateError.previewRequired

        case (.previewing(let sourceID), .startRecording):
            state = .recording(sourceID: sourceID)

        case (.recording, .startRecording):
            throw CaptureStateError.recordingAlreadyInProgress

        case (.recording(let sourceID), .stopRecording):
            state = .previewing(sourceID: sourceID)

        case (.previewing, .stopRecording), (.idle, .stopRecording):
            throw CaptureStateError.notRecording

        case (_, .stopPreview):
            state = .idle
        }

        return state
    }
}
