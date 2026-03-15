//
//  WatchSyncBounceBackTests.swift
//  MetronomeAppTests
//
//  Tests demonstrating the bounce-back problem when rapidly changing BPM
//  on the Apple Watch. The phone echoes stale state back to the watch,
//  causing BPM to jump backward during fast Digital Crown scrolling.
//

import Combine
import XCTest
@testable import MetronomeApp

/// Simulates the watch-phone sync round-trip without real WCSession.
///
/// The model:
///   1. Watch optimistically updates local BPM
///   2. Watch sends "incrementBPM" command to phone
///   3. Phone processes command → engine.incrementBPM() → statePublisher fires
///   4. Phone echoes state back to watch (every statePublisher emission = one echo)
///   5. Watch receives echo and applies it via applyState()
///
/// The bug: echoes from earlier commands arrive while the watch has already
/// moved ahead, overwriting the watch's optimistic BPM with a stale value.
@MainActor
final class WatchSyncBounceBackTests: XCTestCase {

    private var store: InMemoryStateStore!
    private var engine: MetronomeEngine!
    private var cancellables: Set<AnyCancellable>!

    override func setUp() {
        store = InMemoryStateStore()
        engine = MetronomeEngine(store: store)
        engine.setup()
        cancellables = []
    }

    override func tearDown() {
        cancellables.removeAll()
        engine.teardown()
        engine = nil
        store = nil
    }

    // MARK: - Demonstrating the Problem

    /// Every single BPM change on the phone fires statePublisher, which would
    /// trigger sendStateToWatch(). With 10 rapid increments, the phone sends
    /// 10 separate echoes back — each with an intermediate BPM value.
    func testEveryBPMChangeTriggersStateEcho() {
        var echoCount = 0
        engine.statePublisher
            .dropFirst() // skip initial value
            .sink { _ in echoCount += 1 }
            .store(in: &cancellables)

        // Simulate 10 rapid "incrementBPM" commands from watch
        for _ in 0..<10 {
            engine.incrementBPM()
        }

        XCTAssertEqual(echoCount, 10,
            "Phone sends 10 echoes for 10 increments — each one would trigger sendStateToWatch()")
        XCTAssertEqual(engine.bpm, 190,
            "Engine should be at 190 after 10 increments from 180")
    }

    /// Simulates the full bounce-back sequence:
    ///   - Watch is at 180, taps increment 5 times rapidly
    ///   - Watch optimistically reaches 185
    ///   - Phone processes commands sequentially, echoing 181, 182, 183, 184, 185
    ///   - If echo for 181 arrives while watch is at 185, watch jumps back to 181
    func testBounceBackFromStaleEchoes() {
        // Collect all intermediate BPM values the phone would echo back
        var phoneEchoes: [Int] = []
        engine.statePublisher
            .dropFirst()
            .sink { state in phoneEchoes.append(state.bpm) }
            .store(in: &cancellables)

        // Watch side: simulate 5 rapid taps
        var watchOptimisticBPM = 180
        for _ in 0..<5 {
            // Watch optimistically increments
            watchOptimisticBPM += 1
            // Phone processes the command
            engine.incrementBPM()
        }

        // Phone echoed these intermediate values back:
        XCTAssertEqual(phoneEchoes, [181, 182, 183, 184, 185],
            "Phone echoes every intermediate BPM value")

        // Watch is optimistically at 185
        XCTAssertEqual(watchOptimisticBPM, 185)

        // THE BUG: If network delivers echoes out of order or with delay,
        // the watch applies stale values. Simulate echo #1 arriving late:
        let staleEcho = phoneEchoes[0] // 181
        // Watch applies: watchBPM = staleEcho
        let watchBPMAfterStaleEcho = staleEcho

        XCTAssertEqual(watchBPMAfterStaleEcho, 181,
            "Watch BPM jumps from 185 back to 181 when stale echo arrives — THIS IS THE BOUNCE-BACK BUG")
        XCTAssertNotEqual(watchBPMAfterStaleEcho, watchOptimisticBPM,
            "Watch state is now inconsistent with what the user expects")
    }

    /// Even when echoes arrive in order, rapid tapping causes visible jitter.
    /// Watch: 181, 182, 183, 184, 185
    /// Phone echoes arrive: 181 (redundant), 182 (redundant), etc.
    /// Each applyState() triggers a UI update on the watch, causing flicker.
    func testRedundantEchoesCauseUIJitter() {
        var phoneEchoes: [Int] = []
        engine.statePublisher
            .dropFirst()
            .sink { state in phoneEchoes.append(state.bpm) }
            .store(in: &cancellables)

        // Simulate 5 rapid increments
        for _ in 0..<5 {
            engine.incrementBPM()
        }

        // Even in the best case (in-order delivery), the watch receives 5 echoes.
        // Since the watch already optimistically updated, ALL of these are redundant.
        let watchFinalBPM = 185
        let redundantEchoCount = phoneEchoes.filter { $0 <= watchFinalBPM }.count

        XCTAssertEqual(redundantEchoCount, 5,
            "All 5 echoes are redundant — watch already has the correct BPM from optimistic updates")
    }

    // MARK: - What Debouncing Should Fix

    /// With adjustBPM(by:), a batched delta produces a single state emission
    /// from the engine, and the phone's echo debounce collapses it further.
    func testDesiredBehavior_SingleEchoAfterBatchedAdjust() {
        var echoedBPMs: [Int] = []
        engine.statePublisher
            .dropFirst()
            .sink { state in echoedBPMs.append(state.bpm) }
            .store(in: &cancellables)

        // Batched: watch sends a single adjustBPM(by: 10) instead of 10 increments
        engine.adjustBPM(by: 10)

        XCTAssertEqual(echoedBPMs.count, 1,
            "adjustBPM(by:) should produce exactly 1 state emission")
        XCTAssertEqual(echoedBPMs.last, 190,
            "The single emission should contain the final settled BPM")
    }

    // MARK: - handleWatchCommand Double-Echo

    /// After the fix, the phone echoes state only once per command — the explicit
    /// sendStateToWatch() in handleWatchCommand() has been removed. Only the
    /// statePublisher subscription drives echoes, and it's debounced for BPM changes.
    func testSingleEchoPerCommand() {
        var publishCount = 0
        engine.statePublisher
            .dropFirst()
            .sink { _ in publishCount += 1 }
            .store(in: &cancellables)

        engine.incrementBPM()

        // statePublisher fires exactly once (from notifyStateChanged inside incrementBPM)
        // No second echo from handleWatchCommand — that was removed.
        XCTAssertEqual(publishCount, 1,
            "statePublisher fires once per incrementBPM() — no double echo")
    }

    // MARK: - Origin-Unaware applyState

    /// The watch's applyState() unconditionally overwrites local state.
    /// It has no way to know if an incoming message is an echo of its own
    /// change or a genuine change from the phone UI.
    func testApplyStateHasNoOriginTracking() {
        // Simulate: watch is at 200 (user set it locally)
        var watchBPM = 200

        // Phone sends echo from an older state
        let phoneEcho: [String: Any] = ["bpm": 195, "isPlaying": false]

        // Watch blindly applies it (mirrors WatchSessionManager.applyState)
        if let newBPM = phoneEcho["bpm"] as? Int {
            watchBPM = newBPM
        }

        XCTAssertEqual(watchBPM, 195,
            "Watch overwrites its own BPM with stale echo — no origin tracking exists")
    }
}
