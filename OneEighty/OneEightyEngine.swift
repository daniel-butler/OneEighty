//
//  OneEightyEngine.swift
//  OneEighty
//
//  Idempotent reconciler over PlaybackStore. Owns no independent truth:
//  it mirrors store.state into @Observable projections for the UI and drives
//  an injected AudioOutput to match via reconcileAudio().
//
//  ContentView and PhoneSessionManager are thin clients of this engine.
//

import Combine
import Foundation
import Observation
import os

private let logger = Logger(subsystem: "com.danielbutler.OneEighty", category: "OneEightyEngine")

/// Transitional type — kept until PhoneSessionManager/LiveActivityManager/StateSubscriber
/// migrate off it (final cleanup task). New code uses AppState.
struct PlaybackState: Equatable {
    let bpm: Int
    let isPlaying: Bool
}

@Observable
@MainActor
final class OneEightyEngine {
    // UI projection of store.state
    private(set) var bpm: Int = 180
    private(set) var isPlaying: Bool = false

    var currentVersion: UInt64 { store.state.version }

    /// Compatibility publisher for not-yet-migrated consumers (PhoneSessionManager, LA wiring).
    var statePublisher: AnyPublisher<PlaybackState, Never> {
        store.statePublisher
            .map { PlaybackState(bpm: $0.bpm, isPlaying: $0.isPlaying) }
            .eraseToAnyPublisher()
    }

    var volume: Float = 0.4 {
        didSet { store.volume = volume; audio.setVolume(volume) }
    }

    static let bpmRange = AppState.bpmRange
    var canIncrementBPM: Bool { bpm < Self.bpmRange.upperBound }
    var canDecrementBPM: Bool { bpm > Self.bpmRange.lowerBound }

    @ObservationIgnored private let store: PlaybackStore
    @ObservationIgnored private let audio: AudioOutput
    @ObservationIgnored private var bag = Set<AnyCancellable>()

    // `audio` is optional-with-nil-default rather than `= AVAudioOutput()` because a
    // default-argument expression is evaluated in a nonisolated context, and
    // AVAudioOutput's init is @MainActor-isolated. Constructing it in the (isolated)
    // init body sidesteps that while keeping `OneEightyEngine()` callable.
    init(store: PlaybackStore = AppGroupPlaybackStore.shared, audio: AudioOutput? = nil) {
        self.store = store
        self.audio = audio ?? AVAudioOutput()
    }

    nonisolated deinit {
        // nonisolated deinit prevents Swift from scheduling deallocation on the
        // main actor via swift_task_deinitOnExecutorImpl, which avoids a
        // TaskLocal.StopLookupScope crash in unit tests. The deinit body is
        // intentionally empty; Combine subscriptions clean up on dealloc.
    }

    /// Single hydration path: mirror store, reconcile audio, subscribe to changes.
    func hydrate() {
        guard !hydrated else { return }
        hydrated = true
        volume = store.volume
        audio.setVolume(volume)
        syncFromStore(store.state)
        store.statePublisher
            .sink { [weak self] state in self?.syncFromStore(state) }
            .store(in: &bag)
    }

    private func syncFromStore(_ state: AppState) {
        bpm = state.bpm
        isPlaying = state.isPlaying
        reconcileAudio()
    }

    /// Idempotent: drive audio to match desired state. Rolls back on start failure.
    func reconcileAudio() {
        if isPlaying && !audio.isRunning {
            audio.start(bpm: bpm)
            if !audio.isRunning {
                logger.error("audio failed to start — rolling back desired isPlaying")
                store.mutate { $0.isPlaying = false }
            }
        } else if !isPlaying && audio.isRunning {
            audio.stop()
        } else if audio.isRunning {
            audio.updateBPM(bpm)
        }
    }

    // MARK: - Controls (all mutate the store; syncFromStore drives audio)

    func togglePlayback() { store.mutate { $0.isPlaying.toggle() } }
    func setBPM(_ newBPM: Int) { store.mutate { $0.bpm = newBPM } }
    func adjustBPM(by delta: Int) { store.mutate { $0.bpm += delta } }
    func incrementBPM() { store.mutate { $0.bpm += 1 } }
    func decrementBPM() { store.mutate { $0.bpm -= 1 } }
    func setVolume(_ newVolume: Float) { volume = max(0, min(1, newVolume)) }

    // MARK: - Compatibility shims (removed in the final cleanup task)
    // Keep ContentView / PhoneSessionManager compiling until Stages 3–4 migrate them.
    @ObservationIgnored private var hydrated = false
    func setup() { ensureReady() }
    func teardown() {}
    func ensureReady() { hydrate() }
}
