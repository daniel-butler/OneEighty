//
//  MetronomeEngine.swift
//  MetronomeApp
//
//  Owns all metronome state and audio playback.
//  ContentView and WatchSessionManager are thin clients of this engine.
//

import AVFoundation
import Combine
import MediaPlayer
import os

private let logger = Logger(subsystem: "com.danielbutler.MetronomeApp", category: "MetronomeEngine")

struct MetronomeState: Equatable {
    let bpm: Int
    let isPlaying: Bool
}

@Observable
@MainActor
final class MetronomeEngine {
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
    private var tickTimer: Timer?
    private var bpmDebounceTimer: Timer?
    private var pendingBPM: Int?
    private var wasPlayingBeforeInterruption: Bool = false

    // MARK: - Cross-Process

    private let sharedState = SharedMetronomeState.shared
    private var stateObserver: StateChangeObserver?

    // MARK: - Combine Publisher

    private let stateSubject = CurrentValueSubject<MetronomeState, Never>(MetronomeState(bpm: 180, isPlaying: false))

    /// Publishes MetronomeState whenever bpm or isPlaying changes. Late subscribers receive the current value immediately.
    var statePublisher: AnyPublisher<MetronomeState, Never> {
        stateSubject.eraseToAnyPublisher()
    }

    private var subscriptions = Set<AnyCancellable>()

    private func notifyStateChanged() {
        stateSubject.send(MetronomeState(bpm: bpm, isPlaying: isPlaying))
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
    }

    // MARK: - Setup / Teardown

    private var isSetUp: Bool = false

    func setup() {
        logger.info("setup — initializing audio engine and state observer")

        // Restore BPM from shared state (survives app restarts)
        sharedState.synchronize()
        let restoredBPM = sharedState.bpm
        bpm = min(Self.bpmRange.upperBound, max(Self.bpmRange.lowerBound, restoredBPM))
        volume = 0.4
        isPlaying = false

        // Sync shared preferences (keep bpm, reset playback)
        sharedState.bpm = bpm
        sharedState.volume = 0.4
        sharedState.isPlaying = false

        setupAudioEngine()
        setupRemoteCommands()
        startObservingSharedState()
        startObservingInterruptions()
        setupSubscriptions()
        notifyStateChanged()
        isSetUp = true
    }

    /// Lightweight setup for background wake — initializes audio without resetting state.
    /// Safe to call multiple times; no-ops if already set up.
    func ensureReady() {
        guard !isSetUp else { return }
        logger.info("ensureReady — background setup (preserving state)")
        setupAudioEngine()
        setupRemoteCommands()
        startObservingSharedState()
        startObservingInterruptions()
        setupSubscriptions()
        notifyStateChanged()
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

    // MARK: - Public Controls

    func togglePlayback() {
        logger.info("togglePlayback — currently isPlaying=\(self.isPlaying)")
        if isPlaying {
            isPlaying = false
            stopMetronome()
        } else {
            isPlaying = true
            startMetronome()
        }
        sharedState.isPlaying = isPlaying
        notifyStateChanged()
        logger.info("togglePlayback — now isPlaying=\(self.isPlaying)")
    }

    func incrementBPM() {
        guard canIncrementBPM else { return }
        bpm += 1
        sharedState.bpm = bpm
        handleBPMChange()
        notifyStateChanged()
    }

    func decrementBPM() {
        guard canDecrementBPM else { return }
        bpm -= 1
        sharedState.bpm = bpm
        handleBPMChange()
        notifyStateChanged()
    }

    func setBPM(_ newBPM: Int) {
        let clamped = min(Self.bpmRange.upperBound, max(Self.bpmRange.lowerBound, newBPM))
        guard clamped != bpm else { return }
        bpm = clamped
        sharedState.bpm = clamped
        if isPlaying {
            handleBPMChange()
        }
        notifyStateChanged()
    }

    func setVolume(_ newVolume: Float) {
        let clamped = max(0.0, min(1.0, newVolume))
        volume = clamped
        audioEngine?.mainMixerNode.outputVolume = clamped
        sharedState.volume = clamped
        sharedState.notifyWidgetUpdate()
    }

    func syncFromSharedState() {
        sharedState.synchronize()
        let newBPM = sharedState.bpm
        logger.info("syncFromSharedState — shared bpm=\(newBPM), local bpm=\(self.bpm)")

        if newBPM != bpm {
            logger.info("BPM mismatch — syncing \(self.bpm) → \(newBPM)")
            bpm = newBPM
            if isPlaying {
                handleBPMChange()
            }
            notifyStateChanged()
        }
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
        stopMetronome()
        playerNode = nil
        audioEngine = nil
        audioBuffer = nil
    }

    // MARK: - Metronome Control

    private func calculateInterval(bpm: Int) -> TimeInterval {
        return 60.0 / Double(bpm)
    }

    private func startMetronome() {
        stopMetronome()

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

        let interval = calculateInterval(bpm: bpm)

        playerNode.scheduleBuffer(audioBuffer)
        if !playerNode.isPlaying {
            playerNode.play()
        }

        let capturedPlayerNode = playerNode
        let capturedAudioBuffer = audioBuffer

        tickTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            capturedPlayerNode.scheduleBuffer(capturedAudioBuffer)
            if !capturedPlayerNode.isPlaying {
                capturedPlayerNode.play()
            }
        }
    }

    private func stopMetronome() {
        tickTimer?.invalidate()
        tickTimer = nil
        playerNode?.stop()
    }

    private func handleBPMChange() {
        guard isPlaying else { return }

        stopMetronome()
        bpmDebounceTimer?.invalidate()
        pendingBPM = bpm

        bpmDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.pendingBPM != nil else { return }
                self.startMetronome()
                self.pendingBPM = nil
            }
        }
    }

    // MARK: - Shared State Observer

    private func startObservingSharedState() {
        stateObserver = StateChangeObserver()
        stateObserver?.startObserving(
            onStateChanged: { [weak self] in self?.handleSharedStateChange() },
            onPlayCommand: { [weak self] in self?.handlePlayCommand() },
            onStopCommand: { [weak self] in self?.handleStopCommand() }
        )
    }

    private func stopObservingSharedState() {
        stateObserver?.stopObserving()
        stateObserver = nil
    }

    @MainActor
    private func handleSharedStateChange() {
        sharedState.synchronize()
        let newBPM = sharedState.bpm
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
        sharedState.isPlaying = true
        startMetronome()
        notifyStateChanged()
    }

    @MainActor
    private func handleStopCommand() {
        logger.info("handleStopCommand — currently isPlaying=\(self.isPlaying)")
        guard isPlaying else { return }
        isPlaying = false
        sharedState.isPlaying = false
        stopMetronome()
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
    }

    private func stopObservingInterruptions() {
        NotificationCenter.default.removeObserver(self, name: .audioInterruptionBegan, object: nil)
        NotificationCenter.default.removeObserver(self, name: .audioInterruptionEnded, object: nil)
    }

    @objc private func handleInterruptionBegan() {
        Task { @MainActor in
            logger.info("Audio interrupted — wasPlaying=\(self.isPlaying)")
            self.wasPlayingBeforeInterruption = self.isPlaying
            guard self.isPlaying else { return }
            self.isPlaying = false
            self.sharedState.isPlaying = false
            self.stopMetronome()
            self.notifyStateChanged()
        }
    }

    @objc private func handleInterruptionEnded() {
        Task { @MainActor in
            logger.info("Audio interruption ended — wasPlayingBefore=\(self.wasPlayingBeforeInterruption)")
            guard self.wasPlayingBeforeInterruption else { return }
            self.wasPlayingBeforeInterruption = false
            AudioSessionManager.shared.activate()
            self.isPlaying = true
            self.sharedState.isPlaying = true
            self.startMetronome()
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
