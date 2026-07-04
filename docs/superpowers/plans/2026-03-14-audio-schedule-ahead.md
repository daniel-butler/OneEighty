# Audio Schedule-Ahead Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace CPU Timer-based tick scheduling with AVAudioTime schedule-ahead for sample-accurate metronome timing.

**Architecture:** Extract tick scheduling into a dedicated `@MainActor TickScheduler` class that uses `AVAudioPlayerNode.scheduleBuffer(at:)` with precise `AVAudioTime` sample offsets. A low-priority maintenance timer tops up the schedule-ahead window but is never in the critical timing path. BPM changes update the interval for future scheduling — any already-scheduled ticks within the ~200ms look-ahead window play at the old tempo, making the transition nearly instant without requiring cancellation or restart.

**Tech Stack:** AVFoundation (AVAudioEngine, AVAudioPlayerNode, AVAudioTime), XCTest

---

## File Structure

| File | Action | Responsibility |
|------|--------|---------------|
| `OneEighty/TickScheduler.swift` | **Create** | Owns schedule-ahead logic: maintains a rolling window of ticks scheduled via `AVAudioTime`, handles BPM changes by rescheduling from next beat boundary |
| `OneEighty/OneEightyEngine.swift` | **Modify** | Remove `tickTimer`-based scheduling, delegate to `TickScheduler` |
| `OneEightyTests/TickSchedulerTests.swift` | **Create** | Unit tests for schedule-ahead math (sample positions, BPM transitions) |
| `OneEightyTests/OneEightyEngineTests.swift` | **Modify** | Verify existing engine tests still pass unchanged |

---

## Chunk 1: TickScheduler — schedule-ahead core

### Task 1: Define TickScheduler interface and sample-position math

**Files:**
- Create: `OneEightyTests/TickSchedulerTests.swift`
- Create: `OneEighty/TickScheduler.swift`

- [ ] **Step 1: Write failing tests for sample-position calculation**

The core math: given a sample rate and BPM, compute the number of samples between ticks.

```swift
//  TickSchedulerTests.swift

import XCTest
@testable import OneEighty

final class TickSchedulerTests: XCTestCase {

    // MARK: - Sample interval math

    func testSamplesPerBeatAt180BPM() {
        // 60 / 180 = 0.3333s × 24000 Hz = 8000 samples
        let samples = TickScheduler.samplesPerBeat(bpm: 180, sampleRate: 24000)
        XCTAssertEqual(samples, 8000)
    }

    func testSamplesPerBeatAt150BPM() {
        // 60 / 150 = 0.4s × 24000 Hz = 9600 samples
        let samples = TickScheduler.samplesPerBeat(bpm: 150, sampleRate: 24000)
        XCTAssertEqual(samples, 9600)
    }

    func testSamplesPerBeatAt230BPM() {
        // 60 / 230 = 0.26087s × 24000 Hz = 6260.87 → 6261 samples (rounded)
        let samples = TickScheduler.samplesPerBeat(bpm: 230, sampleRate: 24000)
        XCTAssertEqual(samples, 6261)
    }

    func testSamplesPerBeatAt44100Hz() {
        // 60 / 180 = 0.3333s × 44100 Hz = 14700 samples
        let samples = TickScheduler.samplesPerBeat(bpm: 180, sampleRate: 44100)
        XCTAssertEqual(samples, 14700)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme OneEighty -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:OneEightyTests/TickSchedulerTests`
Expected: FAIL — `TickScheduler` does not exist yet.

- [ ] **Step 3: Implement TickScheduler with samplesPerBeat**

```swift
//  TickScheduler.swift

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

    // MARK: - Public

    /// Pure function: computes samples between beats for a given BPM and sample rate.
    static func samplesPerBeat(bpm: Int, sampleRate: Double) -> AVAudioFramePosition {
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
            self?.scheduleAhead()
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -scheme OneEighty -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:OneEightyTests/TickSchedulerTests`
Expected: PASS — all 4 tests green.

- [ ] **Step 5: Commit**

```bash
git add OneEighty/TickScheduler.swift OneEightyTests/TickSchedulerTests.swift
git commit -m "feat: add TickScheduler with sample-position math and schedule-ahead core"
```

---

### Task 2: Add TickScheduler tests for BPM transition math

**Files:**
- Modify: `OneEightyTests/TickSchedulerTests.swift`

- [ ] **Step 1: Write tests for BPM transition sample positions**

Add these tests inside the existing `TickSchedulerTests` class (before the closing `}`):

```swift
    // MARK: - Beat position sequences

    func testBeatPositionsAreEvenlySpaced() {
        let interval = TickScheduler.samplesPerBeat(bpm: 180, sampleRate: 24000)
        let positions = (0..<5).map { AVAudioFramePosition($0) * interval }
        XCTAssertEqual(positions, [0, 8000, 16000, 24000, 32000])
    }

    func testBPMChangeProducesNewInterval() {
        // Simulate: 3 beats at 180, then switch to 200
        let rate: Double = 24000
        let interval180 = TickScheduler.samplesPerBeat(bpm: 180, sampleRate: rate) // 8000
        let interval200 = TickScheduler.samplesPerBeat(bpm: 200, sampleRate: rate) // 7200

        // Beat 3 ends at sample 24000. Next beat at new tempo:
        let transitionPoint = AVAudioFramePosition(3) * interval180 // 24000
        let nextBeat = transitionPoint + interval200 // 31200

        XCTAssertEqual(interval180, 8000)
        XCTAssertEqual(interval200, 7200)
        XCTAssertEqual(nextBeat, 31200)
    }

    func testSamplesPerBeatNeverZero() {
        // Even at extreme BPMs, interval should be positive
        let samples = TickScheduler.samplesPerBeat(bpm: 300, sampleRate: 24000)
        XCTAssertGreaterThan(samples, 0)
    }
```

- [ ] **Step 2: Run tests to verify they pass**

Run: `xcodebuild test -scheme OneEighty -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:OneEightyTests/TickSchedulerTests`
Expected: PASS — all 7 tests green.

- [ ] **Step 3: Commit**

```bash
git add OneEightyTests/TickSchedulerTests.swift
git commit -m "test: add BPM transition and edge case tests for TickScheduler"
```

---

## Chunk 2: Wire TickScheduler into OneEightyEngine

### Task 3: Replace Timer-based scheduling with TickScheduler

**Files:**
- Modify: `OneEighty/OneEightyEngine.swift:39-44` (audio internals properties)
- Modify: `OneEighty/OneEightyEngine.swift:269-303` (`startOneEighty`)
- Modify: `OneEighty/OneEightyEngine.swift:305-309` (`stopOneEighty`)
- Modify: `OneEighty/OneEightyEngine.swift:311-325` (`handleBPMChange`)
- Modify: `OneEighty/OneEightyEngine.swift:256-261` (`cleanupAudio`)

- [ ] **Step 1: Run existing engine tests to confirm green baseline**

Run: `xcodebuild test -scheme OneEighty -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:OneEightyTests/OneEightyEngineTests`
Expected: PASS — all existing tests green.

- [ ] **Step 2: Replace tickTimer and bpmDebounceTimer with TickScheduler**

In `OneEightyEngine.swift`, make these changes:

**Replace the Audio Internals properties (lines 39-44):**

```swift
    // MARK: - Audio Internals

    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var audioBuffer: AVAudioPCMBuffer?
    private var tickScheduler: TickScheduler?
    private var wasPlayingBeforeInterruption: Bool = false
```

Remove `tickTimer`, `bpmDebounceTimer`, and `pendingBPM` — they are no longer needed.

**Replace `startOneEighty()` (lines 269-303):**

```swift
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
```

**Replace `stopOneEighty()` (lines 305-309):**

```swift
    private func stopOneEighty() {
        tickScheduler?.stop()
        tickScheduler = nil
        // Safety: ensure player node is stopped even if no scheduler was active
        if playerNode?.isPlaying == true {
            playerNode?.stop()
        }
    }
```

**Replace `handleBPMChange()` (lines 311-325):**

```swift
    private func handleBPMChange() {
        guard isPlaying else { return }
        tickScheduler?.updateBPM(bpm)
    }
```

**Update `cleanupAudio()` (lines 256-261):**

```swift
    private func cleanupAudio() {
        stopOneEighty()
        playerNode = nil
        audioEngine = nil
        audioBuffer = nil
    }
```

**Remove** `calculateInterval(bpm:)` (lines 265-267) — no longer used.

- [ ] **Step 3: Run all engine tests to confirm nothing broke**

Run: `xcodebuild test -scheme OneEighty -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:OneEightyTests/OneEightyEngineTests`
Expected: PASS — all existing tests still green. The tests use `InMemoryStateStore` and don't depend on audio hardware, so the scheduling change is transparent to them.

- [ ] **Step 4: Run full test suite**

Run: `xcodebuild test -scheme OneEighty -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`
Expected: PASS — no regressions.

- [ ] **Step 5: Commit**

```bash
git add OneEighty/OneEightyEngine.swift
git commit -m "feat: replace CPU Timer scheduling with AVAudioTime schedule-ahead

Ticks are now scheduled on the audio thread's timeline via
TickScheduler, eliminating jitter from main thread contention.
BPM changes take effect within ~200ms (one look-ahead window)
without restarting the audio engine."
```

---

### Task 4: Verify build and full test suite

The Xcode project uses `fileSystemSynchronizedGroups`, so new files in `OneEighty/` and `OneEightyTests/` are automatically discovered — no manual project file changes needed.

- [ ] **Step 1: Build to confirm compilation**

Run: `xcodebuild build -scheme OneEighty -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath ./build`
Expected: BUILD SUCCEEDED

- [ ] **Step 2: Run full test suite one final time**

Run: `xcodebuild test -scheme OneEighty -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`
Expected: PASS

---

## Summary of Changes

| What changed | Why |
|---|---|
| **Removed** `Timer.scheduledTimer` for tick scheduling | CPU timers on the main RunLoop are non-deterministic and cause audible skips during app transitions |
| **Removed** `bpmDebounceTimer` / `pendingBPM` | No longer needed — BPM changes are applied instantly via `TickScheduler.updateBPM()` within the look-ahead window |
| **Removed** `calculateInterval(bpm:)` | Replaced by `TickScheduler.samplesPerBeat(bpm:sampleRate:)` |
| **Added** `TickScheduler` | Schedules ticks via `AVAudioTime` sample positions on the audio thread — sample-accurate, immune to main thread load |
| **Maintenance timer** fires every 100ms | Only does bookkeeping (top up the schedule window). If it fires 50ms late, ticks are unaffected because they were already scheduled on the audio clock |

## Key Design Decisions

1. **200ms look-ahead window**: Small enough that BPM changes feel instant (max 200ms of "stale" ticks), large enough that the maintenance timer has ample margin even under heavy CPU load.

2. **No debounce on BPM changes**: `updateBPM()` is now cheap — it just changes the interval for future `scheduleAhead()` calls. The 300ms debounce was only needed because the old approach stopped and restarted the entire playback. Digital Crown changes now apply without any gap.

3. **Single AVAudioPlayerNode**: `scheduleBuffer(at:)` queues multiple buffers on the same node. Each tick plays at its precise sample time. No need for multiple player nodes.

4. **Rounding for fractional samples**: `samplesPerBeat` rounds to nearest integer. At 230 BPM / 24kHz, this introduces ~0.014ms error per beat. Over a long session (e.g., 10 min at 230 BPM = ~2300 beats), cumulative drift is ~300 samples / ~12.5ms — imperceptible. The drift only resets on pause/resume (when `nextBeatSampleTime` falls behind `currentSample` and is snapped forward). For continuous playback this is acceptable; if sub-ms precision over very long sessions is ever needed, `scheduleAhead()` could periodically reanchor `nextBeatSampleTime` to the true audio clock.
