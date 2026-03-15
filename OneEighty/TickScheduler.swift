//
//  TickScheduler.swift
//  OneEighty
//
//  Schedules tick buffer playback using AVAudioTime for sample-accurate timing.
//

import AVFoundation
import os

private let logger = Logger(subsystem: "com.danielbutler.OneEighty", category: "TickScheduler")

/// Schedules tick buffer playback using AVAudioTime for sample-accurate timing.
/// The caller owns the AVAudioEngine and AVAudioPlayerNode; this class only
/// computes when to schedule and calls scheduleBuffer(at:).
/// Must be used from @MainActor — the maintenance Timer requires the main RunLoop.
@MainActor
final class TickScheduler {

    // MARK: - Configuration

    /// How far ahead (in seconds) to keep ticks scheduled.
    /// The maintenance timer tops up to this horizon.
    private let lookAheadSeconds: Double = 0.2

    // MARK: - State

    private let playerNode: AVAudioPlayerNode
    private let buffer: AVAudioPCMBuffer
    private let sampleRate: Double

    private var bpm: Int
    private var nextBeatSampleTime: AVAudioFramePosition = 0
    private var maintenanceTimer: Timer?

    // MARK: - Init

    init(playerNode: AVAudioPlayerNode, buffer: AVAudioPCMBuffer, sampleRate: Double, bpm: Int) {
        self.playerNode = playerNode
        self.buffer = buffer
        self.sampleRate = sampleRate
        self.bpm = bpm
    }

    // nonisolated deinit prevents Swift from scheduling deallocation on the
    // main actor via swift_task_deinitOnExecutorImpl, which avoids a
    // TaskLocal.StopLookupScope crash in unit tests. Properties are already
    // cleaned up by stop(); the deinit body is intentionally empty.
    nonisolated deinit {}

    // MARK: - Public

    /// Pure function: computes samples between beats for a given BPM and sample rate.
    nonisolated static func samplesPerBeat(bpm: Int, sampleRate: Double) -> AVAudioFramePosition {
        let interval = 60.0 / Double(bpm)
        return AVAudioFramePosition((interval * sampleRate).rounded())
    }

    /// Start scheduling ticks from now.
    func start() {
        guard let nodeTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime) else {
            logger.warning("Cannot get player time — scheduling from sample 0")
            nextBeatSampleTime = 0
            scheduleAhead()
            startMaintenanceTimer()
            return
        }

        // First tick: now (or the next render cycle)
        nextBeatSampleTime = playerTime.sampleTime
        scheduleAhead()
        startMaintenanceTimer()
    }

    /// Stop all scheduled ticks and the maintenance timer.
    func stop() {
        maintenanceTimer?.invalidate()
        maintenanceTimer = nil
        playerNode.stop()
    }

    /// Update BPM. Reschedules future ticks from the next beat boundary.
    func updateBPM(_ newBPM: Int) {
        guard newBPM != bpm else { return }
        bpm = newBPM
        // nextBeatSampleTime already points to the next unscheduled beat —
        // just schedule forward from there at the new tempo.
        // Any already-scheduled ticks at the old tempo will still play,
        // but they're within the look-ahead window (~200ms) so the
        // transition is nearly instant.
        scheduleAhead()
    }

    // MARK: - Internal scheduling

    private func scheduleAhead() {
        guard let nodeTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime) else {
            // Player not yet running — schedule one tick at nextBeatSampleTime
            let time = AVAudioTime(sampleTime: nextBeatSampleTime, atRate: sampleRate)
            playerNode.scheduleBuffer(buffer, at: time, options: [], completionHandler: nil)
            nextBeatSampleTime += Self.samplesPerBeat(bpm: bpm, sampleRate: sampleRate)
            return
        }

        let currentSample = playerTime.sampleTime
        let horizonSample = currentSample + AVAudioFramePosition(lookAheadSeconds * sampleRate)
        let interval = Self.samplesPerBeat(bpm: bpm, sampleRate: sampleRate)

        // If nextBeatSampleTime fell behind (e.g. after a pause), jump forward
        if nextBeatSampleTime < currentSample {
            nextBeatSampleTime = currentSample
        }

        while nextBeatSampleTime <= horizonSample {
            let time = AVAudioTime(sampleTime: nextBeatSampleTime, atRate: sampleRate)
            playerNode.scheduleBuffer(buffer, at: time, options: [], completionHandler: nil)
            nextBeatSampleTime += interval
        }
    }

    private func startMaintenanceTimer() {
        maintenanceTimer?.invalidate()
        // Fire at half the look-ahead interval to ensure we always stay topped up.
        let interval = lookAheadSeconds / 2.0
        maintenanceTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleAhead()
            }
        }
    }
}
