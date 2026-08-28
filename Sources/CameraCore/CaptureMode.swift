import Foundation

public enum CaptureMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case photo
    case video

    public var id: String { rawValue }
}
