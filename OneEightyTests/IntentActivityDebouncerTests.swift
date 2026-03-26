import XCTest
@testable import OneEighty

final class IntentActivityDebouncerTests: XCTestCase {

    // MARK: - BPM Batching

    /// 5 rapid BPM increments within batch window → 1 flush with the final BPM
    nonisolated func testRapidBPMChangesCoalesceIntoSingleFlush() async {
        await MainActor.run {
            IntentActivityDebouncer.shared.resetForTesting()

            for bpm in 181...185 {
                IntentActivityDebouncer.shared.submit(bpm: bpm, isPlaying: true, priority: .normal)
            }

            XCTAssertTrue(IntentActivityDebouncer.shared.hasPending,
                          "Should have pending state during batch window")
            XCTAssertEqual(IntentActivityDebouncer.shared.flushCount, 0,
                           "No flushes should occur during batch window")
        }

        try? await Task.sleep(for: .milliseconds(200))

        await MainActor.run {
            let debouncer = IntentActivityDebouncer.shared
            XCTAssertEqual(debouncer.flushCount, 1,
                           "5 rapid BPM changes should coalesce into 1 flush")
            XCTAssertFalse(debouncer.hasPending,
                           "No pending state after flush")
        }
    }

    /// Only the last BPM in a rapid burst is flushed (intermediate values are dropped)
    nonisolated func testOnlyFinalBPMInBurstIsFlushed() async {
        await MainActor.run {
            IntentActivityDebouncer.shared.resetForTesting()

            IntentActivityDebouncer.shared.submit(bpm: 181, isPlaying: true, priority: .normal)
            IntentActivityDebouncer.shared.submit(bpm: 183, isPlaying: true, priority: .normal)
            IntentActivityDebouncer.shared.submit(bpm: 190, isPlaying: true, priority: .normal)
        }

        try? await Task.sleep(for: .milliseconds(200))

        await MainActor.run {
            let debouncer = IntentActivityDebouncer.shared
            XCTAssertEqual(debouncer.flushCount, 1,
                           "Intermediate BPM values should be dropped, only final flushed")
        }
    }

    // MARK: - Critical Priority

    /// Play/stop changes bypass the batch window and flush immediately
    nonisolated func testCriticalPriorityBypassesBatch() async {
        await MainActor.run {
            IntentActivityDebouncer.shared.resetForTesting()

            IntentActivityDebouncer.shared.submit(bpm: 180, isPlaying: true, priority: .critical)

            XCTAssertEqual(IntentActivityDebouncer.shared.flushCount, 1,
                           "Critical priority should flush immediately")
            XCTAssertFalse(IntentActivityDebouncer.shared.hasPending,
                           "Critical flush should not leave pending state")
        }
    }

    /// Critical update during a pending BPM batch: flushes the pending batch first, then the critical
    nonisolated func testCriticalDuringPendingBatchFlushesBoth() async {
        await MainActor.run {
            IntentActivityDebouncer.shared.resetForTesting()

            // Start a BPM batch (playing)
            IntentActivityDebouncer.shared.submit(bpm: 185, isPlaying: true, priority: .normal)
            XCTAssertTrue(IntentActivityDebouncer.shared.hasPending)

            // Critical arrives mid-batch: stop
            IntentActivityDebouncer.shared.submit(bpm: 185, isPlaying: false, priority: .critical)

            XCTAssertEqual(IntentActivityDebouncer.shared.flushCount, 2,
                           "Should flush pending batch + critical = 2 flushes")
            XCTAssertFalse(IntentActivityDebouncer.shared.hasPending)
        }
    }

    // MARK: - Fresh Batch After Flush

    /// After a batch fires, a new burst starts a fresh batch window
    nonisolated func testNewBurstAfterFlushStartsFreshBatch() async {
        await MainActor.run {
            IntentActivityDebouncer.shared.resetForTesting()

            // First burst
            IntentActivityDebouncer.shared.submit(bpm: 185, isPlaying: true, priority: .normal)
        }

        try? await Task.sleep(for: .milliseconds(200))

        await MainActor.run {
            XCTAssertEqual(IntentActivityDebouncer.shared.flushCount, 1)

            // Second burst — different BPM
            IntentActivityDebouncer.shared.submit(bpm: 190, isPlaying: true, priority: .normal)
            XCTAssertTrue(IntentActivityDebouncer.shared.hasPending,
                          "New burst should create new pending state")
        }

        try? await Task.sleep(for: .milliseconds(200))

        await MainActor.run {
            XCTAssertEqual(IntentActivityDebouncer.shared.flushCount, 2,
                           "Second burst should produce a second flush")
        }
    }

    // MARK: - Reset

    nonisolated func testResetClearsAllState() async {
        await MainActor.run {
            let debouncer = IntentActivityDebouncer.shared
            debouncer.resetForTesting()

            debouncer.submit(bpm: 180, isPlaying: true, priority: .critical)
            XCTAssertEqual(debouncer.flushCount, 1)

            debouncer.resetForTesting()

            XCTAssertEqual(debouncer.flushCount, 0)
            XCTAssertFalse(debouncer.hasPending)
        }
    }
}
