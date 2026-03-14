//
//  MetronomeEngineTests.swift
//  MetronomeAppTests
//
//  Tests for MetronomeEngine state management, BPM persistence, and playback.
//

import Combine
import XCTest
@testable import MetronomeApp

@MainActor
final class MetronomeEngineTests: XCTestCase {

    private var engine: MetronomeEngine!

    override func setUp() {
        engine = MetronomeEngine()
    }

    override func tearDown() {
        engine.teardown()
        engine = nil
    }

    // MARK: - BPM Persistence (Bug 3 fix)

    func testSetupRestoresBPMFromSharedState() {
        // Set BPM to non-default, tear down, then setup a new engine
        engine.setup()
        engine.setBPM(210)
        engine.teardown()

        let engine2 = MetronomeEngine()
        engine2.setup()
        XCTAssertEqual(engine2.bpm, 210, "setup() should restore BPM from SharedPlaybackState, not reset to 180")
        engine2.teardown()
    }

    func testSetupResetsIsPlayingToFalse() {
        engine.setup()
        engine.togglePlayback()
        XCTAssertTrue(engine.isPlaying)
        engine.teardown()

        let engine2 = MetronomeEngine()
        engine2.setup()
        XCTAssertFalse(engine2.isPlaying, "setup() should always start with isPlaying = false")
        engine2.teardown()
    }

    // MARK: - BPM Range

    func testBPMRange() {
        engine.setup()
        XCTAssertEqual(MetronomeEngine.bpmRange, 150...230)
    }

    func testIncrementBPMAtUpperBound() {
        engine.setup()
        engine.setBPM(230)
        XCTAssertFalse(engine.canIncrementBPM)
        engine.incrementBPM()
        XCTAssertEqual(engine.bpm, 230, "BPM should not exceed upper bound")
    }

    func testDecrementBPMAtLowerBound() {
        engine.setup()
        engine.setBPM(150)
        XCTAssertFalse(engine.canDecrementBPM)
        engine.decrementBPM()
        XCTAssertEqual(engine.bpm, 150, "BPM should not go below lower bound")
    }

    func testSetBPMClampsToRange() {
        engine.setup()
        engine.setBPM(999)
        XCTAssertEqual(engine.bpm, 230)
        engine.setBPM(1)
        XCTAssertEqual(engine.bpm, 150)
    }

    // MARK: - Playback Toggle

    func testTogglePlayback() {
        engine.setup()
        XCTAssertFalse(engine.isPlaying)
        engine.togglePlayback()
        XCTAssertTrue(engine.isPlaying)
        engine.togglePlayback()
        XCTAssertFalse(engine.isPlaying)
    }

    // MARK: - State Change via Publisher

    func testPublisherNotifiesOnToggle() {
        engine.setup()
        var callCount = 0
        let cancellable = engine.statePublisher.dropFirst().sink { _ in callCount += 1 }

        engine.togglePlayback()
        XCTAssertEqual(callCount, 1)

        engine.togglePlayback()
        XCTAssertEqual(callCount, 2)

        cancellable.cancel()
    }

    func testPublisherNotifiesOnBPMChange() {
        engine.setup()
        engine.setBPM(180)
        var callCount = 0
        let cancellable = engine.statePublisher.dropFirst().sink { _ in callCount += 1 }

        engine.incrementBPM()
        XCTAssertEqual(callCount, 1)

        engine.decrementBPM()
        XCTAssertEqual(callCount, 2)

        cancellable.cancel()
    }

    // MARK: - PlaybackState

    func testPlaybackStateEquality() {
        let state1 = PlaybackState(bpm: 180, isPlaying: false)
        let state2 = PlaybackState(bpm: 180, isPlaying: false)
        XCTAssertEqual(state1, state2)
    }

    func testPlaybackStateInequalityBPM() {
        let state1 = PlaybackState(bpm: 180, isPlaying: false)
        let state2 = PlaybackState(bpm: 200, isPlaying: false)
        XCTAssertNotEqual(state1, state2)
    }

    func testPlaybackStateInequalityPlaying() {
        let state1 = PlaybackState(bpm: 180, isPlaying: false)
        let state2 = PlaybackState(bpm: 180, isPlaying: true)
        XCTAssertNotEqual(state1, state2)
    }

    // MARK: - Publisher

    func testPublisherEmitsOnToggle() {
        engine.setup()
        var states: [PlaybackState] = []
        let cancellable = engine.statePublisher.dropFirst().sink { states.append($0) }

        engine.togglePlayback()
        XCTAssertEqual(states.count, 1)
        XCTAssertEqual(states.last, PlaybackState(bpm: engine.bpm, isPlaying: true))

        engine.togglePlayback()
        XCTAssertEqual(states.count, 2)
        XCTAssertEqual(states.last, PlaybackState(bpm: engine.bpm, isPlaying: false))

        cancellable.cancel()
    }

    func testPublisherEmitsOnBPMChange() {
        engine.setup()
        engine.setBPM(180)
        var states: [PlaybackState] = []
        let cancellable = engine.statePublisher.dropFirst().sink { states.append($0) }

        engine.incrementBPM()
        XCTAssertEqual(states.count, 1)
        XCTAssertEqual(states.last?.bpm, 181)

        cancellable.cancel()
    }

    func testPublisherEmitsOnSetBPM() {
        engine.setup()
        var states: [PlaybackState] = []
        let cancellable = engine.statePublisher.dropFirst().sink { states.append($0) }

        engine.setBPM(200)
        XCTAssertEqual(states.count, 1)
        XCTAssertEqual(states.last, PlaybackState(bpm: 200, isPlaying: false))

        cancellable.cancel()
    }

    func testPublisherCurrentValueAccessibleByLateSubscriber() {
        engine.setup()
        engine.setBPM(215)

        // Subscribe after state change — should get current value immediately
        var latestState: PlaybackState?
        let cancellable = engine.statePublisher.sink { latestState = $0 }

        XCTAssertEqual(latestState, PlaybackState(bpm: 215, isPlaying: false))

        cancellable.cancel()
    }

    // MARK: - ensureReady

    func testEnsureReadyIsIdempotent() {
        engine.ensureReady()
        let bpm1 = engine.bpm
        engine.ensureReady()
        XCTAssertEqual(engine.bpm, bpm1, "ensureReady should be safe to call multiple times")
    }

    func testEnsureReadyPreservesState() {
        engine.setup()
        engine.setBPM(200)
        engine.togglePlayback()
        XCTAssertTrue(engine.isPlaying)
        XCTAssertEqual(engine.bpm, 200)

        // ensureReady should no-op since already set up
        engine.ensureReady()
        XCTAssertTrue(engine.isPlaying, "ensureReady should not reset isPlaying")
        XCTAssertEqual(engine.bpm, 200, "ensureReady should not reset BPM")
    }

    // MARK: - InMemoryStateStore

    func testInMemoryStateStoreDefaults() {
        let store = InMemoryStateStore()
        XCTAssertEqual(store.bpm, 180)
        XCTAssertFalse(store.isPlaying)
        XCTAssertEqual(store.volume, 0.4)
    }

    func testInMemoryStateStoreRoundTrips() {
        let store = InMemoryStateStore()
        store.bpm = 200
        store.isPlaying = true
        store.volume = 0.8
        XCTAssertEqual(store.bpm, 200)
        XCTAssertTrue(store.isPlaying)
        XCTAssertEqual(store.volume, 0.8)
    }

    // MARK: - StateStore Injection

    func testEngineUsesInjectedStore() {
        let store = InMemoryStateStore()
        store.bpm = 200
        let injectedEngine = MetronomeEngine(store: store)
        injectedEngine.setup()
        XCTAssertEqual(injectedEngine.bpm, 200)
        injectedEngine.teardown()
    }

    // MARK: - External Changes

    func testExternalStateChangeUpdatesBPM() {
        let store = InMemoryStateStore()
        let injectedEngine = MetronomeEngine(store: store)
        injectedEngine.setup()

        store.bpm = 210
        store.simulateExternalChange(.stateChanged)

        XCTAssertEqual(injectedEngine.bpm, 210)
        injectedEngine.teardown()
    }

    func testExternalStartCommandStartsPlayback() {
        let store = InMemoryStateStore()
        let injectedEngine = MetronomeEngine(store: store)
        injectedEngine.setup()
        XCTAssertFalse(injectedEngine.isPlaying)

        store.simulateExternalChange(.command(.start))

        XCTAssertTrue(injectedEngine.isPlaying)
        injectedEngine.teardown()
    }

    func testExternalStopCommandStopsPlayback() {
        let store = InMemoryStateStore()
        let injectedEngine = MetronomeEngine(store: store)
        injectedEngine.setup()
        injectedEngine.togglePlayback()
        XCTAssertTrue(injectedEngine.isPlaying)

        store.simulateExternalChange(.command(.stop))

        XCTAssertFalse(injectedEngine.isPlaying)
        injectedEngine.teardown()
    }
}
