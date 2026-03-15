import XCTest
@testable import OneEighty

final class IntentBudgetTrackingTests: XCTestCase {

    nonisolated func testIntentTrackerRecordsUpdates() async {
        await MainActor.run {
            let tracker = IntentUpdateTracker.shared
            tracker.reset()

            tracker.recordIntentUpdate(intent: "StartOneEighty", bpm: 180, isPlaying: true)

            XCTAssertEqual(tracker.tracker.totalUpdateCount, 1)
        }
    }

    nonisolated func testIntentTrackerTracksIntentNames() async {
        await MainActor.run {
            let tracker = IntentUpdateTracker.shared
            tracker.reset()

            tracker.recordIntentUpdate(intent: "IncrementBPM", bpm: 181, isPlaying: true)
            tracker.recordIntentUpdate(intent: "DecrementBPM", bpm: 180, isPlaying: true)

            XCTAssertEqual(tracker.tracker.totalUpdateCount, 2)
        }
    }
}
