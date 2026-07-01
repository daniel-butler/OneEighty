import XCTest
@testable import OneEighty

final class IntentBudgetTrackingTests: XCTestCase {

    // NOTE: Prior to Task 11, these tests exercised `IntentActivityDebouncer`'s
    // batching/coalescing behavior for widget-extension BPM intents. As of Task
    // 11, the debouncer is deleted: `IncrementBPMIntent`/`DecrementBPMIntent`
    // mutate `AppGroupPlaybackStore` with an absolute delta and push the
    // post-mutation actual value straight to `LiveActivityManager.apply(_:)`,
    // which is itself deduped by the store's version-based `claimActivityPush`
    // (see `ActivityCoordinationTests` and `LiveActivityManagerTests`). These
    // tests now cover the store-level convergence property that replaced the
    // debouncer's job: rapid absolute mutations always converge on the
    // correct final BPM, with no drift from estimating deltas.

    @MainActor
    func testRapidIncrementsConvergeToAbsoluteBPM() {
        let store = InMemoryPlaybackStore()
        for _ in 0..<5 { store.mutate { $0.bpm += 1 } }
        XCTAssertEqual(store.state.bpm, 185)
        XCTAssertEqual(store.state.version, 5)
    }

    @MainActor
    func testRapidDecrementsConvergeToAbsoluteBPM() {
        let store = InMemoryPlaybackStore()
        for _ in 0..<5 { store.mutate { $0.bpm -= 1 } }
        XCTAssertEqual(store.state.bpm, 175)
        XCTAssertEqual(store.state.version, 5)
    }

    /// Mixed rapid increments/decrements still converge on the correct
    /// absolute final value — no estimate drift, since each mutation reads
    /// and writes the actual current bpm.
    @MainActor
    func testMixedRapidAdjustmentsConvergeToAbsoluteBPM() {
        let store = InMemoryPlaybackStore()
        for _ in 0..<7 { store.mutate { $0.bpm += 1 } }
        for _ in 0..<3 { store.mutate { $0.bpm -= 1 } }
        XCTAssertEqual(store.state.bpm, 184)
        XCTAssertEqual(store.state.version, 10)
    }

    /// Rapid increments clamp at the upper bpm bound rather than overshooting.
    @MainActor
    func testRapidIncrementsClampAtUpperBound() {
        let store = InMemoryPlaybackStore(AppState(version: 0, bpm: 229, isPlaying: false))
        for _ in 0..<5 { store.mutate { $0.bpm += 1 } }
        XCTAssertEqual(store.state.bpm, 230)
        XCTAssertEqual(store.state.version, 5)
    }
}
