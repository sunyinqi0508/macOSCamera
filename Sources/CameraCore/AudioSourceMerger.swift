import Foundation

public enum AudioSourceMerger {
    /// Reconciles previously saved audio selections with the devices present right now.
    ///
    /// - Selections whose device is still connected keep their gain and enabled state
    ///   (the name is refreshed from the discovered device).
    /// - Selections whose device disappeared are dropped.
    /// - Newly discovered devices are appended disabled, so hotplugging never hijacks the mix.
    /// - On first population, only the first non-mobile microphone is enabled; devices in
    ///   `mobileSourceIDs` (iPhone/iPad Continuity) are never enabled automatically.
    /// - If the previously enabled microphone disappeared, the first remaining non-mobile
    ///   microphone is enabled so recordings don't silently lose audio.
    public static func merge(
        existing: [AudioSourceSelection],
        discovered: [AudioSourceSelection],
        mobileSourceIDs: Set<String> = []
    ) -> [AudioSourceSelection] {
        guard !existing.isEmpty else {
            var initial = discovered.map { source in
                var source = source
                source.isEnabled = false
                return source
            }
            if let firstMic = initial.firstIndex(where: {
                $0.kind == .microphone && !mobileSourceIDs.contains($0.id)
            }) {
                initial[firstMic].isEnabled = true
            }
            return initial
        }

        let existingByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })

        var merged = discovered.map { source -> AudioSourceSelection in
            guard var kept = existingByID[source.id] else {
                var added = source
                added.isEnabled = false
                return added
            }
            kept.name = source.name
            return kept
        }

        let hadEnabledMic = existing.contains { $0.kind == .microphone && $0.isEnabled }
        let hasEnabledMic = merged.contains { $0.kind == .microphone && $0.isEnabled }
        if hadEnabledMic, !hasEnabledMic,
           let firstMic = merged.firstIndex(where: {
               $0.kind == .microphone && !mobileSourceIDs.contains($0.id)
           }) {
            merged[firstMic].isEnabled = true
        }

        return merged
    }
}
