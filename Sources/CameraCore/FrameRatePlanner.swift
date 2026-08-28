import Foundation

public enum FrameRatePlanner {
    /// Returns the frame rate to actually configure for a requested rate given the
    /// device's supported ranges: the requested rate when a range covers it, otherwise
    /// the nearest achievable rate (preferring the higher on ties). `nil` when the
    /// device reports no ranges, in which case the caller should leave the device alone.
    public static func resolve(requested: Int, supported: [ClosedRange<Double>]) -> Double? {
        guard !supported.isEmpty else {
            return nil
        }

        let target = Double(requested)
        if supported.contains(where: { $0.contains(target) }) {
            return target
        }

        var best: Double?
        for range in supported {
            let candidate = min(max(target, range.lowerBound), range.upperBound)
            guard let current = best else {
                best = candidate
                continue
            }

            let candidateDistance = abs(candidate - target)
            let currentDistance = abs(current - target)
            if candidateDistance < currentDistance
                || (candidateDistance == currentDistance && candidate > current) {
                best = candidate
            }
        }

        return best
    }
}
