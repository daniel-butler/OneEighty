import XCTest
@testable import OneEighty

@MainActor
final class MockStateSubscriber: StateSubscriber {
    var confirmedState: PlaybackState?
    var pushCount: Int = 0
    var lastPushedState: PlaybackState?

    func push(_ state: PlaybackState) {
        pushCount += 1
        lastPushedState = state
    }
}

final class StateSubscriberTests: XCTestCase {

    nonisolated func testReconcileNoOpWhenConfirmedMatchesCurrent() async {
        await MainActor.run {
            let subscriber = MockStateSubscriber()
            let state = PlaybackState(bpm: 180, isPlaying: true)
            subscriber.confirmedState = state
            subscriber.reconcile(currentState: state)
            XCTAssertEqual(subscriber.pushCount, 0,
                           "Should not push when confirmed matches current")
        }
    }

    nonisolated func testReconcilePushesWhenConfirmedDiffers() async {
        await MainActor.run {
            let subscriber = MockStateSubscriber()
            subscriber.confirmedState = PlaybackState(bpm: 180, isPlaying: true)
            let currentState = PlaybackState(bpm: 185, isPlaying: true)
            subscriber.reconcile(currentState: currentState)
            XCTAssertEqual(subscriber.pushCount, 1,
                           "Should push when confirmed differs from current")
            XCTAssertEqual(subscriber.lastPushedState, currentState,
                           "Should push the current engine state")
        }
    }

    nonisolated func testReconcilePushesWhenConfirmedIsNil() async {
        await MainActor.run {
            let subscriber = MockStateSubscriber()
            subscriber.confirmedState = nil
            let currentState = PlaybackState(bpm: 180, isPlaying: true)
            subscriber.reconcile(currentState: currentState)
            XCTAssertEqual(subscriber.pushCount, 1,
                           "Should push when never confirmed (nil)")
        }
    }

    nonisolated func testReconcileDetectsIsPlayingMismatch() async {
        await MainActor.run {
            let subscriber = MockStateSubscriber()
            subscriber.confirmedState = PlaybackState(bpm: 180, isPlaying: false)
            let currentState = PlaybackState(bpm: 180, isPlaying: true)
            subscriber.reconcile(currentState: currentState)
            XCTAssertEqual(subscriber.pushCount, 1,
                           "Should push when isPlaying differs")
        }
    }
}
