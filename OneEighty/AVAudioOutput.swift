//  AVAudioOutput.swift
import AVFoundation
import os

private let logger = Logger(subsystem: "com.danielbutler.OneEighty", category: "AudioOutput")

@MainActor
final class AVAudioOutput: AudioOutput {
    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var audioBuffer: AVAudioPCMBuffer?
    private var tickScheduler: TickScheduler?
    private var currentBPM: Int = 180
    private var volume: Float = 0.4

    var isRunning: Bool { tickScheduler != nil }

    init() { setupAudioEngine() }

    nonisolated deinit {}

    func setVolume(_ volume: Float) {
        self.volume = volume
        audioEngine?.mainMixerNode.outputVolume = volume
    }

    func start(bpm: Int) {
        currentBPM = bpm
        stopInternal()
        guard let playerNode, let audioBuffer, let audioEngine else { return }
        if !audioEngine.isRunning {
            do { try audioEngine.start() }
            catch { logger.error("Failed to restart audio engine: \(error.localizedDescription)"); return }
        }
        audioEngine.mainMixerNode.outputVolume = volume
        if !playerNode.isPlaying { playerNode.play() }
        let scheduler = TickScheduler(playerNode: playerNode, buffer: audioBuffer,
                                      sampleRate: audioBuffer.format.sampleRate, bpm: bpm)
        tickScheduler = scheduler
        scheduler.start()
    }

    func stop() { stopInternal() }

    func updateBPM(_ bpm: Int) {
        currentBPM = bpm
        tickScheduler?.updateBPM(bpm)
    }

    private func stopInternal() {
        tickScheduler?.stop()
        tickScheduler = nil
        if playerNode?.isPlaying == true { playerNode?.stop() }
    }

    private func setupAudioEngine() {
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
        do { try audioEngine.start() }
        catch { logger.error("Failed to start audio engine: \(error.localizedDescription)") }
    }

    private func loadTickSound() {
        guard let tickURL = Bundle.main.url(forResource: "tick-trimmed", withExtension: "wav") else {
            logger.error("Could not find tick-trimmed.wav in bundle"); return
        }
        do {
            let audioFile = try AVAudioFile(forReading: tickURL)
            let format = audioFile.processingFormat
            let frameCount = UInt32(audioFile.length)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
                logger.error("Could not create audio buffer"); return
            }
            try audioFile.read(into: buffer)
            audioBuffer = buffer
        } catch { logger.error("Failed to load tick sound: \(error)") }
    }
}
