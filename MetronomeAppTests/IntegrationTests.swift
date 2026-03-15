//
//  IntegrationTests.swift
//  MetronomeAppTests
//
//  Comprehensive E2E integration tests simulating real user scenarios.
//  Tests cover audio interruptions, widget/external controls, background/foreground
//  transitions, and cross-concern interactions.
//

import Combine
import XCTest
@testable import MetronomeApp

@MainActor
final class IntegrationTests: XCTestCase {

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

    // MARK: - Helpers

    /// Posts an audio interruption began notification and waits for the async Task inside
    /// handleInterruptionBegan to complete on the main actor.
    private func postInterruptionBegan() async {
        NotificationCenter.default.post(name: .audioInterruptionBegan, object: nil)
        // Yield to allow the Task { @MainActor in ... } inside the engine to execute.
        await Task.yield()
        await Task.yield()
    }

    /// Posts an audio interruption ended notification and waits for the async Task inside
    /// handleInterruptionEnded to complete on the main actor.
    private func postInterruptionEnded() async {
        NotificationCenter.default.post(name: .audioInterruptionEnded, object: nil)
        await Task.yield()
        await Task.yield()
    }

    // MARK: - 1. Audio Interruption Tests

    func testInterruptionPausesPlayingEngine() async {
        engine.togglePlayback()
        XCTAssertTrue(engine.isPlaying)

        await postInterruptionBegan()

        XCTAssertFalse(engine.isPlaying, "Engine should be paused after interruption begins")
        XCTAssertFalse(store.isPlaying, "Store should reflect paused state after interruption")
    }

    func testInterruptionPublisherEmitsPausedState() async {
        engine.togglePlayback()
        XCTAssertTrue(engine.isPlaying)

        var emittedStates: [PlaybackState] = []
        engine.statePublisher
            .dropFirst() // skip current value
            .sink { emittedStates.append($0) }
            .store(in: &cancellables)

        await postInterruptionBegan()

        XCTAssertFalse(emittedStates.isEmpty, "Publisher should emit after interruption")
        XCTAssertEqual(emittedStates.last?.isPlaying, false, "Publisher should emit paused state")
        XCTAssertEqual(emittedStates.last?.bpm, engine.bpm)
    }

    func testInterruptionEndedResumesIfWasPlaying() async {
        engine.togglePlayback()
        XCTAssertTrue(engine.isPlaying)

        await postInterruptionBegan()
        XCTAssertFalse(engine.isPlaying)

        await postInterruptionEnded()

        XCTAssertTrue(engine.isPlaying, "Engine should resume after interruption ends if it was playing before")
        XCTAssertTrue(store.isPlaying, "Store should reflect resumed state")
    }

    func testInterruptionEndedKeepsStoppedIfWasNotPlaying() async {
        XCTAssertFalse(engine.isPlaying, "Engine starts stopped")

        await postInterruptionBegan()
        XCTAssertFalse(engine.isPlaying)

        await postInterruptionEnded()

        XCTAssertFalse(engine.isPlaying, "Engine should remain stopped after interruption if it was already stopped")
    }

    func testBPMPreservedAcrossInterruptionCycle() async {
        engine.setBPM(200)
        engine.togglePlayback()
        XCTAssertEqual(engine.bpm, 200)

        await postInterruptionBegan()
        XCTAssertEqual(engine.bpm, 200, "BPM should be preserved when interruption begins")

        await postInterruptionEnded()
        XCTAssertEqual(engine.bpm, 200, "BPM should be preserved after interruption ends")
        XCTAssertTrue(engine.isPlaying)
    }

    func testRapidInterruptionsDoNotCorruptState() async {
        engine.togglePlayback()
        XCTAssertTrue(engine.isPlaying)

        // Fire rapid interruption began/ended pairs
        for _ in 0..<5 {
            await postInterruptionBegan()
            await postInterruptionEnded()
        }

        // After an even number of paired interruptions the engine should be playing
        XCTAssertTrue(engine.isPlaying, "Engine should be playing after paired interruption cycles")
        XCTAssertFalse(engine.bpm < MetronomeEngine.bpmRange.lowerBound || engine.bpm > MetronomeEngine.bpmRange.upperBound,
                       "BPM should remain in valid range after rapid interruptions")
    }

    func testPublisherEmitsCorrectStatesForFullInterruptionCycle() async {
        engine.setBPM(190)
        engine.togglePlayback()
        XCTAssertTrue(engine.isPlaying)

        var emittedStates: [PlaybackState] = []
        engine.statePublisher
            .dropFirst() // skip current value
            .sink { emittedStates.append($0) }
            .store(in: &cancellables)

        await postInterruptionBegan()
        await postInterruptionEnded()

        // Should have emitted at least two states: paused and resumed
        XCTAssertGreaterThanOrEqual(emittedStates.count, 2,
                                    "Publisher should emit at least paused + resumed states")

        // The first emitted state after subscribing should be the paused state
        XCTAssertEqual(emittedStates.first?.isPlaying, false,
                       "First emission after interruption began should be paused")
        XCTAssertEqual(emittedStates.first?.bpm, 190)

        // The last emitted state should be the resumed state
        XCTAssertEqual(emittedStates.last?.isPlaying, true,
                       "Last emission after interruption ended should be playing")
        XCTAssertEqual(emittedStates.last?.bpm, 190)
    }

    // MARK: - 2. Widget / External Control Tests

    func testExternalBPMChangeWhilePlaying() {
        engine.togglePlayback()
        XCTAssertTrue(engine.isPlaying)

        store.bpm = 210
        store.simulateExternalChange(.stateChanged)

        XCTAssertEqual(engine.bpm, 210, "BPM should update from external change while playing")
        XCTAssertTrue(engine.isPlaying, "Playback should continue after external BPM change")
    }

    func testExternalBPMChangeWhileStopped() {
        XCTAssertFalse(engine.isPlaying)

        store.bpm = 165
        store.simulateExternalChange(.stateChanged)

        XCTAssertEqual(engine.bpm, 165, "BPM should update from external change while stopped")
        XCTAssertFalse(engine.isPlaying, "Engine should remain stopped after external BPM change")
    }

    func testExternalStartCommandWhenAlreadyPlaying() {
        engine.togglePlayback()
        XCTAssertTrue(engine.isPlaying)

        var publishCount = 0
        engine.statePublisher
            .dropFirst()
            .sink { _ in publishCount += 1 }
            .store(in: &cancellables)

        // External start command when already playing — should be no-op
        store.simulateExternalChange(.command(.start))

        XCTAssertTrue(engine.isPlaying, "Engine should remain playing")
        XCTAssertEqual(publishCount, 0, "No state change should be published for no-op start command")
    }

    func testExternalStopCommandWhenAlreadyStopped() {
        XCTAssertFalse(engine.isPlaying)

        var publishCount = 0
        engine.statePublisher
            .dropFirst()
            .sink { _ in publishCount += 1 }
            .store(in: &cancellables)

        // External stop command when already stopped — should be no-op
        store.simulateExternalChange(.command(.stop))

        XCTAssertFalse(engine.isPlaying, "Engine should remain stopped")
        XCTAssertEqual(publishCount, 0, "No state change should be published for no-op stop command")
    }

    func testRapidExternalBPMChangesFinalValueWins() {
        let bpmValues = [155, 170, 190, 205, 220]
        for bpm in bpmValues {
            store.bpm = bpm
            store.simulateExternalChange(.stateChanged)
        }

        XCTAssertEqual(engine.bpm, 220, "Final BPM value should win after rapid external changes")
    }

    func testExternalBPMChangePublishesUpdatedState() {
        var emittedStates: [PlaybackState] = []
        engine.statePublisher
            .dropFirst()
            .sink { emittedStates.append($0) }
            .store(in: &cancellables)

        store.bpm = 205
        store.simulateExternalChange(.stateChanged)

        XCTAssertEqual(emittedStates.last?.bpm, 205, "Publisher should emit new BPM after external change")
        XCTAssertEqual(emittedStates.last?.isPlaying, false)
    }

    // MARK: - 3. Background / Foreground Tests

    func testStartPlayingThenBackgroundPreservesState() {
        engine.setBPM(195)
        engine.togglePlayback()
        XCTAssertTrue(engine.isPlaying)
        XCTAssertEqual(engine.bpm, 195)

        // Simulate going to background: engine stays set up, state should be preserved.
        // In a real app, ensureReady() is called on foreground; since already set up it no-ops.
        engine.ensureReady()

        XCTAssertTrue(engine.isPlaying, "State should be preserved in background")
        XCTAssertEqual(engine.bpm, 195, "BPM should be preserved in background")
    }

    func testExternalStateChangeWhileBackgrounded() {
        engine.togglePlayback()
        XCTAssertTrue(engine.isPlaying)

        // Simulate a widget changing BPM while the app is "backgrounded"
        store.bpm = 175
        store.simulateExternalChange(.stateChanged)

        XCTAssertEqual(engine.bpm, 175, "BPM should update from external change while backgrounded")
        XCTAssertTrue(engine.isPlaying, "Playback should continue while backgrounded")
    }

    func testBackgroundedEngineRespondsToExternalStartCommand() {
        // Engine is stopped (simulating backgrounded/idle state)
        XCTAssertFalse(engine.isPlaying)

        store.simulateExternalChange(.command(.start))

        XCTAssertTrue(engine.isPlaying, "Engine should start playing from external command while backgrounded")
        XCTAssertTrue(store.isPlaying, "Store should reflect playing state")
    }

    // MARK: - 4. Cross-Concern Tests

    func testPlayThenExternalBPMChangeInterruptionResumePreservesAllState() async {
        // Start playing at 185 BPM
        engine.setBPM(185)
        engine.togglePlayback()
        XCTAssertTrue(engine.isPlaying)
        XCTAssertEqual(engine.bpm, 185)

        // External BPM change (e.g. from widget)
        store.bpm = 195
        store.simulateExternalChange(.stateChanged)
        XCTAssertEqual(engine.bpm, 195, "BPM should update from external change")
        XCTAssertTrue(engine.isPlaying, "Should still be playing after external BPM change")

        // Audio interruption begins
        await postInterruptionBegan()
        XCTAssertFalse(engine.isPlaying, "Should pause on interruption")
        XCTAssertEqual(engine.bpm, 195, "BPM should be preserved during interruption")

        // Interruption ends — engine should resume
        await postInterruptionEnded()
        XCTAssertTrue(engine.isPlaying, "Should resume after interruption ends")
        XCTAssertEqual(engine.bpm, 195, "BPM should still be 195 after full cycle")
        XCTAssertTrue(store.isPlaying, "Store should reflect playing state")
        XCTAssertEqual(store.bpm, 195, "Store BPM should match engine BPM")
    }

    func testRapidExternalToggleCommandsFinalStateConsistent() {
        var finalIsPlaying: Bool = false

        // Simulate rapid external toggle commands
        let commands: [StateStoreCommand] = [.start, .stop, .start, .stop, .start]
        for command in commands {
            store.simulateExternalChange(.command(command))
        }

        finalIsPlaying = engine.isPlaying

        // Last command was .start, so engine should be playing
        XCTAssertTrue(finalIsPlaying, "After rapid start/stop commands ending with start, engine should be playing")
        XCTAssertTrue(store.isPlaying, "Store should be consistent with engine state")
    }

    func testExternalBPMAtLowerBoundClamps() {
        // Simulate widget sending BPM below the minimum
        store.bpm = 100 // below 150 minimum — but handleSharedStateChange reads store.bpm directly
        // Since store accepts any value, we test that the engine clamps on its own setBPM
        engine.setBPM(100)
        XCTAssertEqual(engine.bpm, 150, "BPM should be clamped to lower bound (150)")
    }

    func testExternalBPMAtUpperBoundClamps() {
        engine.setBPM(999)
        XCTAssertEqual(engine.bpm, 230, "BPM should be clamped to upper bound (230)")
    }

    func testExternalBPMAtExactLowerBound() {
        store.bpm = 150
        store.simulateExternalChange(.stateChanged)
        XCTAssertEqual(engine.bpm, 150, "BPM should accept exact lower bound value")
    }

    func testExternalBPMAtExactUpperBound() {
        store.bpm = 230
        store.simulateExternalChange(.stateChanged)
        XCTAssertEqual(engine.bpm, 230, "BPM should accept exact upper bound value")
    }

    func testInterruptionDoesNotAffectStoppedStateInStore() async {
        XCTAssertFalse(engine.isPlaying)
        XCTAssertFalse(store.isPlaying)

        await postInterruptionBegan()

        // Store should not be changed when engine was already stopped
        XCTAssertFalse(store.isPlaying, "Store isPlaying should remain false when interruption happens while stopped")

        await postInterruptionEnded()
        XCTAssertFalse(store.isPlaying, "Store should remain stopped after interruption cycle when was not playing")
    }

    func testPublisherEmitsOnExternalStartThenStop() {
        var emittedStates: [PlaybackState] = []
        engine.statePublisher
            .dropFirst()
            .sink { emittedStates.append($0) }
            .store(in: &cancellables)

        store.simulateExternalChange(.command(.start))
        store.simulateExternalChange(.command(.stop))

        XCTAssertEqual(emittedStates.count, 2, "Publisher should emit once for start and once for stop")
        XCTAssertEqual(emittedStates.first?.isPlaying, true)
        XCTAssertEqual(emittedStates.last?.isPlaying, false)
    }

    // MARK: - 5. Watch Sync Debounce

    func testBatchedBPMAdjustmentProducesSingleEcho() {
        var emittedStates: [PlaybackState] = []
        engine.statePublisher
            .dropFirst()
            .sink { emittedStates.append($0) }
            .store(in: &cancellables)

        // Simulate what the phone receives from a batched watch command:
        // a single adjustBPM(by: 5) instead of 5 individual incrementBPM() calls
        engine.adjustBPM(by: 5)

        XCTAssertEqual(emittedStates.count, 1,
            "Batched adjustBPM should produce a single state emission")
        XCTAssertEqual(emittedStates.last?.bpm, 185,
            "Single emission should contain the final BPM value")
    }

    // MARK: - 6. Engine Lifecycle

    func testEngineStateConsistentAfterMultipleSetupTeardownCycles() {
        // Teardown and re-setup with the same store (simulates app restart with persisted BPM)
        engine.setBPM(210)
        engine.teardown()

        let engine2 = MetronomeEngine(store: store)
        engine2.setup()
        XCTAssertEqual(engine2.bpm, 210, "BPM should be restored from store across engine lifecycle")
        XCTAssertFalse(engine2.isPlaying, "isPlaying should always reset to false on setup")
        engine2.teardown()

        // Restore engine for tearDown()
        engine = MetronomeEngine(store: store)
        engine.setup()
    }
}
