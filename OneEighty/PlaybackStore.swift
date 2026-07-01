import Combine

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
}
