import XCTest
@testable import OneEighty

final class DeltaCommandTests: XCTestCase {

    nonisolated func testAdjustBPMDeltaApplied() async {
        await MainActor.run {
            let store = InMemoryStateStore()
            let engine = OneEightyEngine(store: store)
            engine.setup()
            store.simulateExternalChange(.command(.adjustBPM(1)))
            XCTAssertEqual(engine.bpm, 181, "Delta +1 from 180 should give 181")
            engine.teardown()
        }
    }

    nonisolated func testMultipleSequentialDeltas() async {
        await MainActor.run {
            let store = InMemoryStateStore()
            let engine = OneEightyEngine(store: store)
            engine.setup()
            for _ in 0..<4 {
                store.simulateExternalChange(.command(.adjustBPM(1)))
            }
            XCTAssertEqual(engine.bpm, 184, "4x +1 deltas from 180 should give 184")
            engine.teardown()
        }
    }

    nonisolated func testDeltaClampedAtUpperBound() async {
        await MainActor.run {
            let store = InMemoryStateStore()
            store.bpm = 229
            let engine = OneEightyEngine(store: store)
            engine.setup()
            store.simulateExternalChange(.command(.adjustBPM(5)))
            XCTAssertEqual(engine.bpm, 230, "Should clamp at upper bound 230")
            engine.teardown()
        }
    }

    nonisolated func testDeltaClampedAtLowerBound() async {
        await MainActor.run {
            let store = InMemoryStateStore()
            store.bpm = 151
            let engine = OneEightyEngine(store: store)
            engine.setup()
            store.simulateExternalChange(.command(.adjustBPM(-5)))
            XCTAssertEqual(engine.bpm, 150, "Should clamp at lower bound 150")
            engine.teardown()
        }
    }

    nonisolated func testMixedDeltas() async {
        await MainActor.run {
            let store = InMemoryStateStore()
            let engine = OneEightyEngine(store: store)
            engine.setup()
            store.simulateExternalChange(.command(.adjustBPM(3)))
            store.simulateExternalChange(.command(.adjustBPM(-1)))
            XCTAssertEqual(engine.bpm, 182, "+3 -1 from 180 = 182")
            engine.teardown()
        }
    }
}
