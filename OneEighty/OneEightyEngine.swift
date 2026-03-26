//
//  OneEightyEngine.swift
//  OneEighty
//
//  Owns all metronome state and audio playback.
//  ContentView and WatchSessionManager are thin clients of this engine.
//

import AVFoundation
import Combine
import MediaPlayer
import UIKit
import os

private let logger = Logger(subsystem: "com.danielbutler.OneEighty", category: "OneEightyEngine")

struct PlaybackState: Equatable {
    let bpm: Int
    let isPlaying: Bool
}

@Observable
@MainActor
final class OneEightyEngine {
    // MARK: - Observable State

    private(set) var bpm: Int = 180
    private(set) var isPlaying: Bool = false
    var volume: Float = 0.4

    // MARK: - BPM Constraints

    static let bpmRange = 150...230

    var canIncrementBPM: Bool { bpm < Self.bpmRange.upperBound }
    var canDecrementBPM: Bool { bpm > Self.bpmRange.lowerBound }

    // MARK: - Audio Internals

    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var audioBuffer: AVAudioPCMBuffer?
    private var tickScheduler: TickScheduler?
    private var wasPlayingBeforeInterruption: Bool = false
    private var isSessionInterrupted: Bool = false

    // MARK: - Cross-Process

    @ObservationIgnored private let store: StateStore

    init(store: StateStore = SharedStateStore.shared) {
        self.store = store
    }

    // MARK: - Combine Publisher

    private let stateSubject = CurrentValueSubject<PlaybackState, Never>(PlaybackState(bpm: 180, isPlaying: false))

    /// Publishes PlaybackState whenever bpm or isPlaying changes. Late subscribers receive the current value immediately.
    var statePublisher: AnyPublisher<PlaybackState, Never> {
        stateSubject.eraseToAnyPublisher()
    }

    private var subscriptions = Set<AnyCancellable>()

    private func notifyStateChanged() {
        stateSubject.send(PlaybackState(bpm: bpm, isPlaying: isPlaying))
    }

    private func setupSubscriptions() {
        subscriptions.removeAll()
        statePublisher
            .removeDuplicates()
            .sink { state in
                LiveActivityManager.shared.updateActivity(bpm: state.bpm, isPlaying: state.isPlaying)
            }
            .store(in: &subscriptions)
        statePublisher
            .sink { [weak self] _ in
                self?.updateNowPlaying()
            }
            .store(in: &subscriptions)
        LiveActivityManager.shared.setStateProvider { [weak self] in
            guard let self else { return PlaybackState(bpm: 180, isPlaying: false) }
            return PlaybackState(bpm: self.bpm, isPlaying: self.isPlaying)
        }
    }

    // MARK: - Setup / Teardown

    private var isSetUp: Bool = false

    func setup() {
        logger.info("setup — initializing audio engine and state observer")

        // Restore BPM from shared state (survives app restarts)
        store.synchronize()
        let restoredBPM = store.bpm
        bpm = min(Self.bpmRange.upperBound, max(Self.bpmRange.lowerBound, restoredBPM))
        volume = 0.4
        isPlaying = false

        // Sync shared preferences (keep bpm, reset playback)
        store.bpm = bpm
        store.volume = 0.4
        store.isPlaying = false

        LiveActivityManager.shared.cleanupStaleActivities()
        setupAudioEngine()
        setupRemoteCommands()
        startObservingInterruptions()
        // Update stateSubject BEFORE subscriptions so the LiveActivityManager
        // subscriber gets the correct restored BPM, not the hardcoded default (180).
        notifyStateChanged()
        setupSubscriptions()
        startObservingSharedState()
        isSetUp = true
    }

    /// Lightweight setup for background wake — initializes audio without resetting state.
    /// Safe to call multiple times; no-ops if already set up.
    func ensureReady() {
        guard !isSetUp else { return }
        logger.info("ensureReady — background setup (preserving state)")
        store.synchronize()
        LiveActivityManager.shared.cleanupStaleActivities()
        setupAudioEngine()
        setupRemoteCommands()
        startObservingInterruptions()
        notifyStateChanged()
        setupSubscriptions()
        startObservingSharedState()
        isSetUp = true
    }

    func teardown() {
        logger.info("teardown — cleaning up audio and observer")
        subscriptions.removeAll()
        stopObservingInterruptions()
        stopObservingSharedState()
        cleanupAudio()
        isSetUp = false
    }

    nonisolated deinit {
        // nonisolated deinit prevents Swift from scheduling deallocation on the
        // main actor via swift_task_deinitOnExecutorImpl, which avoids a
        // TaskLocal.StopLookupScope crash in unit tests. Properties are already
        // cleaned up by teardown(); the deinit body is intentionally empty.
    }

    // MARK: - Public Controls

    func togglePlayback() {
        logger.info("togglePlayback — currently isPlaying=\(self.isPlaying)")
        if isPlaying {
            isPlaying = false
            wasPlayingBeforeInterruption = false
            stopOneEighty()
        } else {
            isPlaying = true
            startOneEighty()
        }
        store.isPlaying = isPlaying
        notifyStateChanged()
        logger.info("togglePlayback — now isPlaying=\(self.isPlaying)")
    }

    func incrementBPM() {
        guard canIncrementBPM else { return }
        bpm += 1
        store.bpm = bpm
        handleBPMChange()
        notifyStateChanged()
    }

    func decrementBPM() {
        guard canDecrementBPM else { return }
        bpm -= 1
        store.bpm = bpm
        handleBPMChange()
        notifyStateChanged()
    }

    func adjustBPM(by delta: Int) {
        let newBPM = min(Self.bpmRange.upperBound, max(Self.bpmRange.lowerBound, bpm + delta))
        guard newBPM != bpm else { return }
        bpm = newBPM
        store.bpm = bpm
        handleBPMChange()
        notifyStateChanged()
    }

    func setBPM(_ newBPM: Int) {
        let clamped = min(Self.bpmRange.upperBound, max(Self.bpmRange.lowerBound, newBPM))
        guard clamped != bpm else { return }
        bpm = clamped
        store.bpm = clamped
        if isPlaying {
            handleBPMChange()
        }
        notifyStateChanged()
    }

    func setVolume(_ newVolume: Float) {
        let clamped = max(0.0, min(1.0, newVolume))
        volume = clamped
        audioEngine?.mainMixerNode.outputVolume = clamped
        store.volume = clamped
        store.notifyWidgetUpdate()
    }


    // MARK: - Audio Engine Setup

    private func setupAudioEngine() {
        // Audio session is managed by AudioSessionManager.shared (with .mixWithOthers).
        // Do NOT reconfigure it here — that would strip .mixWithOthers and kill other audio.
        AudioSessionManager.shared.activate()

        audioEngine = AVAudioEngine()
        playerNode = AVAudioPlayerNode()

        guard let audioEngine, let playerNode else { return }

        audioEngine.attach(playerNode)
        loadTickSound()

        if let audioBuffer {
            audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: audioBuffer.format)
        } else {
            audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: nil)
        }

        do {
            try audioEngine.start()
        } catch {
            logger.error("Failed to start audio engine: \(error.localizedDescription)")
        }
    }

    private func loadTickSound() {
        guard let tickURL = Bundle.main.url(forResource: "tick-trimmed", withExtension: "wav") else {
            logger.error("Could not find tick-trimmed.wav in bundle")
            return
        }

        do {
            let audioFile = try AVAudioFile(forReading: tickURL)
            let format = audioFile.processingFormat
            let frameCount = UInt32(audioFile.length)

            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
                logger.error("Could not create audio buffer")
                return
            }

            try audioFile.read(into: buffer)
            self.audioBuffer = buffer
        } catch {
            logger.error("Failed to load tick sound: \(error)")
        }
    }

    private func cleanupAudio() {
        stopOneEighty()
        playerNode = nil
        audioEngine = nil
        audioBuffer = nil
    }

    // MARK: - OneEighty Control

    private func startOneEighty() {
        stopOneEighty()

        guard let playerNode, let audioBuffer, let audioEngine else { return }

        // Restart audio engine if it was stopped (e.g. after interruption)
        if !audioEngine.isRunning {
            logger.info("Audio engine not running — restarting")
            do {
                try audioEngine.start()
            } catch {
                logger.error("Failed to restart audio engine: \(error.localizedDescription)")
                return
            }
        }

        audioEngine.mainMixerNode.outputVolume = volume

        if !playerNode.isPlaying {
            playerNode.play()
        }

        let sampleRate = audioBuffer.format.sampleRate
        let scheduler = TickScheduler(
            playerNode: playerNode,
            buffer: audioBuffer,
            sampleRate: sampleRate,
            bpm: bpm
        )
        self.tickScheduler = scheduler
        scheduler.start()
    }

    private func stopOneEighty() {
        tickScheduler?.stop()
        tickScheduler = nil
        // Safety: ensure player node is stopped even if no scheduler was active
        if playerNode?.isPlaying == true {
            playerNode?.stop()
        }
    }

    private func handleBPMChange() {
        guard isPlaying else { return }
        tickScheduler?.updateBPM(bpm)
    }

    // MARK: - Shared State Observer

    private func startObservingSharedState() {
        store.externalChanges
            .sink { [weak self] event in
                guard let self else { return }
                switch event {
                case .stateChanged:
                    self.handleSharedStateChange()
                case .command(.start):
                    self.handlePlayCommand()
                case .command(.stop):
                    self.handleStopCommand()
                case .command(.adjustBPM(let delta)):
                    self.adjustBPM(by: delta)
                }
            }
            .store(in: &subscriptions)
    }

    private func stopObservingSharedState() {
        // Subscriptions cancelled via subscriptions.removeAll() in teardown()
    }

    @MainActor
    private func handleSharedStateChange() {
        let newBPM = store.bpm
        logger.info("handleSharedStateChange — shared bpm=\(newBPM), local bpm=\(self.bpm)")

        if newBPM != bpm {
            logger.info("handleSharedStateChange — BPM changed \(self.bpm) → \(newBPM)")
            bpm = newBPM
            if isPlaying {
                handleBPMChange()
            }
            notifyStateChanged()
        }
    }

    @MainActor
    private func handlePlayCommand() {
        logger.info("handlePlayCommand — currently isPlaying=\(self.isPlaying)")
        guard !isPlaying else { return }
        isPlaying = true
        store.isPlaying = true
        startOneEighty()
        notifyStateChanged()
    }

    @MainActor
    private func handleStopCommand() {
        logger.info("handleStopCommand — currently isPlaying=\(self.isPlaying)")
        // Clear auto-resume intent — user explicitly wants to stop,
        // even if we're in the middle of an interruption.
        wasPlayingBeforeInterruption = false
        guard isPlaying else { return }
        isPlaying = false
        store.isPlaying = false
        stopOneEighty()
        notifyStateChanged()
    }

    // MARK: - Audio Interruption Handling

    private func startObservingInterruptions() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruptionBegan),
            name: .audioInterruptionBegan,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruptionEnded),
            name: .audioInterruptionEnded,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    private func stopObservingInterruptions() {
        NotificationCenter.default.removeObserver(self, name: .audioInterruptionBegan, object: nil)
        NotificationCenter.default.removeObserver(self, name: .audioInterruptionEnded, object: nil)
        NotificationCenter.default.removeObserver(self, name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    @objc private func handleInterruptionBegan() {
        Task { @MainActor in
            logger.info("Audio interrupted — wasPlaying=\(self.isPlaying), alreadyInterrupted=\(self.isSessionInterrupted)")
            // Only capture wasPlaying on the first began — a duplicate began
            // would see isPlaying=false and overwrite to false, losing the resume intent.
            if !self.isSessionInterrupted {
                self.wasPlayingBeforeInterruption = self.isPlaying
            }
            self.isSessionInterrupted = true
            guard self.isPlaying else { return }
            self.isPlaying = false
            self.store.isPlaying = false
            self.stopOneEighty()
            self.notifyStateChanged()
        }
    }

    @objc private func handleInterruptionEnded() {
        Task { @MainActor in
            logger.info("Audio interruption ended — wasPlayingBefore=\(self.wasPlayingBeforeInterruption), isPlaying=\(self.isPlaying)")
            self.isSessionInterrupted = false
            guard self.wasPlayingBeforeInterruption, !self.isPlaying else {
                self.wasPlayingBeforeInterruption = false
                return
            }
            self.wasPlayingBeforeInterruption = false
            AudioSessionManager.shared.activate()
            self.isPlaying = true
            self.store.isPlaying = true
            self.startOneEighty()
            self.notifyStateChanged()
        }
    }

    /// Foreground recovery — Apple docs: "There is no guarantee that a begin
    /// interruption will have a corresponding end interruption."
    @objc private func handleDidBecomeActive() {
        Task { @MainActor in
            guard self.wasPlayingBeforeInterruption, !self.isPlaying else { return }
            logger.info("didBecomeActive — recovering from interruption")
            self.wasPlayingBeforeInterruption = false
            self.isSessionInterrupted = false
            AudioSessionManager.shared.activate()
            self.isPlaying = true
            self.store.isPlaying = true
            self.startOneEighty()
            self.notifyStateChanged()
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
}
