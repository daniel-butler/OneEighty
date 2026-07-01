# Versioned State + Reconciler — Design

**Date:** 2026-07-01
**Status:** Approved (design), pending implementation plan
**Scope:** Structural core + quick-win bug fixes. Robustness items are a deliberate follow-up.

## Problem

The app has no single source of truth. `bpm`/`isPlaying` live in five places
(engine, app-group `UserDefaults`, watch, Live Activity content, and the
extension's `pendingBPMDelta` + intent estimates), each authoritative at
different times. State propagates as fire-and-forget snapshots with no version,
so a stale delivery overwrites a newer value and nothing heals it. Commands are
relative and non-idempotent (`adjustBPM(±1)`, `toggle`) sent over channels that
coalesce, reorder, drop, and re-deliver. Each boundary papers over this with its
own echo-suppression timer (watch cooldown, phone debounce, intent debouncer,
Live Activity throttle), and those timers only work when deliveries land inside
the window they assumed.

This design replaces that with one versioned source of truth and a reconciler,
and folds in the highest-value quick-win fixes.

## Core insight

The delta bugs are not caused by unreliable delta transport — they are caused by
deltas existing at all. The domain is two scalars plus a volume, with no history
requirement. When commands carry **absolute target values** instead of deltas,
ordering and no-loss stop mattering:

- Reorder → highest version wins → same result.
- Duplicate delivery → applying `setBPM(187)` twice is a no-op → idempotent.
- Lost intermediate → irrelevant; only the latest absolute value matters.

A full ordered command log solves ordered, non-idempotent, no-loss event
delivery — a problem this design deletes rather than transports. Versioned
last-writer-wins state is the correct, YAGNI-clean model for small state with no
history.

## Model

One versioned value type is the single source of truth:

```swift
struct AppState: Codable, Equatable {
    var version: UInt64   // monotonic, bumped on every mutation
    var bpm: Int          // clamped 150…230
    var isPlaying: Bool   // DESIRED playback state
    var volume: Float     // 0…1
}
```

`isPlaying` is **desired** state ("the user wants sound"), not "audio is
running." The engine makes reality match desired state. This distinction retires
the "silent but isPlaying=true" class of bug.

`bpm` range stays 150…230. Defaults: `bpm 180`, `isPlaying false`, `volume 0.4`.

## Components

### StateStore protocol (refactor)

Shrinks to state + mutation + change notification. The command enum,
`StoreEvent`, and `pendingBPMDelta` are **deleted** — commands become mutations
of absolute state.

```swift
protocol StateStore {
    var state: AppState { get }
    func mutate(_ transform: (inout AppState) -> Void)   // coordinated RMW, bumps version
    var externalChanges: AnyPublisher<AppState, Never> { get }
}
```

`mutate` reads current state, applies the transform, clamps invariants (bpm
range, volume range), bumps `version`, and writes back.

### AppGroupStateStore (rewrite of SharedStateStore)

- Stores `AppState` as JSON in the app-group container.
- `mutate` wraps read-modify-write in an **`NSFileCoordinator`** block so
  `version` stays strictly monotonic under concurrent app+extension writes.
  Without coordination, two writers can stamp the same version with different
  values and corrupt the invariant. This is the one place real cross-process
  atomicity is required.
- After a successful write, posts a single Darwin notification (`…changed`)
  carrying no data — purely a "go re-read the versioned state" wake.
- Publishes `AppState` on `externalChanges` when a Darwin wake indicates another
  process changed state.

**Tradeoff considered:** uncoordinated last-writer-wins that self-heals on
reconcile is simpler but allows transient version collisions. Coordination
chosen because a corrupt version invariant defeats the design.

### OneEightyEngine (refactor to reconciler)

Stops owning `bpm`/`isPlaying` as independent truth. Still exposes `@Observable`
projections for the UI, derived from `store.state`. Core:

```swift
func reconcileAudio(to state: AppState) {
    // idempotent — safe to call any number of times
    if state.isPlaying && !audioRunning { startAudio(bpm: state.bpm) }
    else if !state.isPlaying && audioRunning { stopAudio() }
    else if audioRunning && state.bpm != currentBpm { tickScheduler.updateBPM(state.bpm) }
    setVolume(state.volume)
}
```

- **One hydration path** replaces the `setup()`/`ensureReady()` divergence: read
  `store.state`, reconcile. There is no path that starts audio without reading
  the real bpm (fixes wrong-tempo-on-wake).
- **UI actions** (`togglePlayback`, `incrementBPM`, …) call `store.mutate` with
  absolute values; the change drives `reconcileAudio`. Local edits flow through
  the same source of truth as remote ones.
- **Interruptions** set desired state + reconcile. If `startAudio` fails, the
  engine rolls desired `isPlaying` back to `false` via `mutate`, so every
  surface reflects reality.

### Version-gated projections (all surfaces)

Every consumer stores `lastAppliedVersion` and rejects any snapshot with
`version ≤ lastApplied`. This one rule deletes all four echo-suppression timers.

- **Watch (`WatchSessionManager`):** `applyState` gated by version; state
  messages carry `version`. A stale reply cannot overwrite a newer value (fixes
  sticky-BPM and double-toggle).
- **Phone (`PhoneSessionManager`):** wire up the currently-dead `reconcile` — a
  reconciliation timer + `didBecomeActive`, comparing versions — so watch drift
  self-heals.
- **Live Activity (`LiveActivityManager`):** keep budget throttling (a real OS
  constraint) but make pushes **idempotent by version**. Both the app path and
  the extension-fallback path push the same versioned state, so the duplicate
  collapses to a no-op (fixes double-push) regardless of which process is alive.
  Unify on one `ActivityUpdateTracker`; record **every** push including the
  extension fallback (fixes split-brain budget). Add the `lastSentState`
  equality guard.
- **Now Playing / widget:** projections of the same state.

### Intents (widget extension)

Each intent becomes `store.mutate { $0.bpm = clamp($0.bpm + 1) }` (absolute,
coordinated, version-bumped), then projects the **post-mutation actual value** to
the Live Activity — no `store.bpm + 1` estimate that diverges on rapid taps. The
Darwin wake lets the app reconcile audio if it is alive.

**Out of scope (pre-existing constraint):** a widget "play" cannot start audio
if the app is fully terminated. This refactor makes state consistent; it does
not change what can launch the app.

## Data flow

1. Any writer (UI action, intent, watch command handler) calls `store.mutate`
   with an absolute change.
2. `mutate` coordinates the RMW, bumps `version`, writes, posts Darwin `…changed`.
3. In-process and cross-process observers wake, re-read `AppState`, and publish
   it on `externalChanges`.
4. The engine reconciles audio to the new desired state.
5. Each projection applies the snapshot if `version > lastApplied`, else rejects.
6. Reconcilers (phone→watch, Live Activity) periodically compare their confirmed
   version against desired and re-push if behind, so any drift self-heals.

## Error handling

- **Failed audio start:** engine rolls desired `isPlaying` back to `false` via
  `mutate`; surfaces converge to reality.
- **Failed cross-process write:** `NSFileCoordinator` errors are logged; the
  writer's next `mutate` retries; reconcile re-broadcasts authoritative state.
- **Stale delivery:** rejected by the version gate; no corruption.
- **Live Activity budget pressure:** throttling stays; duplicate/idempotent
  pushes cost nothing.

## Testing strategy

The cross-process layer is currently untested (`InMemoryStateStore` bypasses
it). This design fixes that:

- **Pure reducer tests:** absolute clamping, version monotonicity.
- **Version-gate tests:** projection rejects stale, accepts newer.
- **Real `AppGroupStateStore` tests:** `mutate` monotonicity, JSON round-trip,
  concurrent-write monotonicity.
- **Reconciler tests:** introduce a small `AudioOutput` protocol seam so
  `reconcileAudio` idempotency is testable without hardware (also improves
  isolation).
- Keep integration tests, re-pointed at versioned state.

## Migration

The app has no users, so there is no migration. On launch, if no versioned state
exists, seed defaults (`version 0`, `bpm 180`, `isPlaying false`, `volume 0.4`).
No legacy-key reading. `pendingBPMDelta` and its code are deleted outright. The
`StateStore` protocol seam stays, so `InMemoryStateStore` remains the test double.

## Bugs retired

Structural core + quick wins: wrong-tempo-on-wake, sticky stale BPM on watch,
double-toggle transport mismatch, double ActivityKit push, split-brain budget
accounting, `pendingBPMDelta` RMW race, start/stop reorder, non-idempotent
command double-apply, missing watch reconciliation, intent BPM estimate
divergence, isPlaying-true-but-silent.

## Explicitly out of scope (follow-up plan)

Robustness: `AVAudioEngineConfigurationChange` handling (route changes silently
killing audio, with vacuous tests), mid-interruption `didBecomeActive`
reactivation, maintenance-timer run-loop-mode starvation, `sendStateToWatch`
early-return dropping app-context, `endActivity`→`Activity.request` race, and the
low-severity cleanup items.
