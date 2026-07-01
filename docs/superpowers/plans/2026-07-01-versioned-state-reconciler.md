# Versioned State + Reconciler Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the app's five scattered copies of playback state with one versioned `AppState` source of truth, an idempotent audio reconciler, and version/command-gated projections — retiring the drift, reorder, double-apply, and budget bug classes.

**Architecture:** A single `AppState { version, bpm, isPlaying }` is persisted in the app group behind an off-main `NSFileCoordinator` read-modify-write that keeps `version` monotonic. A dataless Darwin notification wakes every process to re-read. The engine becomes a reconciler that drives audio to match desired state. Store-reader surfaces (Live Activity, Now Playing, widget) reject snapshots with `version <= lastApplied`; the watch (not a store reader) uses relative commands with a client command-id and in-flight tracking. Play/stop/toggle intents conform to `AudioPlaybackIntent` so widget playback starts audio from a suspended app.

**Tech Stack:** Swift, SwiftUI, AVFoundation, WatchConnectivity, ActivityKit, AppIntents, `NSFileCoordinator`, Combine, XCTest.

**Design spec:** `docs/superpowers/specs/2026-07-01-versioned-state-reconciler-design.md`

## Global Constraints

- BPM range is `150...230` (`AppState.bpmRange`). Clamp on every mutation.
- App group identifier: `group.com.danielbutler.OneEighty`.
- Bundle id: `com.danielbutler.OneEighty`. Logger subsystem: `com.danielbutler.OneEighty`.
- Defaults: `bpm 180`, `isPlaying false`, `volume 0.4`.
- Volume is app-local (its own uncoordinated key) — NEVER in `AppState`, never bumps `version`, never posts Darwin.
- All state types and managers are `@MainActor` except the file IO path, which runs off-main and hops back.
- Build: `xcodebuild build -scheme OneEighty -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath ./build`
- Test: `xcodebuild test -scheme OneEighty -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`
- Single-file test: append `-only-testing:OneEightyTests/<TestClass>` to the test command.
- Project uses `fileSystemSynchronizedGroups`: new files under `OneEighty/`, `OneEightyTests/`, `OneEightyWidget/`, and the watch app are auto-discovered. No `.pbxproj` edits needed.
- Work happens on branch `refactor/versioned-state-reconciler`.
- Commit after every green step.

---

## Stage 1 — Store foundation

New files only; existing code is untouched and keeps compiling. The old
`SharedStateStore`/`StateStoreCommand`/`StoreEvent` remain until Stage 2 swaps
consumers over.

### Task 1: AppState model

**Files:**
- Create: `OneEighty/AppState.swift`
- Test: `OneEightyTests/AppStateTests.swift`

**Interfaces:**
- Produces: `struct AppState: Codable, Equatable { var version: UInt64; var bpm: Int; var isPlaying: Bool }`, `static let bpmRange = 150...230`, `static let defaultState: AppState`, `mutating func clampInvariants()`.

- [ ] **Step 1: Write the failing test**

```swift
//  AppStateTests.swift
import XCTest
@testable import OneEighty

final class AppStateTests: XCTestCase {
    func testDefaultState() {
        XCTAssertEqual(AppState.defaultState, AppState(version: 0, bpm: 180, isPlaying: false))
    }

    func testClampPinsBPMToRange() {
        var high = AppState(version: 1, bpm: 999, isPlaying: false)
        high.clampInvariants()
        XCTAssertEqual(high.bpm, 230)

        var low = AppState(version: 1, bpm: 10, isPlaying: true)
        low.clampInvariants()
        XCTAssertEqual(low.bpm, 150)
    }

    func testCodableRoundTrip() throws {
        let original = AppState(version: 7, bpm: 200, isPlaying: true)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AppState.self, from: data)
        XCTAssertEqual(decoded, original)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme OneEighty -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:OneEightyTests/AppStateTests`
Expected: FAIL — `AppState` does not exist.

- [ ] **Step 3: Write minimal implementation**

```swift
//  AppState.swift
import Foundation

/// The single versioned source of truth for shared playback state.
/// Volume is intentionally excluded — it is app-local audio config.
struct AppState: Codable, Equatable {
    var version: UInt64
    var bpm: Int
    var isPlaying: Bool

    static let bpmRange = 150...230
    static let defaultState = AppState(version: 0, bpm: 180, isPlaying: false)

    /// Pins fields to their legal ranges. Call after every mutation.
    mutating func clampInvariants() {
        bpm = min(Self.bpmRange.upperBound, max(Self.bpmRange.lowerBound, bpm))
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme OneEighty -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:OneEightyTests/AppStateTests`
Expected: PASS — 3 tests green.

- [ ] **Step 5: Commit**

```bash
git add OneEighty/AppState.swift OneEightyTests/AppStateTests.swift
git commit -m "feat: add versioned AppState model with clamping"
```

---

### Task 2: New StateStore protocol + in-memory test double

Replaces the old command/event protocol. The old `SharedStateStore` will not
compile against the new protocol yet — that's fine: it conforms to the OLD
protocol which we leave in place. To keep the repo compiling, this task defines
the NEW protocol under a distinct name `PlaybackStore`, used only by new code.
Stage 2 renames consumers and deletes the old `StateStore`. (Rename now would
break every existing consumer in one uncommittable step.)

**Files:**
- Create: `OneEighty/PlaybackStore.swift`
- Create: `OneEightyTests/InMemoryPlaybackStore.swift`
- Test: `OneEightyTests/InMemoryPlaybackStoreTests.swift`

**Interfaces:**
- Consumes: `AppState` (Task 1).
- Produces:
  - `protocol PlaybackStore: AnyObject` with `var state: AppState { get }`, `var statePublisher: AnyPublisher<AppState, Never> { get }`, `func mutate(_ transform: @escaping (inout AppState) -> Void)`, `var volume: Float { get set }`.
  - `final class InMemoryPlaybackStore: PlaybackStore` with initializer `init(_ initial: AppState = .defaultState)`.

- [ ] **Step 1: Write the failing test**

```swift
//  InMemoryPlaybackStoreTests.swift
import XCTest
import Combine
@testable import OneEighty

@MainActor
final class InMemoryPlaybackStoreTests: XCTestCase {
    func testMutateBumpsVersionAndClamps() {
        let store = InMemoryPlaybackStore()
        store.mutate { $0.bpm = 999 }
        XCTAssertEqual(store.state.version, 1)
        XCTAssertEqual(store.state.bpm, 230)
    }

    func testStatePublisherEmitsCurrentThenChanges() {
        let store = InMemoryPlaybackStore()
        var seen: [Int] = []
        var bag = Set<AnyCancellable>()
        store.statePublisher.sink { seen.append($0.bpm) }.store(in: &bag)
        store.mutate { $0.bpm = 190 }
        XCTAssertEqual(seen, [180, 190])   // current value, then the change
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme OneEighty -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:OneEightyTests/InMemoryPlaybackStoreTests`
Expected: FAIL — `PlaybackStore`/`InMemoryPlaybackStore` do not exist.

- [ ] **Step 3: Write the protocol**

```swift
//  PlaybackStore.swift
import Combine

/// One versioned source of truth for shared playback state, shared across the
/// app and the widget extension. Writers mutate absolute values; `version` is
/// bumped on every mutation so readers can reject stale snapshots.
@MainActor
protocol PlaybackStore: AnyObject {
    /// In-memory projection of the latest known state. Synchronous, main-actor.
    var state: AppState { get }

    /// Emits the current value immediately, then on every change (local or external).
    var statePublisher: AnyPublisher<AppState, Never> { get }

    /// Apply an absolute change. Bumps `version`, clamps invariants, persists,
    /// and signals other processes. Safe to call from the main actor.
    func mutate(_ transform: @escaping (inout AppState) -> Void)

    /// App-local audio config. Not versioned, not signalled cross-process.
    var volume: Float { get set }
}
```

- [ ] **Step 4: Write the in-memory test double**

```swift
//  InMemoryPlaybackStore.swift
import Combine
@testable import OneEighty

/// In-memory PlaybackStore for tests. No files, no Darwin, no cross-process IO.
@MainActor
final class InMemoryPlaybackStore: PlaybackStore {
    private let subject: CurrentValueSubject<AppState, Never>
    var volume: Float = 0.4

    init(_ initial: AppState = .defaultState) {
        subject = CurrentValueSubject(initial)
    }

    var state: AppState { subject.value }
    var statePublisher: AnyPublisher<AppState, Never> { subject.eraseToAnyPublisher() }

    func mutate(_ transform: @escaping (inout AppState) -> Void) {
        var next = subject.value
        transform(&next)
        next.version = subject.value.version + 1
        next.clampInvariants()
        subject.send(next)
    }

    /// Simulate another process changing authoritative state (arrives as a newer version).
    func simulateExternal(_ transform: (inout AppState) -> Void) {
        mutate(transform)
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `xcodebuild test -scheme OneEighty -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:OneEightyTests/InMemoryPlaybackStoreTests`
Expected: PASS — 2 tests green.

- [ ] **Step 6: Commit**

```bash
git add OneEighty/PlaybackStore.swift OneEightyTests/InMemoryPlaybackStore.swift OneEightyTests/InMemoryPlaybackStoreTests.swift
git commit -m "feat: add PlaybackStore protocol and in-memory test double"
```

---

### Task 3: AppGroupPlaybackStore — coordinated file RMW + projection + Darwin

**Files:**
- Create: `OneEighty/AppGroupPlaybackStore.swift`
- Test: `OneEightyTests/AppGroupPlaybackStoreTests.swift`

**Interfaces:**
- Consumes: `AppState` (Task 1), `PlaybackStore` (Task 2).
- Produces: `final class AppGroupPlaybackStore: PlaybackStore` with `static let shared`, `init(fileURL: URL, defaults: UserDefaults)` (test seam), `nonisolated func handleExternalWake()` (invoked by the Darwin callback).

- [ ] **Step 1: Write the failing test**

```swift
//  AppGroupPlaybackStoreTests.swift
import XCTest
import Combine
@testable import OneEighty

@MainActor
final class AppGroupPlaybackStoreTests: XCTestCase {
    private func makeStore() -> (AppGroupPlaybackStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("state.json")
        let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        return (AppGroupPlaybackStore(fileURL: url, defaults: defaults), url)
    }

    func testMutatePersistsAndBumpsVersionMonotonically() async throws {
        let (store, url) = makeStore()
        store.mutate { $0.bpm = 200 }
        store.mutate { $0.bpm = 205 }

        // Optimistic projection is immediate.
        XCTAssertEqual(store.state.bpm, 205)

        // Authoritative file catches up; version is monotonic.
        try await waitUntil { (try? self.readVersion(url)) == 2 }
        let onDisk = try readState(url)
        XCTAssertEqual(onDisk.bpm, 205)
        XCTAssertEqual(onDisk.version, 2)
    }

    func testVolumeIsUncoordinatedAndUnversioned() {
        let (store, _) = makeStore()
        let before = store.state.version
        store.volume = 0.9
        XCTAssertEqual(store.volume, 0.9, accuracy: 0.001)
        XCTAssertEqual(store.state.version, before)   // volume must not bump version
    }

    // MARK: helpers
    private func readState(_ url: URL) throws -> AppState {
        try JSONDecoder().decode(AppState.self, from: Data(contentsOf: url))
    }
    private func readVersion(_ url: URL) throws -> UInt64 { try readState(url).version }
    private func waitUntil(_ cond: @escaping () -> Bool) async throws {
        for _ in 0..<100 { if cond() { return }; try await Task.sleep(nanoseconds: 20_000_000) }
        XCTFail("condition never became true")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme OneEighty -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:OneEightyTests/AppGroupPlaybackStoreTests`
Expected: FAIL — `AppGroupPlaybackStore` does not exist.

- [ ] **Step 3: Write the implementation**

```swift
//  AppGroupPlaybackStore.swift
import Combine
import Foundation
import os

private let logger = Logger(subsystem: "com.danielbutler.OneEighty", category: "PlaybackStore")

private enum DarwinName {
    static let changed = "com.danielbutler.OneEighty.state.changed"
}

@MainActor
final class AppGroupPlaybackStore: PlaybackStore {
    static let shared = AppGroupPlaybackStore()

    private let subject: CurrentValueSubject<AppState, Never>
    var statePublisher: AnyPublisher<AppState, Never> { subject.eraseToAnyPublisher() }
    var state: AppState { subject.value }

    private nonisolated let fileURL: URL
    private nonisolated let defaults: UserDefaults
    private nonisolated let ioQueue = DispatchQueue(label: "com.danielbutler.OneEighty.store.io")

    var volume: Float {
        get { defaults.object(forKey: "volume") as? Float ?? 0.4 }
        set { defaults.set(newValue, forKey: "volume") }
    }

    private nonisolated var observerPointer: UnsafeMutableRawPointer {
        Unmanaged.passUnretained(self).toOpaque()
    }

    convenience init() {
        let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: "group.com.danielbutler.OneEighty")
        let url = (container ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("state.json")
        let defaults = UserDefaults(suiteName: "group.com.danielbutler.OneEighty") ?? .standard
        self.init(fileURL: url, defaults: defaults)
    }

    init(fileURL: URL, defaults: UserDefaults) {
        self.fileURL = fileURL
        self.defaults = defaults
        // Seed the projection from disk (or default) synchronously at init.
        let seed = Self.readFromDisk(fileURL) ?? .defaultState
        subject = CurrentValueSubject(seed)
        startObserving()
    }

    func mutate(_ transform: @escaping (inout AppState) -> Void) {
        // 1. Optimistic main-actor projection for instant UI.
        var optimistic = subject.value
        transform(&optimistic)
        optimistic.version = subject.value.version + 1
        optimistic.clampInvariants()
        subject.send(optimistic)

        // 2. Authoritative coordinated write off the main actor.
        let url = fileURL
        ioQueue.async {
            var authoritative = AppState.defaultState
            let coordinator = NSFileCoordinator()
            var coordError: NSError?
            coordinator.coordinate(writingItemAt: url, options: [], error: &coordError) { writeURL in
                var current = Self.readFromDisk(writeURL) ?? .defaultState
                transform(&current)
                current.version += 1
                current.clampInvariants()
                if let data = try? JSONEncoder().encode(current) {
                    try? data.write(to: writeURL, options: .atomic)
                }
                authoritative = current
            }
            if let coordError { logger.error("coordinate write failed: \(coordError.localizedDescription)") }
            Self.postDarwin()
            Task { @MainActor [weak self] in self?.adoptAuthoritative(authoritative) }
        }
    }

    /// Update the projection to an authoritative value if it is newer.
    private func adoptAuthoritative(_ authoritative: AppState) {
        if authoritative.version >= subject.value.version, authoritative != subject.value {
            subject.send(authoritative)
        }
    }

    // MARK: - Disk

    private nonisolated static func readFromDisk(_ url: URL) -> AppState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AppState.self, from: data)
    }

    // MARK: - Darwin

    private nonisolated static func postDarwin() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(center, CFNotificationName(DarwinName.changed as CFString), nil, nil, true)
    }

    private func startObserving() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let callback: CFNotificationCallback = { _, observer, _, _, _ in
            guard let observer else { return }
            let instance = Unmanaged<AppGroupPlaybackStore>.fromOpaque(observer).takeUnretainedValue()
            instance.handleExternalWake()
        }
        CFNotificationCenterAddObserver(center, observerPointer, callback,
            DarwinName.changed as CFString, nil, .deliverImmediately)
    }

    /// Darwin wake: re-read the file off-main, adopt if newer. Coalesced self-wakes are harmless.
    nonisolated func handleExternalWake() {
        let url = fileURL
        ioQueue.async {
            var latest: AppState?
            let coordinator = NSFileCoordinator()
            coordinator.coordinate(readingItemAt: url, options: [], error: nil) { readURL in
                latest = Self.readFromDisk(readURL)
            }
            if let latest {
                Task { @MainActor [weak self] in self?.adoptAuthoritative(latest) }
            }
        }
    }

    deinit {
        CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(), observerPointer)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme OneEighty -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:OneEightyTests/AppGroupPlaybackStoreTests`
Expected: PASS — 2 tests green.

- [ ] **Step 5: Commit**

```bash
git add OneEighty/AppGroupPlaybackStore.swift OneEightyTests/AppGroupPlaybackStoreTests.swift
git commit -m "feat: add AppGroupPlaybackStore with off-main coordinated RMW"
```

---

### Task 4: Cross-process monotonicity + external-wake adoption tests

Hardens the store against the concurrency the review flagged as untested.

**Files:**
- Modify: `OneEightyTests/AppGroupPlaybackStoreTests.swift`

**Interfaces:**
- Consumes: `AppGroupPlaybackStore` (Task 3).

- [ ] **Step 1: Write the failing tests**

Add inside `AppGroupPlaybackStoreTests` (before the closing `}` of the class):

```swift
    func testTwoStoresSharingAFileConvergeMonotonically() async throws {
        // Two stores on the SAME file simulate app + extension processes.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("state.json")
        let d1 = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        let d2 = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        let a = AppGroupPlaybackStore(fileURL: url, defaults: d1)
        let b = AppGroupPlaybackStore(fileURL: url, defaults: d2)

        a.mutate { $0.bpm = 200 }
        b.mutate { $0.isPlaying = true }

        // Both writes must survive (different fields), version reaches 2 on disk.
        try await waitUntil { (try? self.readState(url))?.version == 2 }
        let disk = try readState(url)
        XCTAssertEqual(disk.bpm, 200)
        XCTAssertTrue(disk.isPlaying)
    }

    func testHandleExternalWakeAdoptsNewerDiskState() async throws {
        let (store, url) = makeStore()
        // Write a newer state to disk out-of-band, then signal a wake.
        let newer = AppState(version: 9, bpm: 222, isPlaying: true)
        try JSONEncoder().encode(newer).write(to: url, options: .atomic)
        store.handleExternalWake()
        try await waitUntil { store.state.version == 9 }
        XCTAssertEqual(store.state.bpm, 222)
        XCTAssertTrue(store.state.isPlaying)
    }
```

- [ ] **Step 2: Run tests to verify they fail or pass as appropriate**

Run: `xcodebuild test -scheme OneEighty -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:OneEightyTests/AppGroupPlaybackStoreTests`
Expected: `testTwoStoresSharingAFileConvergeMonotonically` and `testHandleExternalWakeAdoptsNewerDiskState` PASS (the implementation from Task 3 already supports this). If either fails, fix `AppGroupPlaybackStore` — do not weaken the test.

- [ ] **Step 3: Commit**

```bash
git add OneEightyTests/AppGroupPlaybackStoreTests.swift
git commit -m "test: cover cross-process monotonicity and external-wake adoption"
```

---

## Stage 2 — Engine becomes a reconciler

Swaps the app onto the new store, converts the engine to an idempotent
reconciler with one hydration path, and deletes the old store/command machinery.

### Task 5: AudioOutput protocol seam

Extracts the audio side-effects behind a protocol so the reconciler is testable
without hardware.

**Files:**
- Create: `OneEighty/AudioOutput.swift`
- Test: `OneEightyTests/FakeAudioOutput.swift`

**Interfaces:**
- Produces:
  - `protocol AudioOutput: AnyObject { var isRunning: Bool { get }; func start(bpm: Int); func stop(); func updateBPM(_ bpm: Int); func setVolume(_ volume: Float) }`
  - `final class FakeAudioOutput: AudioOutput` (test) recording calls.

- [ ] **Step 1: Write the fake and its test**

```swift
//  FakeAudioOutput.swift
@testable import OneEighty

@MainActor
final class FakeAudioOutput: AudioOutput {
    private(set) var isRunning = false
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var lastBPM: Int?
    private(set) var lastVolume: Float?

    func start(bpm: Int) { isRunning = true; startCount += 1; lastBPM = bpm }
    func stop() { isRunning = false; stopCount += 1 }
    func updateBPM(_ bpm: Int) { lastBPM = bpm }
    func setVolume(_ volume: Float) { lastVolume = volume }
}
```

```swift
//  add to OneEightyTests/AudioOutputTests.swift
import XCTest
@testable import OneEighty

@MainActor
final class AudioOutputTests: XCTestCase {
    func testFakeTracksLifecycle() {
        let out = FakeAudioOutput()
        out.start(bpm: 190)
        XCTAssertTrue(out.isRunning)
        XCTAssertEqual(out.lastBPM, 190)
        out.stop()
        XCTAssertFalse(out.isRunning)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild test -scheme OneEighty -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:OneEightyTests/AudioOutputTests`
Expected: FAIL — `AudioOutput` does not exist.

- [ ] **Step 3: Define the protocol**

```swift
//  AudioOutput.swift
/// Audio side-effects the reconciler drives. Real impl wraps AVAudioEngine +
/// TickScheduler; the fake records calls for tests.
@MainActor
protocol AudioOutput: AnyObject {
    var isRunning: Bool { get }
    func start(bpm: Int)
    func stop()
    func updateBPM(_ bpm: Int)
    func setVolume(_ volume: Float)
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `xcodebuild test -scheme OneEighty -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:OneEightyTests/AudioOutputTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add OneEighty/AudioOutput.swift OneEightyTests/FakeAudioOutput.swift OneEightyTests/AudioOutputTests.swift
git commit -m "feat: add AudioOutput protocol seam and fake for reconciler tests"
```

---

### Task 6: Extract the real audio engine into AVAudioOutput

Moves the existing AVAudioEngine/TickScheduler code out of `OneEightyEngine`
into an `AudioOutput` conformer. Pure move — behavior preserved.

**Files:**
- Create: `OneEighty/AVAudioOutput.swift`
- Modify: `OneEighty/OneEightyEngine.swift` (audio internals will be deleted in Task 7)

**Interfaces:**
- Consumes: `AudioOutput` (Task 5), `TickScheduler` (existing), `AudioSessionManager` (existing).
- Produces: `final class AVAudioOutput: AudioOutput`.

- [ ] **Step 1: Write `AVAudioOutput` by lifting the engine's audio code**

Copy the audio internals verbatim from `OneEightyEngine.swift` (fields
`audioEngine`, `playerNode`, `audioBuffer`, `tickScheduler`; methods
`setupAudioEngine`, `loadTickSound`, `cleanupAudio`, `startOneEighty`,
`stopOneEighty`, `handleBPMChange`) into this new class, renaming to the
`AudioOutput` API:

```swift
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
```

- [ ] **Step 2: Build to confirm it compiles** (no test yet — audio needs hardware)

Run: `xcodebuild build -scheme OneEighty -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath ./build`
Expected: BUILD SUCCEEDED (both `OneEightyEngine`'s copy and `AVAudioOutput` exist; duplicate logic is temporary, removed in Task 7).

- [ ] **Step 3: Commit**

```bash
git add OneEighty/AVAudioOutput.swift
git commit -m "feat: extract AVAudioOutput from engine audio internals"
```

---

### Task 7: Reconciler core + single hydration path + mutate-based controls

Rewrites `OneEightyEngine` to own no independent truth: it mirrors `store.state`
into `@Observable` projections for the UI and drives `AudioOutput` to match.

**Files:**
- Modify: `OneEighty/OneEightyEngine.swift` (full rewrite of the class body)
- Test: `OneEightyTests/OneEightyEngineTests.swift` (update to new API)

**Interfaces:**
- Consumes: `PlaybackStore` (Task 2), `AudioOutput` (Task 5), `AVAudioOutput` (Task 6).
- Produces: `OneEightyEngine(store: PlaybackStore = AppGroupPlaybackStore.shared, audio: AudioOutput = AVAudioOutput())`, `@Observable private(set) var bpm/isPlaying`, `var volume`, `var currentVersion: UInt64`, `func hydrate()`, `func reconcileAudio()`, `func togglePlayback()`, `func setBPM(_:)`, `func adjustBPM(by:)`, `func incrementBPM()`, `func decrementBPM()`, `func setVolume(_:)`, `var canIncrementBPM/canDecrementBPM`, and a **compatibility** `var statePublisher: AnyPublisher<PlaybackState, Never>` so existing consumers (`PhoneSessionManager`, `LiveActivityManager` wiring) keep compiling until Stages 3–4 migrate them.

**Compile-safety note:** `PlaybackState { bpm, isPlaying }` is KEPT as a transitional type (existing `PhoneSessionManager`, `LiveActivityManager`, `StateSubscriber` still reference it). It is deleted only in the final cleanup task, after all consumers are migrated. Do NOT delete it here.

- [ ] **Step 1: Write failing reconciler tests**

Replace the body of `OneEightyEngineTests` with tests driven through the fake:

```swift
//  OneEightyEngineTests.swift
import XCTest
@testable import OneEighty

@MainActor
final class OneEightyEngineTests: XCTestCase {
    private func makeEngine(_ initial: AppState = .defaultState)
        -> (OneEightyEngine, InMemoryPlaybackStore, FakeAudioOutput) {
        let store = InMemoryPlaybackStore(initial)
        let audio = FakeAudioOutput()
        let engine = OneEightyEngine(store: store, audio: audio)
        engine.hydrate()
        return (engine, store, audio)
    }

    func testHydrateStartsAudioWhenDesiredPlaying() {
        let (_, _, audio) = makeEngine(AppState(version: 3, bpm: 210, isPlaying: true))
        XCTAssertTrue(audio.isRunning)
        XCTAssertEqual(audio.lastBPM, 210)   // real tempo, not hardcoded 180
    }

    func testTogglePlaybackMutatesStoreAndDrivesAudio() {
        let (engine, store, audio) = makeEngine()
        engine.togglePlayback()
        XCTAssertTrue(store.state.isPlaying)
        XCTAssertTrue(audio.isRunning)
        engine.togglePlayback()
        XCTAssertFalse(store.state.isPlaying)
        XCTAssertFalse(audio.isRunning)
    }

    func testBPMChangeWhilePlayingUpdatesTempoNotRestart() {
        let (engine, _, audio) = makeEngine(AppState(version: 1, bpm: 180, isPlaying: true))
        let startsBefore = audio.startCount
        engine.incrementBPM()
        XCTAssertEqual(audio.lastBPM, 181)
        XCTAssertEqual(audio.startCount, startsBefore)   // updateBPM, not restart
    }

    func testExternalStateChangeReconciles() {
        let (_, store, audio) = makeEngine()
        store.simulateExternal { $0.isPlaying = true; $0.bpm = 195 }
        XCTAssertTrue(audio.isRunning)
        XCTAssertEqual(audio.lastBPM, 195)
    }

    func testReconcileIsIdempotent() {
        let (engine, _, audio) = makeEngine(AppState(version: 1, bpm: 180, isPlaying: true))
        engine.reconcileAudio(); engine.reconcileAudio(); engine.reconcileAudio()
        XCTAssertEqual(audio.startCount, 1)   // already running → no re-start
    }

    func testFailedStartRollsBackDesiredState() {
        let store = InMemoryPlaybackStore()
        let audio = FailingAudioOutput()   // start() never sets isRunning
        let engine = OneEightyEngine(store: store, audio: audio)
        engine.hydrate()
        engine.togglePlayback()
        XCTAssertFalse(store.state.isPlaying)   // rolled back to reality
    }
}

@MainActor
final class FailingAudioOutput: AudioOutput {
    var isRunning = false            // never becomes true
    func start(bpm: Int) {}
    func stop() {}
    func updateBPM(_ bpm: Int) {}
    func setVolume(_ volume: Float) {}
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild test -scheme OneEighty -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:OneEightyTests/OneEightyEngineTests`
Expected: FAIL — new `OneEightyEngine` API does not exist.

- [ ] **Step 3: Rewrite `OneEightyEngine`**

Replace the class in `OneEightyEngine.swift` with the reconciler. KEEP the
`struct PlaybackState { let bpm: Int; let isPlaying: Bool }` definition (transitional
— consumers still use it) and add a compatibility `statePublisher`. Interruptions and
Now Playing are added in Task 8. Minimal reconciler body:

```swift
//  OneEightyEngine.swift
import Combine
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

    init(store: PlaybackStore = AppGroupPlaybackStore.shared, audio: AudioOutput = AVAudioOutput()) {
        self.store = store
        self.audio = audio
    }

    nonisolated deinit {}

    /// Single hydration path: mirror store, reconcile audio, subscribe to changes.
    func hydrate() {
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
    private var hydrated = false
    func setup() { ensureReady() }
    func teardown() {}
    func ensureReady() { guard !hydrated else { return }; hydrated = true; hydrate() }
}
```

Guard `hydrate()`'s body so it is safe to call more than once (it sets
`hydrated = true` and returns early if already hydrated).

Note: `reconcileAudio` runs on `updateBPM` only when already running; the "start"
branch guards `!audio.isRunning`, so repeat syncs are idempotent (satisfies
`testReconcileIsIdempotent`).

- [ ] **Step 4: Keep the whole test target compiling**

`xcodebuild test` compiles the entire target, so every test file that constructs
`OneEightyEngine(store:)` with the old `StateStore`/`InMemoryStateStore` or uses
`StoreEvent`/removed engine API must be migrated or removed now. Find them:

Run: `grep -rln "InMemoryStateStore\|simulateExternalChange\|StoreEvent\|OneEightyEngine(store:" OneEightyTests`

For each hit, choose:
- **Migrate** (behavior still exists): re-point to `InMemoryPlaybackStore` +
  `FakeAudioOutput`, using `store.simulateExternal { … }` for external changes and
  the `AppState`-based API — follow the pattern in the rewritten `OneEightyEngineTests`.
  This applies to salvageable cases in `IntegrationTests`, `NowPlayingTests`,
  `ContentViewTests`, `StateSubscriberTests`.
- **Delete** (tests removed architecture — delta commands, old Darwin store,
  old interruption internals): `AudioInterruptionRecoveryTests` is tightly coupled
  to the old engine internals; delete it and rely on the new engine unit tests
  (interruption behavior is re-covered against the new engine in Task 8). Delete
  `IntegrationTests.swift` if a faithful re-point is not straightforward — the new
  per-component unit tests (store, engine, LA, watch) cover the same ground.

Do NOT delete `SharedStateStore.swift`, `StateStore.swift`, or
`InMemoryStateStore.swift` yet — the extension intents still use them until Stage 3.

- [ ] **Step 5: Run engine tests, then the full suite**

Run: `xcodebuild test -scheme OneEighty -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:OneEightyTests/OneEightyEngineTests`
Then: `xcodebuild test -scheme OneEighty -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`
Expected: reconciler tests PASS; full target BUILDS and remaining tests PASS.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: rewrite OneEightyEngine as idempotent reconciler over PlaybackStore"
```

---

### Task 8: Interruptions + Now Playing + app wiring

Restores interruption recovery and Now Playing on the new engine and points the
app's lifecycle at `hydrate()`. No file deletions here — obsolete files are
removed in the final cleanup task once every consumer is migrated.

**Files:**
- Modify: `OneEighty/OneEightyEngine.swift` (add interruption + now-playing sections)
- Modify: `OneEighty/OneEightyApp.swift`, `OneEighty/ContentView.swift`
- Test: `OneEightyTests/EngineInterruptionTests.swift` (new, against the new engine)

**Interfaces:**
- Consumes: `OneEightyEngine` (Task 7), `AudioSessionManager` (existing), `FakeAudioOutput` (Task 5).
- Produces: `OneEightyEngine.startObservingInterruptions()`, `setupRemoteCommands()`, `updateNowPlaying()`.

- [ ] **Step 1: Add interruption + now-playing to the engine**

Append to `OneEightyEngine` (interruptions set desired state via `store.mutate`;
the reconciler does the audio):

```swift
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
```

Add Now Playing by moving `setupRemoteCommands()` and `updateNowPlaying()` from
the old engine verbatim, changing their state reads to `bpm`/`isPlaying` and their
control calls to the new methods (`togglePlayback`, `incrementBPM`, `decrementBPM`),
and call `updateNowPlaying()` inside `syncFromStore`. Import `MediaPlayer` and `UIKit`.
Call `startObservingInterruptions()` and `setupRemoteCommands()` at the end of `hydrate()`.

- [ ] **Step 2: Point the app at the new store/engine**

In `OneEightyApp.swift`, replace the reset-state block and remove the
`AudioSessionManager` note only if still valid; change `ContentView.onAppear` to
call `engine.hydrate()` and `onDisappear` to a no-op (teardown removed — the
engine now lives for the app lifetime). Concretely, `ContentView`:

```swift
        .onAppear { engine.hydrate() }
        // remove the old .onDisappear teardown
```

In `OneEightyApp.init`, keep the `--reset-state` support by deleting the state
file and volume key:

```swift
        if ProcessInfo.processInfo.arguments.contains("--reset-state") {
            if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.danielbutler.OneEighty") {
                try? FileManager.default.removeItem(at: container.appendingPathComponent("state.json"))
            }
            UserDefaults(suiteName: "group.com.danielbutler.OneEighty")?.removeObject(forKey: "volume")
        }
```

- [ ] **Step 3: Add interruption tests against the new engine**

```swift
//  EngineInterruptionTests.swift
import XCTest
@testable import OneEighty

@MainActor
final class EngineInterruptionTests: XCTestCase {
    func testInterruptionStopsThenResumesPlayback() {
        let store = InMemoryPlaybackStore(AppState(version: 1, bpm: 180, isPlaying: true))
        let audio = FakeAudioOutput()
        let engine = OneEightyEngine(store: store, audio: audio)
        engine.hydrate()
        engine.startObservingInterruptions()

        NotificationCenter.default.post(name: .audioInterruptionBegan, object: nil)
        // began sets desired isPlaying=false via mutate (async Task) — pump the runloop
        let e1 = expectation(description: "stopped")
        DispatchQueue.main.async { e1.fulfill() }
        wait(for: [e1], timeout: 1)
        XCTAssertFalse(store.state.isPlaying)

        NotificationCenter.default.post(name: .audioInterruptionEnded, object: nil)
        let e2 = expectation(description: "resumed")
        DispatchQueue.main.async { e2.fulfill() }
        wait(for: [e2], timeout: 1)
        XCTAssertTrue(store.state.isPlaying)
        XCTAssertTrue(audio.isRunning)
    }
}
```

- [ ] **Step 4: Build + full test suite**

Run: `xcodebuild test -scheme OneEighty -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`
Expected: BUILD SUCCEEDED and all tests PASS.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: restore interruptions and now-playing on the reconciler engine; hydrate on appear"
```

---

## Stage 3 — Live Activity + intents (cross-process)

### Task 9: Store-backed Live Activity coordination (dedupe + budget)

Adds cross-process push dedupe and budget accounting to the store so both the app
and the widget extension share one source of truth for "what was last pushed."

**Files:**
- Modify: `OneEighty/PlaybackStore.swift` (extend protocol)
- Modify: `OneEighty/AppGroupPlaybackStore.swift`, `OneEightyTests/InMemoryPlaybackStore.swift`
- Test: `OneEightyTests/ActivityCoordinationTests.swift`

**Interfaces:**
- Produces (added to `PlaybackStore`):
  - `func claimActivityPush(version: UInt64, at date: Date) -> Bool` — atomically returns `true` and records the push iff `version` is newer than the last recorded push; else `false`.
  - `func activityPushesInLastHour(at date: Date) -> Int`

- [ ] **Step 1: Write the failing test**

```swift
//  ActivityCoordinationTests.swift
import XCTest
@testable import OneEighty

@MainActor
final class ActivityCoordinationTests: XCTestCase {
    func testClaimDedupesOlderOrEqualVersions() {
        let store = InMemoryPlaybackStore()
        let now = Date(timeIntervalSince1970: 1000)
        XCTAssertTrue(store.claimActivityPush(version: 5, at: now))
        XCTAssertFalse(store.claimActivityPush(version: 5, at: now))   // equal → skip
        XCTAssertFalse(store.claimActivityPush(version: 3, at: now))   // older → skip
        XCTAssertTrue(store.claimActivityPush(version: 6, at: now))    // newer → push
    }

    func testBudgetCountsPushesInLastHour() {
        let store = InMemoryPlaybackStore()
        let base = Date(timeIntervalSince1970: 10_000)
        _ = store.claimActivityPush(version: 1, at: base)
        _ = store.claimActivityPush(version: 2, at: base.addingTimeInterval(60))
        _ = store.claimActivityPush(version: 3, at: base.addingTimeInterval(4000)) // >1h from base
        XCTAssertEqual(store.activityPushesInLastHour(at: base.addingTimeInterval(4000)), 1)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild test -scheme OneEighty -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:OneEightyTests/ActivityCoordinationTests`
Expected: FAIL — methods don't exist.

- [ ] **Step 3: Extend the protocol and both stores**

Add to `PlaybackStore`:

```swift
    func claimActivityPush(version: UInt64, at date: Date) -> Bool
    func activityPushesInLastHour(at date: Date) -> Int
```

In `InMemoryPlaybackStore`:

```swift
    private var lastPushedVersion: UInt64 = 0
    private var pushTimestamps: [Date] = []

    func claimActivityPush(version: UInt64, at date: Date) -> Bool {
        guard version > lastPushedVersion else { return false }
        lastPushedVersion = version
        pushTimestamps.append(date)
        return true
    }
    func activityPushesInLastHour(at date: Date) -> Int {
        pushTimestamps.filter { $0 > date.addingTimeInterval(-3600) }.count
    }
```

In `AppGroupPlaybackStore`, back these with app-group `defaults` under a small
coordinated lock (reuse `ioQueue` synchronously via `ioQueue.sync`):

```swift
    func claimActivityPush(version: UInt64, at date: Date) -> Bool {
        ioQueue.sync {
            let last = UInt64(defaults.integer(forKey: "lastPushedActivityVersion"))
            guard version > last else { return false }
            defaults.set(Int(version), forKey: "lastPushedActivityVersion")
            var stamps = (defaults.array(forKey: "activityPushStamps") as? [Double]) ?? []
            stamps.append(date.timeIntervalSince1970)
            stamps = stamps.filter { $0 > date.timeIntervalSince1970 - 3600 }
            defaults.set(stamps, forKey: "activityPushStamps")
            return true
        }
    }
    func activityPushesInLastHour(at date: Date) -> Int {
        ioQueue.sync {
            let stamps = (defaults.array(forKey: "activityPushStamps") as? [Double]) ?? []
            return stamps.filter { $0 > date.timeIntervalSince1970 - 3600 }.count
        }
    }
```

- [ ] **Step 4: Run to verify it passes**

Run: `xcodebuild test -scheme OneEighty -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:OneEightyTests/ActivityCoordinationTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: store-backed cross-process Live Activity dedupe and budget"
```

---

### Task 10: LiveActivityManager pushes by version through the store

Rewires `LiveActivityManager` to push authoritative versioned state, deduped and
budgeted via the store, deleting the echo-suppression throttle logic.

**Files:**
- Modify: `OneEighty/LiveActivityManager.swift`
- Modify: `OneEighty/OneEightyEngine.swift` (have `syncFromStore` call `LiveActivityManager.shared.apply(state)`)
- Modify: `OneEightyTests/LiveActivityManagerTests.swift`, `OneEightyTests/ReconciliationTimerTests.swift`

**Interfaces:**
- Consumes: `PlaybackStore` (Task 9), `AppState`.
- Produces: `func apply(_ state: AppState)` — the single entry point; pushes iff `store.claimActivityPush(version:at:)` succeeds and budget allows.

**Also:** remove the `IntentActivityDebouncer.shared.setUpdateHandler { … }` wiring
from `LiveActivityManager.init` (the debouncer is deleted in Task 11) and change
`confirmedState`/`push` to stop using the transitional `PlaybackState` (use the
local `PlaybackStateSnapshot`). In `OneEightyEngine.syncFromStore`, add
`LiveActivityManager.shared.apply(state)` after updating the UI projection.

- [ ] **Step 1: Write the failing test**

```swift
    func testApplyPushesOncePerVersion() {
        let store = InMemoryPlaybackStore()
        let manager = LiveActivityManager.makeForTesting(store: store)
        manager.startActivity(bpm: 180, isPlaying: true)     // creates activity
        let before = manager.tracker.totalUpdateCount
        let s = AppState(version: 4, bpm: 190, isPlaying: true)
        manager.apply(s)
        manager.apply(s)   // same version → deduped, no second push
        XCTAssertEqual(manager.tracker.totalUpdateCount, before + 1)
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild test -scheme OneEighty -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:OneEightyTests/LiveActivityManagerTests`
Expected: FAIL — `apply(_:)`/`makeForTesting` don't exist.

- [ ] **Step 3: Implement `apply` and route updates through it**

Add a testing initializer and the version-gated apply:

```swift
    private let store: PlaybackStore
    static func makeForTesting(store: PlaybackStore) -> LiveActivityManager {
        LiveActivityManager(store: store)
    }
    private init(store: PlaybackStore) { self.store = store; tracker = ActivityUpdateTracker() }

    /// Single entry point. Pushes only if this version hasn't been pushed and budget allows.
    func apply(_ state: AppState) {
        guard store.claimActivityPush(version: state.version, at: Date()) else { return }
        guard currentActivity != nil else {
            startActivity(bpm: state.bpm, isPlaying: state.isPlaying)
            tracker.recordUpdate()
            return
        }
        tracker.recordUpdate()
        push(PlaybackStateSnapshot(bpm: state.bpm, isPlaying: state.isPlaying))
    }
```

Replace `updateActivity(bpm:isPlaying:)` call sites: the engine's `syncFromStore`
calls `LiveActivityManager.shared.apply(state)`. Delete `throttleTimer`,
`pendingState`, `reconciliationTimer`, and `scheduleReconciliation` (echo
suppression is gone; dedupe is by version). Keep `startActivity`, `endActivity`,
`cleanupStaleActivities`, and the `contentUpdates` observer. `push` now takes a
small local struct `PlaybackStateSnapshot { bpm; isPlaying }` (define it in this
file) since `PlaybackState` was deleted.

Update the `shared` singleton to build with `AppGroupPlaybackStore.shared`.

- [ ] **Step 4: Update/trim the affected tests**

`ReconciliationTimerTests` tests deleted behavior — replace its assertions with
the version-dedupe behavior or delete the file if fully obsolete:

```bash
git rm OneEightyTests/ReconciliationTimerTests.swift
```

Update `LiveActivityManagerTests` construction to `makeForTesting(store:)`.

- [ ] **Step 5: Run to verify it passes**

Run: `xcodebuild test -scheme OneEighty -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:OneEightyTests/LiveActivityManagerTests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: LiveActivityManager pushes by version via store dedupe, drop echo throttle"
```

---

### Task 11: BPM intents → absolute mutation + post-mutation Live Activity push

**Files:**
- Modify: `OneEighty/OneEightyIntents.swift` (Increment/Decrement)
- Modify: `OneEighty/IntentActivityDebouncer.swift` (simplify or delete)
- Test: `OneEightyTests/IntentBudgetTrackingTests.swift`, `OneEightyTests/IntentActivityDebouncerTests.swift`

**Interfaces:**
- Consumes: `AppGroupPlaybackStore.shared`, `LiveActivityManager` (Task 10).

- [ ] **Step 1: Rewrite the bpm intents**

```swift
struct IncrementBPMIntent: AppIntent {
    static var title: LocalizedStringResource = "Increment SPM"
    @MainActor func perform() async throws -> some IntentResult {
        let store = AppGroupPlaybackStore.shared
        store.mutate { $0.bpm += 1 }
        LiveActivityManager.shared.apply(store.state)   // post-mutation actual value
        return .result()
    }
}
struct DecrementBPMIntent: AppIntent {
    static var title: LocalizedStringResource = "Decrement SPM"
    @MainActor func perform() async throws -> some IntentResult {
        let store = AppGroupPlaybackStore.shared
        store.mutate { $0.bpm -= 1 }
        LiveActivityManager.shared.apply(store.state)
        return .result()
    }
}
```

Delete `IntentActivityDebouncer.swift` and its test — dedupe/budget now live in
the store; the `store.state` after `mutate` is the accurate absolute value, so no
estimate and no debounce are needed.

```bash
git rm OneEighty/IntentActivityDebouncer.swift OneEightyTests/IntentActivityDebouncerTests.swift
```

- [ ] **Step 2: Update the budget-tracking test**

Rewrite `IntentBudgetTrackingTests` to assert that N rapid increments produce the
correct final absolute bpm and at most N distinct-version pushes:

```swift
    func testRapidIncrementsConvergeToAbsoluteBPM() {
        let store = InMemoryPlaybackStore()
        for _ in 0..<5 { store.mutate { $0.bpm += 1 } }
        XCTAssertEqual(store.state.bpm, 185)
        XCTAssertEqual(store.state.version, 5)
    }
```

- [ ] **Step 3: Build + run**

Run: `xcodebuild test -scheme OneEighty -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:OneEightyTests/IntentBudgetTrackingTests`
Expected: PASS. Fix `grep -rn "IntentActivityDebouncer"` stragglers.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat: bpm intents mutate absolute state and push actual value; drop debouncer"
```

---

### Task 12: Play/Stop/Toggle intents conform to AudioPlaybackIntent

**Files:**
- Modify: `OneEighty/OneEightyIntents.swift`

**Interfaces:**
- Consumes: `AppGroupPlaybackStore.shared`, `OneEightyEngine`.

- [ ] **Step 1: Conform the playback intents**

`AudioPlaybackIntent`-conforming intents run in the app process. Mutate desired
state; the engine (alive because the system launched it for the audio intent)
reconciles audio:

```swift
struct ToggleOneEightyIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Toggle OneEighty"
    @MainActor func perform() async throws -> some IntentResult {
        let store = AppGroupPlaybackStore.shared
        store.mutate { $0.isPlaying.toggle() }
        LiveActivityManager.shared.apply(store.state)
        return .result()
    }
}
struct StartOneEightyIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Start OneEighty"
    @MainActor func perform() async throws -> some IntentResult {
        let store = AppGroupPlaybackStore.shared
        store.mutate { $0.isPlaying = true }
        LiveActivityManager.shared.apply(store.state)
        return .result()
    }
}
struct StopOneEightyIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Stop OneEighty"
    @MainActor func perform() async throws -> some IntentResult {
        let store = AppGroupPlaybackStore.shared
        store.mutate { $0.isPlaying = false }
        LiveActivityManager.shared.apply(store.state)
        return .result()
    }
}
```

- [ ] **Step 2: Build**

Run: `xcodebuild build -scheme OneEighty -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath ./build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Manual device verification (note in commit, not automated)**

On a physical device: kill the app, tap Play in the Live Activity, confirm audio
starts (background-audio start; the simulator does not reproduce this reliably).

- [ ] **Step 4: Commit**

```bash
git add OneEighty/OneEightyIntents.swift
git commit -m "feat: play/stop/toggle intents conform to AudioPlaybackIntent"
```

---

## Stage 4 — Watch (last)

### Task 13: Versioned WCSession payloads + phone reconciliation

**Files:**
- Modify: `OneEighty/PhoneSessionManager.swift`
- Test: `OneEightyTests/PhoneSessionManagerTests.swift`

**Interfaces:**
- Consumes: `OneEightyEngine`/`AppState`.
- Produces: `PhoneSessionManager` sends `{bpm, isPlaying, version}` in every message and reply; `reconcile` is driven by a timer + `didBecomeActive`.

- [ ] **Step 1: Write the failing test**

```swift
    func testStatePayloadIncludesVersion() {
        let store = InMemoryPlaybackStore(AppState(version: 12, bpm: 200, isPlaying: true))
        let engine = OneEightyEngine(store: store, audio: FakeAudioOutput())
        engine.hydrate()
        let mgr = PhoneSessionManager(engine: engine)
        let payload = mgr.statePayload()
        XCTAssertEqual(payload["version"] as? UInt64, 12)
        XCTAssertEqual(payload["bpm"] as? Int, 200)
        XCTAssertEqual(payload["isPlaying"] as? Bool, true)
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild test -scheme OneEighty -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:OneEightyTests/PhoneSessionManagerTests`
Expected: FAIL — `statePayload()` doesn't exist / lacks version.

- [ ] **Step 3: Add version to payloads and wire reconcile**

Add:

```swift
    func statePayload() -> [String: Any] {
        ["bpm": engine.bpm, "isPlaying": engine.isPlaying, "version": engine.currentVersion]
    }
```

Expose `engine.currentVersion` (`var currentVersion: UInt64 { store.state.version }`
on the engine). Replace the manual dictionaries in `sendStateToWatch` and both
reply handlers with `statePayload()`. Move `updateApplicationContext` ABOVE the
reachability/installed guard so state persistence isn't dropped. Add a 1s repeating
reconcile timer and a `didBecomeActive` observer that call `sendStateToWatch()`.

- [ ] **Step 4: Run to verify it passes**

Run: `xcodebuild test -scheme OneEighty -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:OneEightyTests/PhoneSessionManagerTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: versioned WCSession payloads + phone reconciliation timer"
```

---

### Task 14: Command-id dedupe on the phone

**Files:**
- Modify: `OneEighty/PhoneSessionManager.swift`
- Test: `OneEightyTests/PhoneSessionManagerTests.swift`

**Interfaces:**
- Produces: `handleWatchCommand` dedupes by `commandId`; applies relative deltas to authoritative state via `engine.adjustBPM`/`togglePlayback`.

- [ ] **Step 1: Write the failing test**

```swift
    func testDuplicateCommandIdAppliedOnce() {
        let store = InMemoryPlaybackStore()
        let engine = OneEightyEngine(store: store, audio: FakeAudioOutput())
        engine.hydrate()
        let mgr = PhoneSessionManager(engine: engine)
        let cmd: [String: Any] = ["command": "adjustBPM", "count": 3, "commandId": 42]
        mgr.handleWatchCommandForTesting(cmd)
        mgr.handleWatchCommandForTesting(cmd)   // retry — must NOT double-apply
        XCTAssertEqual(store.state.bpm, 183)
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild test -scheme OneEighty -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:OneEightyTests/PhoneSessionManagerTests`
Expected: FAIL — no dedupe / helper.

- [ ] **Step 3: Implement dedupe**

```swift
    private var seenCommandIds = Set<Int>()
    func handleWatchCommandForTesting(_ m: [String: Any]) { handleWatchCommand(m) }

    // inside handleWatchCommand, after extracting `command`:
    if let id = message["commandId"] as? Int {
        guard !seenCommandIds.contains(id) else {
            logger.info("Dropping duplicate watch command id \(id)")
            return
        }
        seenCommandIds.insert(id)
        if seenCommandIds.count > 256 { seenCommandIds.removeFirst() }
    }
```

Keep applying deltas to authoritative state (`engine.adjustBPM(by:)`,
`engine.togglePlayback()`), which resolve against truth — no stale-cache clobber.

- [ ] **Step 4: Run to verify it passes**

Run: `xcodebuild test -scheme OneEighty -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:OneEightyTests/PhoneSessionManagerTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: dedupe watch commands by commandId on the phone"
```

---

### Task 15: Watch in-flight tracking + snap-when-quiescent + self-heal

**Files:**
- Modify: `OneEightyWatch Watch App/WatchSessionManager.swift`
- Test: `OneEightyWatch Watch AppTests/WatchSessionManagerTests.swift`

**Interfaces:**
- Produces: each command carries an incrementing `commandId`; `applyState` is ignored while any command is in-flight; on quiescence (in-flight count 0) the watch adopts the latest authoritative snapshot; failed/timed-out commands decrement in-flight and trigger adoption.

- [ ] **Step 1: Write the failing tests**

```swift
    func testOptimisticHeldWhileCommandInFlight() {
        let m = WatchSessionManager()
        m.incrementBPM()                                  // optimistic 181, in-flight 1
        m.applyState(["bpm": 180, "isPlaying": false, "version": 3])
        XCTAssertEqual(m.bpm, 181)                        // ignored while in-flight
    }

    func testSnapsToAuthoritativeWhenQuiescent() {
        let m = WatchSessionManager()
        m.incrementBPM()
        m.ackInFlightForTesting()                         // command acked → in-flight 0
        m.applyState(["bpm": 200, "isPlaying": true, "version": 9])
        XCTAssertEqual(m.bpm, 200)                        // adopts latest authoritative
        XCTAssertTrue(m.isPlaying)
    }

    func testLostOptimisticEditSelfHeals() {
        let m = WatchSessionManager()
        m.incrementBPM()                                  // optimistic 181
        m.failInFlightForTesting()                        // command failed → revert + quiescent
        m.applyState(["bpm": 180, "isPlaying": false, "version": 3])
        XCTAssertEqual(m.bpm, 180)                        // healed back to truth
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild test -scheme OneEighty -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:"OneEightyWatch Watch AppTests/WatchSessionManagerTests"`
Expected: FAIL — in-flight tracking doesn't exist.

- [ ] **Step 3: Implement in-flight tracking**

Replace the `isCoolingDown` timer scheme with in-flight tracking:

```swift
    private var inFlight = 0
    private var nextCommandId = 0
    private var latestAuthoritative: (bpm: Int, isPlaying: Bool, version: UInt64)?

    private func beginCommand() -> Int {
        inFlight += 1
        nextCommandId += 1
        return nextCommandId
    }
    private func endCommand(success: Bool) {
        inFlight = max(0, inFlight - 1)
        if inFlight == 0 { adoptLatestIfAny() }
    }
    private func adoptLatestIfAny() {
        if let s = latestAuthoritative { bpm = s.bpm; isPlaying = s.isPlaying }
    }

    func applyState(_ message: [String: Any]) {
        guard let v = message["version"] as? UInt64,
              let b = message["bpm"] as? Int,
              let p = message["isPlaying"] as? Bool else { return }
        if latestAuthoritative == nil || v > latestAuthoritative!.version {
            latestAuthoritative = (b, p, v)
        }
        guard inFlight == 0 else { return }   // hold optimistic while editing
        adoptLatestIfAny()
    }

    // test seams
    func ackInFlightForTesting() { endCommand(success: true) }
    func failInFlightForTesting() { bpm = latestAuthoritative?.bpm ?? bpm; endCommand(success: false) }
```

Update `toggle`/`incrementBPM`/`decrementBPM`/`sendCommand` to call
`beginCommand()`, attach the returned `commandId` to the payload, and call
`endCommand(success:)` in the reply/error handlers. Delete `isCoolingDown`,
`cooldownTimer`, `startCooldown`, and the cooldown checks in `applyState`.

- [ ] **Step 4: Run to verify it passes**

Run: `xcodebuild test -scheme OneEighty -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:"OneEightyWatch Watch AppTests/WatchSessionManagerTests"`
Expected: PASS.

- [ ] **Step 5: Full suite + commit**

Run: `xcodebuild test -scheme OneEighty -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`
Expected: PASS.

```bash
git add -A
git commit -m "feat: watch in-flight tracking with snap-to-authoritative self-heal"
```

---

### Task 16: Cleanup — delete obsolete files and compat shims

Now that every consumer is migrated, remove the old machinery. Deletions are
gated on grep showing zero remaining references, so the build stays green.

**Files:**
- Delete (verify unreferenced first): `OneEighty/SharedStateStore.swift`, `OneEighty/StateStore.swift` (old command/event protocol), `OneEightyTests/InMemoryStateStore.swift`, `OneEightyTests/SharedOneEightyStateTests.swift`, `OneEightyTests/DeltaCommandTests.swift`, `OneEighty/IntentActivityDebouncer.swift` (if not already removed in Task 11).
- Modify: `OneEighty/OneEightyEngine.swift` (remove `setup()/teardown()/ensureReady()` compat shims), `OneEighty/PhoneSessionManager.swift` (replace any `engine.ensureReady()` call with `engine.hydrate()` — safe, guarded), and remove the transitional `PlaybackState` + compat `statePublisher` if no longer referenced.

- [ ] **Step 1: Find remaining references to each obsolete symbol**

Run: `grep -rn "SharedStateStore\|StateStoreCommand\|StoreEvent\|InMemoryStateStore\|IntentActivityDebouncer\|ensureReady\|\.setup()\|\.teardown()" OneEighty OneEightyTests OneEightyWidget "OneEightyWatch Watch App" "OneEightyWatch Watch AppTests"`

- [ ] **Step 2: Migrate the last stragglers**

Replace any `engine.ensureReady()` / `engine.setup()` with `engine.hydrate()`.
Confirm nothing outside the files being deleted references the old store types.

- [ ] **Step 3: Delete the obsolete files**

```bash
git rm OneEighty/SharedStateStore.swift OneEighty/StateStore.swift \
       OneEightyTests/InMemoryStateStore.swift \
       OneEightyTests/SharedOneEightyStateTests.swift \
       OneEightyTests/DeltaCommandTests.swift
```

(Skip any already deleted. Delete `IntentActivityDebouncer.swift` here if Task 11
did not.)

- [ ] **Step 4: Remove compat shims**

Delete `setup()`, `teardown()`, `ensureReady()` from `OneEightyEngine`. If
`grep -rn "\.statePublisher\|PlaybackState"` shows no remaining consumers of the
transitional type, delete `struct PlaybackState` and the compat `statePublisher`.
If `StateSubscriber`/`PhoneSessionManager` still use `PlaybackState`, leave it —
it is a harmless value type; note that in the commit message.

- [ ] **Step 5: Build + full test suite**

Run: `xcodebuild test -scheme OneEighty -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`
Expected: BUILD SUCCEEDED, all tests PASS.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "chore: remove old store, delta commands, and reconciler compat shims"
```

---

## Final verification

- [ ] **Full build + test suite green**

Run: `xcodebuild test -scheme OneEighty -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`
Expected: BUILD SUCCEEDED, all tests PASS.

- [ ] **No stragglers**

Run: `grep -rn "SharedStateStore\|StateStoreCommand\|StoreEvent\|IntentActivityDebouncer\|isCoolingDown\|pendingBPMDelta" OneEighty OneEightyTests OneEightyWidget "OneEightyWatch Watch App" "OneEightyWatch Watch AppTests"`
Expected: no results.

- [ ] **Manual device pass** (documented, not automated): widget play from a
  suspended app starts audio; rapid crown scroll on the watch converges; Live
  Activity +/- shows correct absolute SPM without flicker.
