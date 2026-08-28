import Foundation

public enum AudioMuxingError: Error, Equatable {
    case noSourcesEnabled
}

public struct PreparedAudioMix: Equatable, Sendable {
    public var activeSourceIDs: [String]
    public var normalizedGains: [String: Double]

    public init(activeSourceIDs: [String], normalizedGains: [String: Double]) {
        self.activeSourceIDs = activeSourceIDs
        self.normalizedGains = normalizedGains
    }
}

public enum AudioMuxingPlanner {
    public static func prepare(from sources: [AudioSourceSelection]) throws -> PreparedAudioMix {
        let enabled = sources.filter { $0.isEnabled }
        guard !enabled.isEmpty else {
            throw AudioMuxingError.noSourcesEnabled
        }

        let clamped = enabled.map { max(0.0, min(2.0, $0.gain)) }
        let total = clamped.reduce(0.0, +)
        let normalizationFactor = total <= 0 ? 1.0 : total

        var normalized: [String: Double] = [:]
        for (index, source) in enabled.enumerated() {
            normalized[source.id] = clamped[index] / normalizationFactor
        }

        return PreparedAudioMix(
            activeSourceIDs: enabled.map(\.id),
            normalizedGains: normalized
        )
    }
}
