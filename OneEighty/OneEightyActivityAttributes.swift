import ActivityKit

struct OneEightyActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var bpm: Int
        var isPlaying: Bool
    }
}
