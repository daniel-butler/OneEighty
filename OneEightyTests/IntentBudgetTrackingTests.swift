import XCTest
@testable import OneEighty

final class IntentBudgetTrackingTests: XCTestCase {

    // NOTE: Prior to Task 10, these tests also asserted that IntentActivityDebouncer
    // flushes were forwarded into LiveActivityManager's tracker, via a
    // `setUpdateHandler` wiring installed in `LiveActivityManager.init`. That wiring
    // was removed in Task 10 — `LiveActivityManager.apply(_:AppState)` is now the sole
    // entry point, gated by the store's version-based dedupe (see
    // `ActivityCoordinationTests` and `LiveActivityManagerTests`). `IntentActivityDebouncer`
    // itself is deleted in Task 11 in favor of intents mutating the store directly and
    // calling `LiveActivityManager.shared.apply(store.state)`. These tests now cover only
    // the debouncer's own flush/coalescing behavior.

    nonisolated func testDebouncerFlushesCriticalImmediately() async {
        await MainActor.run {
            IntentActivityDebouncer.shared.resetForTesting()

            IntentActivityDebouncer.shared.submit(bpm: 180, isPlaying: true, priority: .critical)

            XCTAssertEqual(IntentActivityDebouncer.shared.flushCount, 1,
                           "Debouncer should have flushed once")
        }
    }

    /// The debouncer itself does not dedup identical states — each submit/reset cycle flushes.
    nonisolated func testDuplicateSubmitsEachProduceAFlush() async {
        await MainActor.run {
            IntentActivityDebouncer.shared.resetForTesting()

            // First flush
            IntentActivityDebouncer.shared.submit(bpm: 180, isPlaying: true, priority: .critical)
        }

        try? await Task.sleep(for: .milliseconds(400))

        await MainActor.run {
            XCTAssertEqual(IntentActivityDebouncer.shared.flushCount, 1, "First flush should be recorded")

            // Second flush with same state — debouncer has no dedup of its own.
            IntentActivityDebouncer.shared.resetForTesting()
            IntentActivityDebouncer.shared.submit(bpm: 180, isPlaying: true, priority: .critical)
        }

        try? await Task.sleep(for: .milliseconds(400))

        await MainActor.run {
            XCTAssertEqual(IntentActivityDebouncer.shared.flushCount, 1, "Second flush should also be recorded")
        }
    }

    /// Batched BPM changes coalesce into a single debouncer flush
    nonisolated func testBatchedBPMProducesSingleDebouncerFlush() async {
        await MainActor.run {
            IntentActivityDebouncer.shared.resetForTesting()

            // Rapid BPM taps
            for bpm in 181...185 {
                IntentActivityDebouncer.shared.submit(bpm: bpm, isPlaying: true, priority: .normal)
            }
        }

        try? await Task.sleep(for: .milliseconds(500))

        await MainActor.run {
            XCTAssertEqual(IntentActivityDebouncer.shared.flushCount, 1,
                           "Debouncer should coalesce into 1 flush")
        }
    }
}
