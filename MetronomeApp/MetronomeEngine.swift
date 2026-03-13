//
//  MetronomeEngine.swift
//  MetronomeApp
//
//  Owns all metronome state and audio playback.
//  ContentView and WatchSessionManager are thin clients of this engine.
//

import AVFoundation
import os

private let logger = Logger(subsystem: "com.danielbutler.MetronomeApp", category: "MetronomeEngine")

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

    /// Called whenever bpm or isPlaying changes. PhoneSessionManager uses this to push state to the watch.
    var onStateChange: (() -> Void)?

    // MARK: - Setup / Teardown

    private var isSetUp: Bool = false

    func setup() {
        logger.info("setup — initializing audio engine and state observer")

        // Always start fresh
        bpm = 180
        volume = 0.4
        isPlaying = false

        // Reset shared preferences
        sharedState.bpm = 180
        sharedState.volume = 0.4
        sharedState.isPlaying = false

        setupAudioEngine()
        startObservingSharedState()
        startObservingInterruptions()
        isSetUp = true
    }

    /// Lightweight setup for background wake — initializes audio without resetting state.
    /// Safe to call multiple times; no-ops if already set up.
    func ensureReady() {
        guard !isSetUp else { return }
        logger.info("ensureReady — background setup (preserving state)")
        setupAudioEngine()
        startObservingSharedState()
        startObservingInterruptions()
        isSetUp = true
    }

    func teardown() {
        logger.info("teardown — cleaning up audio and observer")
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
        LiveActivityManager.shared.updateActivity(bpm: bpm, isPlaying: isPlaying)
        onStateChange?()
        logger.info("togglePlayback — now isPlaying=\(self.isPlaying)")
    }

    func incrementBPM() {
        guard canIncrementBPM else { return }
        bpm += 1
        sharedState.bpm = bpm
        handleBPMChange()
        LiveActivityManager.shared.updateActivity(bpm: bpm, isPlaying: isPlaying)
        onStateChange?()
    }

    func decrementBPM() {
        guard canDecrementBPM else { return }
        bpm -= 1
        sharedState.bpm = bpm
        handleBPMChange()
        LiveActivityManager.shared.updateActivity(bpm: bpm, isPlaying: isPlaying)
        onStateChange?()
    }

    func setBPM(_ newBPM: Int) {
        let clamped = min(Self.bpmRange.upperBound, max(Self.bpmRange.lowerBound, newBPM))
        guard clamped != bpm else { return }
        bpm = clamped
        sharedState.bpm = clamped
        if isPlaying {
            handleBPMChange()
        }
        LiveActivityManager.shared.updateActivity(bpm: bpm, isPlaying: isPlaying)
        onStateChange?()
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
            LiveActivityManager.shared.updateActivity(bpm: bpm, isPlaying: isPlaying)
        }
    }

    @MainActor
    private func handlePlayCommand() {
        logger.info("handlePlayCommand — currently isPlaying=\(self.isPlaying)")
        guard !isPlaying else { return }
        isPlaying = true
        sharedState.isPlaying = true
        startMetronome()
        LiveActivityManager.shared.updateActivity(bpm: bpm, isPlaying: true)
    }

    @MainActor
    private func handleStopCommand() {
        logger.info("handleStopCommand — currently isPlaying=\(self.isPlaying)")
        guard isPlaying else { return }
        isPlaying = false
        sharedState.isPlaying = false
        stopMetronome()
        LiveActivityManager.shared.updateActivity(bpm: bpm, isPlaying: false)
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
            LiveActivityManager.shared.updateActivity(bpm: self.bpm, isPlaying: false)
            self.onStateChange?()
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
            LiveActivityManager.shared.updateActivity(bpm: self.bpm, isPlaying: true)
            self.onStateChange?()
        }
    }
}
