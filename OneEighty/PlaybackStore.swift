import Combine
import Foundation

/// One versioned source of truth for shared playback state, shared across the
/// app and the widget extension. Writers mutate absolute values; `version` is
/// bumped on every mutation so readers can reject stale snapshots.
@MainActor
protocol PlaybackStore: AnyObject {
    /// In-memory projection of the latest known state. Synchronous, main-actor.
    var state: AppState { get }

    /// Emits the current value immediately, then on every change (local or external).
    var statePublisher: AnyPublisher<AppState, Never> { get }

    /// Apply an absolute change. Bumps `version`, clamps invariants, persists,
    /// and signals other processes. Safe to call from the main actor.
    func mutate(_ transform: @escaping (inout AppState) -> Void)

    /// App-local audio config. Not versioned, not signalled cross-process.
    var volume: Float { get set }

    /// Atomically claim the right to push a Live Activity update for `version`.
    /// Returns `true` and records the push iff `version` is newer than the last
    /// recorded push version; else `false` (dedupe). Shared across processes so
    /// the app and widget extension agree on "what was last pushed."
    func claimActivityPush(version: UInt64, at date: Date) -> Bool

    /// Number of Live Activity pushes claimed within the last hour of `date`.
    func activityPushesInLastHour(at date: Date) -> Int
}
