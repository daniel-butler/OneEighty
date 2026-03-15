# Delta Commands + Reconciliation Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace absolute BPM writes with delta commands and add reconciliation to ensure the DI/LA always converges to the engine's state.

**Architecture:** All 4 surfaces (App UI, LA, DI, Watch) send delta commands to the engine instead of absolute writes. A `StateSubscriber` protocol with a default `reconcile` implementation ensures remote stores (ActivityKit, WatchConnectivity) converge to the engine's state after throttled bursts. The `contentUpdates` stream provides the confirmed state for comparison.

**Tech Stack:** Swift, ActivityKit, WatchConnectivity, Combine, XCTest

**Spec:** `docs/superpowers/specs/2026-03-15-delta-commands-reconciliation.md`

---

## File Map

| File | Action | Responsibility |
|------|--------|---------------|
| `OneEighty/StateStore.swift` | Modify | Add `.adjustBPM(Int)` to `StateStoreCommand` |
| `OneEighty/SharedStateStore.swift` | Modify | Add `pendingBPMDelta` accumulation + Darwin notification for `.adjustBPM` |
| `OneEightyTests/InMemoryStateStore.swift` | Modify | No-op for `.adjustBPM` (engine handles via `simulateExternalChange`) |
| `OneEighty/OneEightyEngine.swift` | Modify | Handle `.command(.adjustBPM)` in `externalChanges` subscriber |
| `OneEighty/StateSubscriber.swift` | Create | Protocol + default `reconcile` implementation |
| `OneEighty/ActivityUpdateTracker.swift` | Modify | Remove delivery confirmation tracking |
| `OneEighty/LiveActivityManager.swift` | Modify | Conform to `StateSubscriber`, remove dedup, add reconciliation timer |
| `OneEighty/IntentActivityDebouncer.swift` | Modify | Remove dedup fields, simplify to play/stop + widget fallback |
| `OneEighty/OneEightyIntents.swift` | Modify | BPM intents use `.adjustBPM` delta, remove `store.bpm =` writes |
| `OneEighty/PhoneSessionManager.swift` | Modify | Conform to `StateSubscriber`, add reply handler |
| `OneEightyTests/DeltaCommandTests.swift` | Create | Tests for delta command pipeline |
| `OneEightyTests/StateSubscriberTests.swift` | Create | Tests for reconciliation protocol |
| `OneEightyTests/ReconciliationTimerTests.swift` | Create | Tests for LiveActivityManager reconciliation timer lifecycle |
| `OneEightyTests/ActivityUpdateTrackerTests.swift` | Modify | Remove delivery confirmation tests |
| `OneEightyTests/LiveActivityManagerTests.swift` | Modify | Remove dedup tests, add reconciliation |
| `OneEightyTests/IntentActivityDebouncerTests.swift` | Modify | Remove dedup tests |
| `OneEightyTests/IntentBudgetTrackingTests.swift` | Modify | Update for delta command flow |

---

## Task 1: Delta Commands in StateStore + Engine

Add `.adjustBPM(Int)` to the command vocabulary. Engine handles it. Tests prove no lost increments.

**Files:**
- Modify: `OneEighty/StateStore.swift:10-13`
- Modify: `OneEightyTests/InMemoryStateStore.swift:28-30`
- Modify: `OneEighty/SharedStateStore.swift:78-85`
- Modify: `OneEighty/OneEightyEngine.swift:316-329`
- Create: `OneEightyTests/DeltaCommandTests.swift`

### Steps

- [ ] **Step 1: Write failing tests for delta commands**

Create `OneEightyTests/DeltaCommandTests.swift`:

```swift
import XCTest
@testable import OneEighty

final class DeltaCommandTests: XCTestCase {

    nonisolated func testAdjustBPMDeltaApplied() async {
        await MainActor.run {
            let store = InMemoryStateStore()
            let engine = OneEightyEngine(store: store)
            engine.setup()

            store.simulateExternalChange(.command(.adjustBPM(1)))

            XCTAssertEqual(engine.bpm, 181, "Delta +1 from 180 should give 181")
            engine.teardown()
        }
    }

    nonisolated func testMultipleSequentialDeltas() async {
        await MainActor.run {
            let store = InMemoryStateStore()
            let engine = OneEightyEngine(store: store)
            engine.setup()

            for _ in 0..<4 {
                store.simulateExternalChange(.command(.adjustBPM(1)))
            }

            XCTAssertEqual(engine.bpm, 184, "4x +1 deltas from 180 should give 184")
            engine.teardown()
        }
    }

    nonisolated func testDeltaClampedAtUpperBound() async {
        await MainActor.run {
            let store = InMemoryStateStore()
            store.bpm = 229
            let engine = OneEightyEngine(store: store)
            engine.setup()

            store.simulateExternalChange(.command(.adjustBPM(5)))

            XCTAssertEqual(engine.bpm, 230, "Should clamp at upper bound 230")
            engine.teardown()
        }
    }

    nonisolated func testDeltaClampedAtLowerBound() async {
        await MainActor.run {
            let store = InMemoryStateStore()
            store.bpm = 151
            let engine = OneEightyEngine(store: store)
            engine.setup()

            store.simulateExternalChange(.command(.adjustBPM(-5)))

            XCTAssertEqual(engine.bpm, 150, "Should clamp at lower bound 150")
            engine.teardown()
        }
    }

    nonisolated func testMixedDeltas() async {
        await MainActor.run {
            let store = InMemoryStateStore()
            let engine = OneEightyEngine(store: store)
            engine.setup()

            store.simulateExternalChange(.command(.adjustBPM(3)))
            store.simulateExternalChange(.command(.adjustBPM(-1)))

            XCTAssertEqual(engine.bpm, 182, "+3 -1 from 180 = 182")
            engine.teardown()
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme OneEighty -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:OneEightyTests/DeltaCommandTests 2>&1 | grep -E '(error:|FAILED|SUCCEEDED)'`

Expected: FAIL — `adjustBPM` is not a member of `StateStoreCommand`

- [ ] **Step 3: Add `.adjustBPM(Int)` to `StateStoreCommand`**

In `OneEighty/StateStore.swift`, change the enum:

```swift
enum StateStoreCommand: Equatable {
    case start
    case stop
    case adjustBPM(Int)
}
```

- [ ] **Step 4: Verify `InMemoryStateStore.postCommand` stays as no-op**

`InMemoryStateStore.postCommand` stays as a no-op for all commands including `.adjustBPM`. In the real app, `postCommand(.adjustBPM)` writes to UserDefaults and posts a Darwin notification — the *receiving* process emits the event, not the sender. Tests use `store.simulateExternalChange(.command(.adjustBPM(n)))` to simulate this, which goes through `externalChanges` and the engine's subscriber. Having `postCommand` directly mutate `bpm` would bypass the engine and create confusing dual semantics.

No code change needed — the existing no-op `postCommand` handles `.adjustBPM` via the `default` case once the enum gains the new case.

- [ ] **Step 5: Handle `.adjustBPM` in engine's `externalChanges` subscriber**

In `OneEighty/OneEightyEngine.swift`, in `startObservingSharedState()`, add the case:

```swift
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
```

- [ ] **Step 6: Add delta transport to `SharedStateStore`**

In `OneEighty/SharedStateStore.swift`, add the Darwin notification name and delta accumulation:

```swift
// In DarwinNotification enum:
static let commandAdjustBPM = "com.danielbutler.OneEighty.command.adjustBPM"
```

In `postCommand`, add the `.adjustBPM` case:

```swift
func postCommand(_ command: StateStoreCommand) {
    switch command {
    case .start:
        postDarwinNotification(DarwinNotification.commandStart)
    case .stop:
        postDarwinNotification(DarwinNotification.commandStop)
    case .adjustBPM(let delta):
        let current = defaults.integer(forKey: "pendingBPMDelta")
        defaults.set(current + delta, forKey: "pendingBPMDelta")
        postDarwinNotification(DarwinNotification.commandAdjustBPM)
    }
}
```

In `startObserving()`, add the observer callback:

```swift
let adjustBPMCallback: CFNotificationCallback = { _, observer, _, _, _ in
    guard let observer else { return }
    let instance = Unmanaged<SharedStateStore>.fromOpaque(observer).takeUnretainedValue()
    Task { @MainActor in
        instance.defaults.synchronize()
        let delta = instance.defaults.integer(forKey: "pendingBPMDelta")
        instance.defaults.set(0, forKey: "pendingBPMDelta")
        if delta != 0 {
            instance.externalChangesSubject.send(.command(.adjustBPM(delta)))
        }
    }
}

CFNotificationCenterAddObserver(center, observer,
    adjustBPMCallback,
    DarwinNotification.commandAdjustBPM as CFString,
    nil, .deliverImmediately)
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `xcodebuild test -scheme OneEighty -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:OneEightyTests/DeltaCommandTests 2>&1 | grep -E '(error:|FAILED|SUCCEEDED)'`

Expected: PASS

- [ ] **Step 8: Run full test suite to check for regressions**

Run: `xcodebuild test -scheme OneEighty -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:OneEightyTests 2>&1 | grep -E '(FAILED|SUCCEEDED)'`

Expected: PASS

- [ ] **Step 9: Commit**

```bash
git add OneEighty/StateStore.swift OneEighty/SharedStateStore.swift OneEighty/OneEightyEngine.swift OneEightyTests/InMemoryStateStore.swift OneEightyTests/DeltaCommandTests.swift
git commit -m "feat: add adjustBPM delta command to StateStore and engine"
```

---

## Task 2: StateSubscriber Protocol + Reconciliation Tests

Create the protocol with default `reconcile` and test it with a spy.

**Files:**
- Create: `OneEighty/StateSubscriber.swift`
- Create: `OneEightyTests/StateSubscriberTests.swift`

### Steps

- [ ] **Step 1: Write failing tests for StateSubscriber**

Create `OneEightyTests/StateSubscriberTests.swift`:

```swift
import XCTest
@testable import OneEighty

@MainActor
final class MockStateSubscriber: StateSubscriber {
    var confirmedState: PlaybackState?
    var pushCount: Int = 0
    var lastPushedState: PlaybackState?

    func push(_ state: PlaybackState) {
        pushCount += 1
        lastPushedState = state
    }
}

final class StateSubscriberTests: XCTestCase {

    nonisolated func testReconcileNoOpWhenConfirmedMatchesCurrent() async {
        await MainActor.run {
            let subscriber = MockStateSubscriber()
            let state = PlaybackState(bpm: 180, isPlaying: true)
            subscriber.confirmedState = state

            subscriber.reconcile(currentState: state)

            XCTAssertEqual(subscriber.pushCount, 0,
                           "Should not push when confirmed matches current")
        }
    }

    nonisolated func testReconcilePushesWhenConfirmedDiffers() async {
        await MainActor.run {
            let subscriber = MockStateSubscriber()
            subscriber.confirmedState = PlaybackState(bpm: 180, isPlaying: true)

            let currentState = PlaybackState(bpm: 185, isPlaying: true)
            subscriber.reconcile(currentState: currentState)

            XCTAssertEqual(subscriber.pushCount, 1,
                           "Should push when confirmed differs from current")
            XCTAssertEqual(subscriber.lastPushedState, currentState,
                           "Should push the current engine state")
        }
    }

    nonisolated func testReconcilePushesWhenConfirmedIsNil() async {
        await MainActor.run {
            let subscriber = MockStateSubscriber()
            subscriber.confirmedState = nil

            let currentState = PlaybackState(bpm: 180, isPlaying: true)
            subscriber.reconcile(currentState: currentState)

            XCTAssertEqual(subscriber.pushCount, 1,
                           "Should push when never confirmed (nil)")
        }
    }

    nonisolated func testReconcileDetectsIsPlayingMismatch() async {
        await MainActor.run {
            let subscriber = MockStateSubscriber()
            subscriber.confirmedState = PlaybackState(bpm: 180, isPlaying: false)

            let currentState = PlaybackState(bpm: 180, isPlaying: true)
            subscriber.reconcile(currentState: currentState)

            XCTAssertEqual(subscriber.pushCount, 1,
                           "Should push when isPlaying differs")
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme OneEighty -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:OneEightyTests/StateSubscriberTests 2>&1 | grep -E '(error:|FAILED|SUCCEEDED)'`

Expected: FAIL — `StateSubscriber` not defined

- [ ] **Step 3: Create `StateSubscriber.swift`**

Create `OneEighty/StateSubscriber.swift`:

```swift
import Foundation

@MainActor
protocol StateSubscriber: AnyObject {
    /// What the remote store last confirmed it holds.
    var confirmedState: PlaybackState? { get }

    /// Push state to the remote store.
    func push(_ state: PlaybackState)

    /// Compare confirmedState against source of truth, push if different.
    func reconcile(currentState: PlaybackState)
}

extension StateSubscriber {
    func reconcile(currentState: PlaybackState) {
        guard confirmedState != currentState else { return }
        push(currentState)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -scheme OneEighty -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:OneEightyTests/StateSubscriberTests 2>&1 | grep -E '(error:|FAILED|SUCCEEDED)'`

Expected: PASS

- [ ] **Step 5: Add `StateSubscriber.swift` to widget extension exclusion list**

In `OneEighty.xcodeproj/project.pbxproj`, add `StateSubscriber.swift` to the `membershipExceptions` array for the `OneEightyWidgetExtension` target (same block as `ActivityUpdateTracker.swift`, `IntentActivityDebouncer.swift`, etc.).

- [ ] **Step 6: Build to verify no widget extension errors**

Run: `xcodebuild build -scheme OneEighty -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath ./build 2>&1 | tail -3`

Expected: BUILD SUCCEEDED

- [ ] **Step 7: Commit**

```bash
git add OneEighty/StateSubscriber.swift OneEightyTests/StateSubscriberTests.swift OneEighty.xcodeproj/project.pbxproj
git commit -m "feat: add StateSubscriber protocol with default reconcile"
```

---

## Task 3: LiveActivityManager — Remove Dedup, Add Reconciliation

Conform LiveActivityManager to `StateSubscriber`. Remove `lastPushedState` dedup. Add reconciliation timer. Clean up `ActivityUpdateTracker`.

**Files:**
- Modify: `OneEighty/LiveActivityManager.swift`
- Modify: `OneEighty/ActivityUpdateTracker.swift`
- Create: `OneEightyTests/ReconciliationTimerTests.swift`
- Modify: `OneEightyTests/LiveActivityManagerTests.swift`
- Modify: `OneEightyTests/ActivityUpdateTrackerTests.swift`

### Steps

- [ ] **Step 1: Write failing tests for reconciliation timer**

Create `OneEightyTests/ReconciliationTimerTests.swift`:

```swift
import XCTest
@testable import OneEighty

final class ReconciliationTimerTests: XCTestCase {

    nonisolated func testReconciliationFiresAfterThrottleSettles() async {
        await MainActor.run {
            let manager = LiveActivityManager.shared
            manager.resetForTesting()

            // Push an update (creates activity via startActivity)
            manager.updateActivity(bpm: 180, isPlaying: true)
        }

        // Wait for throttle (0.3s) + reconciliation (0.5s) + margin
        try? await Task.sleep(for: .milliseconds(1000))

        await MainActor.run {
            let manager = LiveActivityManager.shared
            XCTAssertGreaterThanOrEqual(manager.reconciliationCount, 1,
                                        "Reconciliation should fire after throttle settles")
        }
    }

    nonisolated func testReconciliationCancelledByNewUpdate() async {
        await MainActor.run {
            let manager = LiveActivityManager.shared
            manager.resetForTesting()

            manager.updateActivity(bpm: 180, isPlaying: true)
        }

        // Wait past throttle but before reconciliation
        try? await Task.sleep(for: .milliseconds(400))

        await MainActor.run {
            let manager = LiveActivityManager.shared
            let countBefore = manager.reconciliationCount

            // New update should cancel pending reconciliation
            manager.updateActivity(bpm: 181, isPlaying: true)

            XCTAssertEqual(manager.reconciliationCount, countBefore,
                           "New update should cancel pending reconciliation")
        }
    }

    nonisolated func testReconciliationCancelledByEndActivity() async {
        await MainActor.run {
            let manager = LiveActivityManager.shared
            manager.resetForTesting()

            manager.updateActivity(bpm: 180, isPlaying: true)
            manager.endActivity()
        }

        // Wait for reconciliation timer — should NOT fire
        try? await Task.sleep(for: .milliseconds(1000))

        await MainActor.run {
            let manager = LiveActivityManager.shared
            XCTAssertEqual(manager.reconciliationCount, 0,
                           "Reconciliation should not fire after endActivity")
        }
    }
}
```

- [ ] **Step 2: Remove delivery confirmation tracking from `ActivityUpdateTracker`**

In `OneEighty/ActivityUpdateTracker.swift`, remove:
- `hasPendingUpdate` property
- `pendingSentTime` property
- `markUpdateSent(at:)` method
- `markUpdateConfirmed()` method
- `isPendingUpdateStale(at:timeout:)` method
- Clear those from `reset()` too

Keep: `shouldThrottle`, `recordUpdate`, `effectiveInterval`, `isApproachingBudgetLimit`, `updatesInLastHour`, `reset`.

- [ ] **Step 3: Remove delivery confirmation tests from `ActivityUpdateTrackerTests`**

In `OneEightyTests/ActivityUpdateTrackerTests.swift`, remove these tests:
- `testMarkUpdateSentSetsPending`
- `testMarkUpdateConfirmedClearsPending`
- `testIsPendingUpdateStaleAfterTimeout`
- `testIsPendingUpdateNotStaleBeforeTimeout`
- `testNoPendingUpdateIsNeverStale`
- `testResetClearsPendingUpdate`

- [ ] **Step 4: Update `LiveActivityManager` — conform to `StateSubscriber`, remove dedup, add reconciliation**

In `OneEighty/LiveActivityManager.swift`:

1. Add `StateSubscriber` conformance and properties:
   - Add `private(set) var confirmedState: PlaybackState?`
   - Add `private(set) var reconciliationCount: Int = 0`
   - Add `private var reconciliationTimer: Timer?`
   - Add `private var stateProvider: (() -> PlaybackState)?` — closure that reads the engine's current state
   - Remove `lastPushedState` property
   - Add a `setStateProvider(_ provider:)` method so the engine can wire this up in `setupSubscriptions()`

In `OneEightyEngine.setupSubscriptions()`, after the existing statePublisher subscription, add:
```swift
LiveActivityManager.shared.setStateProvider { [weak self] in
    guard let self else { return PlaybackState(bpm: 180, isPlaying: false) }
    return PlaybackState(bpm: self.bpm, isPlaying: self.isPlaying)
}
```

2. Add `push(_ state:)` method:
```swift
func push(_ state: PlaybackState) {
    guard let activity = currentActivity else { return }
    let contentState = OneEightyActivityAttributes.ContentState(bpm: state.bpm, isPlaying: state.isPlaying)
    tracker.recordUpdate()
    let count = tracker.totalUpdateCount
    let hourly = tracker.updatesInLastHour()
    logger.info("Pushing update #\(count) (hourly: \(hourly)) — bpm=\(state.bpm), isPlaying=\(state.isPlaying)")
    Task {
        await activity.update(.init(state: contentState, staleDate: nil))
        logger.info("Activity updated — id=\(activity.id)")
    }
}
```

3. Remove dedup from `pushUpdate`:
   - Remove the `lastPushedState` check and assignment
   - Remove `tracker.markUpdateSent()` call
   - Replace body with call to `push(PlaybackState(bpm: bpm, isPlaying: isPlaying))`

4. In `observeActivityUpdates`, set `confirmedState`:
```swift
for await content in activity.contentUpdates {
    let delivered = content.state
    logger.info("contentUpdates delivered — bpm=\(delivered.bpm), isPlaying=\(delivered.isPlaying)")
    confirmedState = PlaybackState(bpm: delivered.bpm, isPlaying: delivered.isPlaying)
}
```

5. Add reconciliation timer scheduling. After the throttle timer fires and pushes pending state, schedule reconciliation:
```swift
func setStateProvider(_ provider: @escaping () -> PlaybackState) {
    stateProvider = provider
}

private func scheduleReconciliation() {
    reconciliationTimer?.invalidate()
    reconciliationTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { _ in
        Task { @MainActor [weak self] in
            guard let self, self.currentActivity != nil else { return }
            self.reconciliationTimer = nil
            self.reconciliationCount += 1
            if let provider = self.stateProvider {
                self.reconcile(currentState: provider())
            }
        }
    }
}
```

Call `scheduleReconciliation()` at the end of `pushUpdate` (after `push`). Cancel reconciliation timer in three places:
- At the start of `updateActivity` (new update cancels pending reconciliation)
- In `endActivity()` (don't push to nil activity):
```swift
// Add to endActivity(), before the existing currentActivity = nil:
reconciliationTimer?.invalidate()
reconciliationTimer = nil
```
- In `resetForTesting()` (already covered by the new property cleanup)

6. Add `applicationDidBecomeActive` reconciliation trigger. Register for `UIApplication.didBecomeActiveNotification` and trigger reconciliation:
```swift
private func startObservingAppLifecycle() {
    NotificationCenter.default.addObserver(
        self,
        selector: #selector(appDidBecomeActive),
        name: UIApplication.didBecomeActiveNotification,
        object: nil
    )
}

@objc private func appDidBecomeActive() {
    Task { @MainActor in
        guard currentActivity != nil, let provider = stateProvider else { return }
        reconciliationCount += 1
        reconcile(currentState: provider())
    }
}
```

Call `startObservingAppLifecycle()` in `init()`.

7. In `resetForTesting`, clear new properties:
   - `confirmedState = nil`
   - `reconciliationCount = 0`
   - `reconciliationTimer?.invalidate(); reconciliationTimer = nil`
   - Remove `lastPushedState = nil`
   - Keep `stateProvider` (structural wiring, not test state)

8. Remove `lastPushedState` from `startActivity` too.

- [ ] **Step 5: Remove dedup tests from `LiveActivityManagerTests`**

Remove `testIdenticalConsecutiveUpdatesProduceSinglePush` and `testDifferentBPMNotSuppressedByDedup` (dedup is gone — these test removed behavior).

- [ ] **Step 6: Run all tests**

Run: `xcodebuild test -scheme OneEighty -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:OneEightyTests 2>&1 | grep -E '(FAILED|SUCCEEDED)'`

Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add OneEighty/LiveActivityManager.swift OneEighty/ActivityUpdateTracker.swift OneEightyTests/ReconciliationTimerTests.swift OneEightyTests/LiveActivityManagerTests.swift OneEightyTests/ActivityUpdateTrackerTests.swift
git commit -m "feat: LiveActivityManager reconciliation, remove dedup"
```

---

## Task 4: Intents + Debouncer — Switch to Delta Commands

BPM intents use `.adjustBPM` instead of absolute writes. Debouncer simplified.

**Files:**
- Modify: `OneEighty/OneEightyIntents.swift`
- Modify: `OneEighty/IntentActivityDebouncer.swift`
- Modify: `OneEightyTests/IntentActivityDebouncerTests.swift`
- Modify: `OneEightyTests/IntentBudgetTrackingTests.swift`

### Steps

- [ ] **Step 1: Update BPM intents to use delta commands**

In `OneEighty/OneEightyIntents.swift`, change `IncrementBPMIntent`:

```swift
@MainActor
func perform() async throws -> some IntentResult {
    let store = SharedStateStore.shared
    logger.info("IncrementBPMIntent — posting adjustBPM(+1)")
    store.postCommand(.adjustBPM(1))
    // Widget extension fallback: read the new BPM after delta is applied to UserDefaults
    // and push directly to ActivityKit (no engine running in widget extension)
    let newBPM = store.bpm + 1
    let isPlaying = store.isPlaying
    IntentActivityDebouncer.shared.submit(bpm: min(230, newBPM), isPlaying: isPlaying, priority: .normal)
    return .result()
}
```

Change `DecrementBPMIntent`:

```swift
@MainActor
func perform() async throws -> some IntentResult {
    let store = SharedStateStore.shared
    logger.info("DecrementBPMIntent — posting adjustBPM(-1)")
    store.postCommand(.adjustBPM(-1))
    // Widget extension fallback: estimate new BPM for direct ActivityKit push
    let newBPM = store.bpm - 1
    let isPlaying = store.isPlaying
    IntentActivityDebouncer.shared.submit(bpm: max(150, newBPM), isPlaying: isPlaying, priority: .normal)
    return .result()
}
```

The debouncer call serves two purposes:
1. **Widget extension (no engine):** The debouncer's fallback path pushes directly to ActivityKit so the DI/LA updates immediately.
2. **In-app (engine running):** The debouncer routes through LiveActivityManager via the update handler. The engine also receives the delta via Darwin notification and pushes through its own subscription. LiveActivityManager's reconciliation ensures they converge.

Play/stop intents stay unchanged — they keep `store.isPlaying` writes and debouncer calls.

- [ ] **Step 2: Remove dedup from `IntentActivityDebouncer`**

In `OneEighty/IntentActivityDebouncer.swift`:

- Remove `lastFlushedBPM` and `lastFlushedIsPlaying` properties
- Remove the dedup check in `push(bpm:isPlaying:)` — always forward
- Remove the corresponding lines from `resetForTesting()`

The `push` method becomes:

```swift
private func push(bpm: Int, isPlaying: Bool) {
    flushCount += 1
    logger.info("Flushing update #\(self.flushCount) — bpm=\(bpm), isPlaying=\(isPlaying)")

    if let handler = updateHandler {
        handler(bpm, isPlaying)
    } else {
        let state = OneEightyActivityAttributes.ContentState(bpm: bpm, isPlaying: isPlaying)
        Task {
            for activity in Activity<OneEightyActivityAttributes>.activities {
                await activity.update(.init(state: state, staleDate: nil))
            }
        }
    }
}
```

- [ ] **Step 3: Remove dedup tests from `IntentActivityDebouncerTests`**

Remove these tests:
- `testDuplicateStateSuppressed`
- `testDuplicateAfterBatchFlushSuppressed`
- `testDifferentBPMNotSuppressed`

Remove references to `lastFlushedBPM` and `lastFlushedIsPlaying` from `testResetClearsAllState`.

Keep all batching and critical priority tests — they test throttle behavior, not dedup.

- [ ] **Step 4: Update `IntentBudgetTrackingTests`**

Update integration tests to reflect the delta command flow. The debouncer no longer receives BPM submissions from intents for increment/decrement. Update or remove tests that assumed this path.

- [ ] **Step 5: Run all tests**

Run: `xcodebuild test -scheme OneEighty -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:OneEightyTests 2>&1 | grep -E '(FAILED|SUCCEEDED)'`

Expected: PASS

- [ ] **Step 6: Verify no absolute BPM writes in intents**

Run: `grep -n 'store\.bpm\s*=' OneEighty/OneEightyIntents.swift`

Expected: zero hits

- [ ] **Step 7: Commit**

```bash
git add OneEighty/OneEightyIntents.swift OneEighty/IntentActivityDebouncer.swift OneEightyTests/IntentActivityDebouncerTests.swift OneEightyTests/IntentBudgetTrackingTests.swift
git commit -m "feat: BPM intents use delta commands, remove debouncer dedup"
```

---

## Task 5: PhoneSessionManager — Conform to StateSubscriber

Add reply handler for confirmation. Formalize existing echo debounce as partial reconciliation.

**Files:**
- Modify: `OneEighty/PhoneSessionManager.swift`

### Steps

- [ ] **Step 1: Add `StateSubscriber` conformance to `PhoneSessionManager`**

Add `confirmedState` property and `push` method:

```swift
// Add property:
private(set) var confirmedState: PlaybackState?

// Add push method:
func push(_ state: PlaybackState) {
    sendStateToWatch()
}
```

Add protocol conformance declaration:

```swift
@MainActor
final class PhoneSessionManager: NSObject, StateSubscriber {
```

- [ ] **Step 2: Add reply handler to `sendMessage`**

In `sendStateToWatch()`, change:

```swift
// Before:
WCSession.default.sendMessage(state, replyHandler: nil) { error in

// After:
WCSession.default.sendMessage(state, replyHandler: { [weak self] reply in
    Task { @MainActor in
        if let bpm = reply["bpm"] as? Int, let isPlaying = reply["isPlaying"] as? Bool {
            self?.confirmedState = PlaybackState(bpm: bpm, isPlaying: isPlaying)
        }
    }
}) { error in
```

- [ ] **Step 3: Build and run tests**

Run: `xcodebuild test -scheme OneEighty -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:OneEightyTests 2>&1 | grep -E '(FAILED|SUCCEEDED)'`

Expected: PASS

- [ ] **Step 4: Run full verification**

```bash
# No absolute BPM writes in intents
grep -n 'store\.bpm\s*=' OneEighty/OneEightyIntents.swift

# No lastPushedState
grep -rn 'lastPushedState' OneEighty/

# No lastFlushedBPM
grep -rn 'lastFlushedBPM' OneEighty/
```

Expected: zero hits for all three

- [ ] **Step 5: Run full test suite (unit + UI)**

Run: `xcodebuild test -scheme OneEighty -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | grep -E '(FAILED|SUCCEEDED)'`

Expected: PASS (unit tests), UI tests may need simulator state reset

- [ ] **Step 6: Commit**

```bash
git add OneEighty/PhoneSessionManager.swift
git commit -m "feat: PhoneSessionManager conforms to StateSubscriber with reply handler"
```
