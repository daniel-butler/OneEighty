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
import MediaPlayer
import Observation
import UIKit
import os

private let logger = Logger(subsystem: "com.danielbutler.OneEighty", category: "OneEightyEngine")

/// Transitional type — still consumed by PhoneSessionManager and StateSubscriber
/// (watch-sync reconciliation). LiveActivityManager has fully migrated off it onto
/// AppState / PlaybackStateSnapshot. Kept intentionally; not dead code.
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
        startObservingInterruptions()
        setupRemoteCommands()
    }

    /// Called from the UI launch path (ContentView.onAppear). On a genuine cold
    /// launch, audio is not yet running, so reset desired playback to stopped —
    /// the app never auto-starts sound on open. If an AudioPlaybackIntent already
    /// started audio in this process, `audio.isRunning` is true and we preserve it.
    func hydrateForUILaunch() {
        if !audio.isRunning {
            store.mutate { $0.isPlaying = false }
        }
        hydrate()
    }

    private func syncFromStore(_ state: AppState) {
        bpm = state.bpm
        isPlaying = state.isPlaying
        LiveActivityManager.shared.apply(state)
        reconcileAudio()
        updateNowPlaying()
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

    func togglePlayback() {
        store.mutate { $0.isPlaying.toggle() }
        // User explicitly changed playback — if now stopped, drop any pending
        // interruption resume intent so we don't auto-resume against an explicit stop.
        if !isPlaying { wasPlayingBeforeInterruption = false }
    }
    func setBPM(_ newBPM: Int) { store.mutate { $0.bpm = newBPM } }
    func adjustBPM(by delta: Int) { store.mutate { $0.bpm += delta } }
    func incrementBPM() { store.mutate { $0.bpm += 1 } }
    func decrementBPM() { store.mutate { $0.bpm -= 1 } }
    func setVolume(_ newVolume: Float) { volume = max(0, min(1, newVolume)) }

    // MARK: - Interruptions
    @ObservationIgnored private var wasPlayingBeforeInterruption = false
    @ObservationIgnored private var isSessionInterrupted = false

    func startObservingInterruptions() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(onInterruptionBegan), name: .audioInterruptionBegan, object: nil)
        nc.addObserver(self, selector: #selector(onInterruptionEnded), name: .audioInterruptionEnded, object: nil)
        nc.addObserver(self, selector: #selector(onDidBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    @objc private func onInterruptionBegan() {
        Task { @MainActor in
            if !isSessionInterrupted { wasPlayingBeforeInterruption = isPlaying }
            isSessionInterrupted = true
            guard isPlaying else { return }
            store.mutate { $0.isPlaying = false }
        }
    }

    @objc private func onInterruptionEnded() {
        Task { @MainActor in
            isSessionInterrupted = false
            guard wasPlayingBeforeInterruption, !isPlaying else { wasPlayingBeforeInterruption = false; return }
            wasPlayingBeforeInterruption = false
            AudioSessionManager.shared.activate()
            store.mutate { $0.isPlaying = true }
        }
    }

    @objc private func onDidBecomeActive() {
        Task { @MainActor in
            guard wasPlayingBeforeInterruption, !isPlaying, isSessionInterrupted else { return }
            wasPlayingBeforeInterruption = false
            isSessionInterrupted = false
            AudioSessionManager.shared.activate()
            store.mutate { $0.isPlaying = true }
        }
    }

    // MARK: - Now Playing

    private func setupRemoteCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()

        commandCenter.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isPlaying else { return }
                self.togglePlayback()
            }
            return .success
        }

        commandCenter.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isPlaying else { return }
                self.togglePlayback()
            }
            return .success
        }

        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.togglePlayback()
            }
            return .success
        }

        // Repurpose next/previous track for BPM +/-
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.incrementBPM()
            }
            return .success
        }

        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.decrementBPM()
            }
            return .success
        }
    }

    private func updateNowPlaying() {
        let infoCenter = MPNowPlayingInfoCenter.default()
        infoCenter.nowPlayingInfo = [
            MPMediaItemPropertyTitle: "\(bpm) SPM",
            MPMediaItemPropertyArtist: isPlaying ? "Playing" : "Stopped",
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        infoCenter.playbackState = isPlaying ? .playing : .paused
    }

    @ObservationIgnored private var hydrated = false
}
