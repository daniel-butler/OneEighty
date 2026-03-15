# Delta Commands + Reconciliation for Live Activity Sync

## Problem

Three issues with the current live activity update architecture:

1. **Read-modify-write races across 4 surfaces.** Four surfaces can write state: App UI, Lock Screen LA, Dynamic Island, and Watch. The intents do `store.bpm = currentBPM + 1` — a read-modify-write that clobbers concurrent changes. If the DI and Watch both increment from 180, both write 181 instead of 182.

2. **No reconciliation after throttled updates.** After a burst of throttled updates, the DI/LA can show stale values permanently. Nothing verifies the final state landed. The `lastPushedState` dedup tracks what we *sent* to ActivityKit, not what was *rendered*. If the system suppressed a widget refresh, we never retry because dedup thinks the value already landed.

3. **DI and LA can diverge.** Despite sharing the same `Activity` object, the DI and LA are separate rendering surfaces refreshed independently by the system. They can show different values at the same time. Reconciliation cannot detect per-surface rendering failures — `contentUpdates` delivers one stream for the entire Activity. This spec reduces but does not fully eliminate the DI/LA divergence, which is a system-level limitation.

## Solution

Two changes that reinforce each other:

### Part 1: Delta Commands

All surfaces send delta commands instead of absolute value writes. The engine applies deltas atomically — no read-modify-write, no races.

Add `.adjustBPM(Int)` to `StateStoreCommand`:

```swift
enum StateStoreCommand {
    case start
    case stop
    case adjustBPM(Int)  // delta: +1, -1, +3, etc.
}
```

Intents change from:
```swift
// Before — absolute write, race-prone
let currentBPM = store.bpm
store.bpm = currentBPM + 1
```

To:
```swift
// After — delta command, atomic
store.postCommand(.adjustBPM(1))
```

The engine already has `adjustBPM(by:)`. The watch already sends delta commands via WatchConnectivity. This makes all 4 surfaces consistent.

**Important:** BPM intents must also **remove** the direct `store.bpm = newBPM` assignment. Only the delta command remains. The `store.bpm` property stays readable (for play/stop intents that need the current BPM for the live activity update) but BPM intents no longer write to it.

**Play/stop intents:** `store.isPlaying = value` writes remain acceptable. Play/stop is idempotent (setting `isPlaying = true` twice is the same as once), so there is no delta concern. These intents continue to call `store.postCommand(.start/.stop)` as today.

#### Delta transport via Darwin notifications

Darwin notifications cannot carry payloads. The delta is transported via UserDefaults with an accumulation pattern:

1. Intent writes: atomically add delta to `pendingBPMDelta` key in UserDefaults (read current, add, write back). Since intents are serialized on `@MainActor` within a single process, this is safe within-process.
2. Intent posts Darwin notification: `com.danielbutler.OneEighty.command.adjustBPM`
3. Engine receives notification: reads `pendingBPMDelta`, resets it to 0, calls `adjustBPM(by: delta)`.

Cross-process race (two processes posting simultaneously) is unlikely in practice — the widget extension and app don't both post BPM deltas. If it happens, the accumulated delta in UserDefaults may be stale (one process overwrites the other's increment). This is an acceptable trade-off for now; true optimistic locking (Part 3) would eliminate it.

#### IntentActivityDebouncer data flow

After this change, BPM intents no longer compute `newBPM` — they post a delta command. The debouncer no longer receives absolute BPM values from intents for BPM changes. Instead:

1. Intent posts `.adjustBPM(+1)` → engine applies delta → `statePublisher` emits new state
2. LiveActivityManager subscription picks up new state → pushes to ActivityKit (throttled)

The debouncer's BPM batching for intents becomes unnecessary — the engine-to-LiveActivityManager path handles it. The debouncer remains for play/stop intents (critical priority bypass) and as a widget extension fallback. In the widget extension (no engine running), the debouncer's fallback path reads `store.bpm` after the delta command is posted for the direct ActivityKit push.

### Part 2: StateSubscriber Protocol + Reconciliation

A shared protocol for any component that keeps a remote store in sync with the engine:

```swift
@MainActor
protocol StateSubscriber: AnyObject {
    /// What the remote store last confirmed it holds.
    /// Represents the remote store's actual state regardless of who put it there.
    var confirmedState: PlaybackState? { get }

    /// Push state to the remote store (ActivityKit, WatchConnectivity, etc.)
    func push(_ state: PlaybackState)

    /// Compare confirmedState against source of truth, push if different
    func reconcile(currentState: PlaybackState)
}

extension StateSubscriber {
    /// Default reconciliation: push if confirmed state doesn't match current engine state.
    func reconcile(currentState: PlaybackState) {
        guard confirmedState != currentState else { return }
        push(currentState)
    }
}
```

`reconcile` has a default implementation in the protocol extension. Conformers only need to implement `push` and set `confirmedState` from their remote store's confirmation channel.

Both `LiveActivityManager` and `PhoneSessionManager` conform. Each owns its own throttle/batch strategy, but the reconciliation logic is shared.

**`confirmedState` semantics:** Represents what the remote store actually holds, regardless of who put it there. For LiveActivityManager, this is set from `activity.contentUpdates`. For PhoneSessionManager, from reply handlers. If another process pushed a different value (e.g., widget extension fallback), `confirmedState` still reflects that value — reconciliation catches divergence from the engine regardless of origin.

**Reconciliation timer lifecycle:**

1. When the throttle timer fires and flushes pending state, start a one-shot reconciliation timer (500ms).
2. If a new update arrives before reconciliation fires, cancel the reconciliation timer. It will be rescheduled after the next throttle cycle.
3. When reconciliation fires, call `reconcile(currentState: statePublisher.value)`.
4. Also trigger reconciliation on `applicationDidBecomeActive` — timers may not fire while backgrounded, so this is a catch-all.
5. Cancel the reconciliation timer in `endActivity()` — don't push to a nil activity.

**Reconciliation flow:**

1. Engine state changes → subscriber pushes through throttle → `activity.update()` / `session.sendMessage()`
2. Remote store confirms → `contentUpdates` / reply handler → sets `confirmedState`
3. After burst settles (throttle timer fires + 500ms), reconciliation runs
4. Compare `confirmedState` against `statePublisher.value` (engine's current state)
5. If they differ → push `statePublisher.value` again
6. If they match → done

**What this replaces:**

- `lastPushedState` dedup in LiveActivityManager — **removed** (tracked intent, not result)
- `lastFlushedBPM/IsPlaying` dedup in IntentActivityDebouncer — **removed** (same flaw)
- `hasPendingUpdate` / `markUpdateSent` / `markUpdateConfirmed` in ActivityUpdateTracker — **removed** (replaced by reconciliation)

**What this keeps:**

- Throttle timer in LiveActivityManager (rate limiting still needed for Apple's budget)
- Batch timer in IntentActivityDebouncer (for play/stop and widget extension fallback)
- `effectiveInterval()` budget backoff in ActivityUpdateTracker
- Critical priority bypass for play/stop

### Part 3: Future Optimistic Locking

The `StateSubscriber` protocol is designed so optimistic locking can be added later by extending `PlaybackState` with a version field:

```swift
struct PlaybackState: Equatable {
    let bpm: Int
    let isPlaying: Bool
    let version: Int  // future: monotonic counter for conflict detection
}
```

Note: `OneEightyActivityAttributes.ContentState` would also need a version field if used for confirmed state comparison.

`reconcile` would then check version as well as values. The protocol doesn't change — just the comparison logic inside the default implementation.

### PhoneSessionManager Conformance

To conform to `StateSubscriber`, PhoneSessionManager needs:

- **`confirmedState`**: Set from `sendMessage` reply handlers. Currently `replyHandler: nil` — change to a reply handler that reads the state from the reply dict.
- **`push(_ state:)`**: Maps to the existing `sendStateToWatch()` call.
- **`updateApplicationContext`**: Fire-and-forget with no reply. Treated as unconfirmed — reconciliation will catch up if the watch doesn't receive it.

No watch-side changes needed — the watch already returns state in its reply handler (`WatchSessionManager` calls `replyHandler` with `bpm` and `isPlaying`).

## File Changes

| File | Change |
|------|--------|
| `StateStore.swift` | Add `.adjustBPM(Int)` to `StateStoreCommand` |
| `SharedStateStore.swift` | Add `pendingBPMDelta` UserDefaults key. Add Darwin notification for `adjustBPM`. Accumulate deltas on write, read-and-reset on receive. |
| `InMemoryStateStore.swift` | Support `.adjustBPM` command in test store |
| `OneEightyEngine.swift` | Handle `.command(.adjustBPM(delta))` in `externalChanges` subscriber |
| `OneEightyIntents.swift` | BPM intents: remove `store.bpm = newBPM`, call `store.postCommand(.adjustBPM(±1))`. Play/stop intents: keep `store.isPlaying` writes, keep `.start/.stop` commands. |
| `StateSubscriber.swift` | **New.** Protocol + default `reconcile` implementation |
| `LiveActivityManager.swift` | Conform to `StateSubscriber`. Remove `lastPushedState` dedup. Add reconciliation timer (scheduled after throttle, cancelled on new update, cancelled in `endActivity()`). `observeActivityUpdates` sets `confirmedState`. Add `applicationDidBecomeActive` reconciliation trigger. |
| `IntentActivityDebouncer.swift` | Remove `lastFlushedBPM/IsPlaying` dedup. Simplify: BPM batching no longer needed (engine path handles it). Keep for play/stop critical bypass and widget extension fallback. |
| `PhoneSessionManager.swift` | Conform to `StateSubscriber`. Add reply handler to `sendMessage`. Set `confirmedState` from reply. |
| `ActivityUpdateTracker.swift` | Remove delivery confirmation tracking (`hasPendingUpdate`, `pendingSentTime`, `markUpdateSent`, `markUpdateConfirmed`, `isPendingUpdateStale`). Keep throttle, budget, and `effectiveInterval`. |

## Testing Strategy

Testing is first-class. Every layer is tested, with the remote store boundary injectable.

### Unit Tests: Delta Commands

Test the command pipeline through `InMemoryStateStore`. All deltas are serialized on `@MainActor`, so these verify sequential application (cross-process races are a manual test):

- 4 sequential `.adjustBPM(+1)` deltas → engine.bpm == startBPM + 4 (no lost increments)
- `.adjustBPM(-1)` at lower bound (150) → clamped, no underflow
- `.adjustBPM(+1)` at upper bound (230) → clamped, no overflow
- Mixed deltas: `.adjustBPM(+3)`, `.adjustBPM(-1)` → net +2
- `SharedStateStore.postCommand(.adjustBPM(3))` writes correct `pendingBPMDelta` value and posts Darwin notification

### Unit Tests: Reconciliation

Test the `StateSubscriber` default implementation with a test spy conformer:

- confirmedState == currentState → reconcile is no-op (no push)
- confirmedState != currentState → reconcile calls push with currentState
- confirmedState is nil → reconcile calls push (never confirmed = assume stale)

### Unit Tests: Reconciliation Timer

Test LiveActivityManager's reconciliation timer lifecycle:

- Throttle timer fires → reconciliation timer scheduled at 500ms
- New update arrives during 500ms wait → reconciliation timer cancelled
- Reconciliation fires → calls reconcile with statePublisher.value
- `endActivity()` → reconciliation timer cancelled
- App becomes active → reconciliation triggered

### Unit Tests: Subscriber Protocol Conformance

Both LiveActivityManager and PhoneSessionManager tested against the same protocol contract:

- `push(_ state:)` records the push (test spy / counter)
- `confirmedState` is settable for test scenarios
- `reconcile` pushes when confirmed != current, no-ops when they match

### Integration Tests: Full Pipeline

- Engine state change → subscriber push → simulated confirmation → verify no reconciliation needed
- Engine state change → subscriber push → no confirmation (simulating system throttle) → verify reconciliation fires after 500ms
- Intent posts `.adjustBPM(+1)` → engine updates → LiveActivityManager pushes → confirm → verify activity state matches engine

### Existing Tests: Update

- `IntentActivityDebouncerTests`: Remove dedup assertions (`testDuplicateStateSuppressed`, `testDuplicateAfterBatchFlushSuppressed`). Keep batching tests.
- `LiveActivityManagerTests`: Remove `testIdenticalConsecutiveUpdatesProduceSinglePush`. Add reconciliation tests.
- `ActivityUpdateTrackerTests`: Remove `testMarkUpdateSent*`, `testMarkUpdateConfirmed*`, `testIsPendingUpdate*`. Keep throttle and budget tests.
- `IntentBudgetTrackingTests`: Update integration tests for delta command flow.

## Verification

1. All unit tests pass — delta commands, reconciliation, subscriber conformance
2. `grep -r 'store\.bpm\s*=' OneEighty/OneEightyIntents.swift` → zero hits (no absolute BPM writes from intents)
3. `grep -r 'lastPushedState' OneEighty/` → zero hits
4. `grep -r 'lastFlushedBPM' OneEighty/` → zero hits
5. Manual test: rapid +/- taps on DI while watch is connected → BPM converges correctly across all surfaces
6. Manual test: tap + 10 times on DI → after settling, DI/LA show final BPM (reconciliation works)
7. Manual test: cross-process delta accumulation — tap on DI while app is backgrounded, verify BPM increments correctly
