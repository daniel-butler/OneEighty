import Foundation

/// The single versioned source of truth for shared playback state.
/// Volume is intentionally excluded — it is app-local audio config.
struct AppState: Codable, Equatable {
    var version: UInt64
    var bpm: Int
    var isPlaying: Bool

    static let bpmRange = 150...230
    static let defaultState = AppState(version: 0, bpm: 180, isPlaying: false)

    /// Pins fields to their legal ranges. Call after every mutation.
    mutating func clampInvariants() {
        bpm = min(Self.bpmRange.upperBound, max(Self.bpmRange.lowerBound, bpm))
    }
}
