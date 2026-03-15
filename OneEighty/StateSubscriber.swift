import Foundation

@MainActor
protocol StateSubscriber: AnyObject {
    /// What the remote store last confirmed it holds.
    var confirmedState: PlaybackState? { get }

    /// Push state to the remote store.
    func push(_ state: PlaybackState)

    /// Compare confirmedState against source of truth, push if different.
    func reconcile(currentState: PlaybackState)
}

extension StateSubscriber {
    func reconcile(currentState: PlaybackState) {
        guard confirmedState != currentState else { return }
        push(currentState)
    }
}
