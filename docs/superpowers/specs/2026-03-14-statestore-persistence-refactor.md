# StateStore Persistence Refactor

## Problem

`SharedMetronomeState` works but has four structural problems:

1. **Not injectable.** `MetronomeEngine` hardcodes `SharedMetronomeState.shared`. Tests leak BPM through real UserDefaults, causing flaky UI tests and fragile unit tests that depend on execution order.
2. **Split observer.** `StateChangeObserver` exists only to receive the Darwin notifications that `SharedMetronomeState` sends. Two halves of the same IPC channel live in separate classes, and `MetronomeEngine` must coordinate both.
3. **Unsafe concurrency.** `nonisolated(unsafe)` suppresses the compiler instead of proving thread safety. The `@Sendable` conformance relies on UserDefaults being thread-safe, but the compiler cannot verify this.
4. **Scattered `synchronize()` calls.** Callers must remember to force-read from disk before accessing properties. Cache coherence is the store's job, not the consumer's.

## Solution

Replace `SharedMetronomeState` and `StateChangeObserver` with a `StateStore` protocol, a production `SharedStateStore`, and a test-only `InMemoryStateStore`.

## Design

### Protocol

```swift
@MainActor
protocol StateStore: Sendable {
    var bpm: Int { get set }
    var isPlaying: Bool { get set }
    var volume: Float { get set }

    /// Emits when another process changes state (widget intent, watch command).
    var externalChanges: AnyPublisher<PlaybackState, Never> { get }

    /// Posts a cross-process play or stop command.
    func postCommand(_ command: StateStoreCommand)

    /// Forces a read from the backing store (disk, app group).
    func synchronize()

    /// Tells widgets to reload their timelines.
    func notifyWidgetUpdate()
}

enum StateStoreCommand {
    case start
    case stop
}
```

### `SharedStateStore` (production)

Replaces both `SharedMetronomeState` and `StateChangeObserver`.

- **Persistence:** UserDefaults app group (`group.com.danielbutler.MetronomeApp`). The mechanism is correct for three scalar values shared across process boundaries.
- **IPC send:** Darwin notifications posted from property setters, as today.
- **IPC receive:** Owns its own Darwin notification observers. Calls `synchronize()` internally before emitting on `externalChanges`, so consumers never manage cache coherence.
- **Concurrency:** `@MainActor` isolation throughout. Eliminates `nonisolated(unsafe)`.
- **Singleton:** `static let shared` remains for widget intents, which run in a separate process without `MetronomeEngine`.

### `InMemoryStateStore` (tests)

- Stored properties, no UserDefaults, no Darwin notifications.
- `externalChanges` backed by a `PassthroughSubject` that tests push values into to simulate external changes.
- Lives in the test target only.

### `PlaybackState` (rename)

Rename `MetronomeState` to `PlaybackState`. This struct captures the live snapshot (bpm + isPlaying) published by the Combine pipeline. The name distinguishes it from persisted state.

### Consumer Changes

**`MetronomeEngine`:**
- Accepts `StateStore` in `init` (defaults to `SharedStateStore.shared`).
- Subscribes to `store.externalChanges` instead of wiring a `StateChangeObserver`.
- Removes all `synchronize()` calls — the store handles this internally.

**Widget intents (`MetronomeAppIntents.swift`):**
- Use `SharedStateStore.shared` directly. Same pattern, renamed type.

**`MetronomeAppApp.swift`:**
- No changes beyond passing the default.

## Files

| File | Change |
|------|--------|
| `SharedMetronomeState.swift` | **Delete.** Replaced by `StateStore.swift` + `SharedStateStore.swift`. |
| `StateChangeObserver.swift` | **Delete.** Folded into `SharedStateStore`. |
| `MetronomeEngine.swift` | Inject `StateStore`. Subscribe to `externalChanges`. Remove `synchronize()` calls and `StateChangeObserver` wiring. Rename `MetronomeState` to `PlaybackState`. |
| `MetronomeAppIntents.swift` | Update type references. |
| `StateStore.swift` | **New.** Protocol + `StateStoreCommand` enum. |
| `SharedStateStore.swift` | **New.** Production implementation. |
| `InMemoryStateStore.swift` | **New.** Test target only. |
| `SharedMetronomeStateTests.swift` | **Rewrite.** Test `SharedStateStore` against protocol contract. |
| `StateChangeObserverTests.swift` | **Delete.** Covered by `SharedStateStore` tests. |
| `MetronomeNotificationTests.swift` | Update references. |
| `MetronomeEngineTests.swift` | Inject `InMemoryStateStore`. Fix test isolation. |
| `PhoneSessionManager.swift` | Update `PlaybackState` references if needed. |

## Module Rename

This refactor follows a separate module rename from `MetronomeApp` to `OneEighty`. The rename is a mechanical prerequisite and is not covered in this spec.

## Verification

1. All unit tests pass with `InMemoryStateStore` injected — no UserDefaults leakage.
2. `SharedStateStore` tests verify persistence round-trips and Darwin notification delivery.
3. Grep for `SharedMetronomeState` — zero hits in source.
4. Grep for `StateChangeObserver` — zero hits in source.
5. Grep for `nonisolated(unsafe)` in `SharedStateStore` — zero hits.
6. Grep for `synchronize()` in `MetronomeEngine` — zero hits (store handles it).
7. Widget intents build and function (manual test: toggle from Lock Screen widget).
