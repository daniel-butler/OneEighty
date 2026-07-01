# Versioned State + Reconciler — Design

**Date:** 2026-07-01
**Status:** Approved (design), pending implementation plan
**Scope:** Structural core + quick-win bug fixes. Robustness items are a deliberate follow-up.
**Revision:** v3 — reworked after a cold design review. Changes: volume removed from
versioned state; watch redesigned around in-flight-command tracking (not version-gating);
mutation threading contract specified; Live Activity budget/dedupe made cross-process;
staged rollout with the watch last; play/stop/toggle intents conform to
`AudioPlaybackIntent` so widget playback starts audio even when the app is suspended.

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

## Core insight (and its scope)

The delta bugs are not caused by unreliable delta transport — they are caused by
deltas existing at all, *for writers that can read authoritative state before
writing*. For those writers (the main app and the widget/AppIntent extension,
both of which read the app-group store), absolute target values make ordering and
no-loss irrelevant:

- Reorder → highest version wins → same result.
- Duplicate delivery → applying `setBPM(187)` twice is a no-op → idempotent.
- Lost intermediate → irrelevant; only the latest absolute value matters.

**This scope matters.** The watch is *not* a store reader — it edits a possibly
stale cached copy and has no version authority. Absolute commands from a stale
watch cache would *clobber* newer authoritative state (a regression deltas did
not have). So the watch keeps relative/toggle commands, and the phone applies
them to authoritative state (see "Watch"). "Delete deltas" applies to the two
store-backed writers only.

A full ordered command log solves ordered, non-idempotent, no-loss event
delivery — a problem this design deletes rather than transports, for the store
writers. Versioned last-writer-wins is the correct, YAGNI-clean model for small
shared state with no history.

## Model

One versioned value type is the single source of truth for **shared** state:

```swift
struct AppState: Codable, Equatable {
    var version: UInt64   // monotonic, bumped on every mutation
    var bpm: Int          // clamped 150…230
    var isPlaying: Bool   // DESIRED playback state
}
```

`isPlaying` is **desired** state ("the user wants sound"), not "audio is
running." The engine makes reality match desired state *when the app process is
running* (see "Reconciler" for the honest limits).

**Volume is deliberately NOT in `AppState`.** It is app-local audio config that
no other surface displays, and the volume slider fires tens of writes/second.
Putting it in the versioned/coordinated/Darwin path would cause main-thread jank
and inflate `version` for a field nothing cross-surface consumes. Volume is
persisted in its own app-group key with no version bump and no Darwin post, read
only by the engine.

Defaults: `bpm 180`, `isPlaying false`, `volume 0.4`.

## Components

### StateStore protocol (refactor)

Shrinks to state + mutation + change notification. The command enum,
`StoreEvent`, and `pendingBPMDelta` are **deleted** — store-writer commands
become mutations of absolute state.

```swift
protocol StateStore {
    var state: AppState { get }                          // in-memory projection, sync, main-actor
    func mutate(_ transform: @escaping (inout AppState) -> Void)  // async coordinated RMW
    var externalChanges: AnyPublisher<AppState, Never> { get }
    var volume: Float { get set }                        // app-local, uncoordinated
}
```

`mutate` reads current state, applies the transform, clamps invariants (bpm
range), bumps `version`, and writes back. The closure form gives per-field merge
for free: because it runs *inside* the coordinated RMW against the freshest
struct, two store writers changing different fields (app toggles `isPlaying`
while the extension changes `bpm`) never clobber each other. No per-field version
or CRDT needed for the store writers.

### AppGroupStateStore (rewrite of SharedStateStore)

- Stores `AppState` as JSON in the app-group container.
- **Threading contract:** the coordinated read-modify-write runs **off the main
  actor** (a dedicated serial executor) using `NSFileCoordinator`, so a
  foreground main-thread call never blocks on file coordination held by a
  lower-QoS extension (avoids priority inversion). Results publish back to the
  main actor.
- **In-memory projection:** the store holds a main-actor `@Observable` copy of
  the latest known `AppState`. `state` reads this synchronously (UI never touches
  disk). A local `mutate` updates the projection **optimistically** for instant
  UI, then performs the coordinated write; the authoritative result reconciles
  the projection if it differs.
- After a successful write, posts a single dataless Darwin notification
  (`…changed`) — purely a "go re-read the versioned state" wake. Coalescing is a
  feature: N posts collapse to one re-read that yields the latest value.
- **Self-notification:** the posting process also receives the Darwin wake. The
  version gate makes re-reading harmless (nothing re-applies), and self-wakes are
  coalesced. The optimistic projection means UI does not wait for the round-trip.
- Publishes `AppState` on `externalChanges` when a wake indicates another process
  changed state.
- **Live Activity coordination fields:** the store also persists
  `lastPushedActivityVersion` and a small ring of push timestamps, RMW'd by
  whichever process pushes the Live Activity (see "Live Activity").

**Tradeoff considered:** uncoordinated last-writer-wins that self-heals on
reconcile is simpler but allows transient version collisions (two writers stamp
the same version with different values), which corrupts monotonicity. Coordinated
off-main RMW chosen because the version invariant is load-bearing. With volume
removed, write frequency is human-speed (toggles, bpm taps/crown bursts), so the
coordination cost is negligible.

### OneEightyEngine (refactor to reconciler)

Stops owning `bpm`/`isPlaying` as independent truth. Still exposes `@Observable`
projections for the UI, derived from `store.state`. Core:

```swift
func reconcileAudio(to state: AppState) {
    // idempotent — safe to call any number of times
    if state.isPlaying && !audioRunning { startAudio(bpm: state.bpm) }
    else if !state.isPlaying && audioRunning { stopAudio() }
    else if audioRunning && state.bpm != currentBpm { tickScheduler.updateBPM(state.bpm) }
}
// volume applied separately from store.volume, not from AppState
```

- **One hydration path** replaces the `setup()`/`ensureReady()` divergence: read
  `store.state`, reconcile. There is no path that starts audio without reading
  the real bpm (fixes wrong-tempo-on-wake).
- **UI actions** (`togglePlayback`, `incrementBPM`, …) call `store.mutate` with
  absolute values; the change drives `reconcileAudio`. Local edits flow through
  the same source of truth as remote ones.
- **Interruptions** set desired state + reconcile. If `startAudio` fails, the
  engine rolls desired `isPlaying` back to `false` via `mutate`, so surfaces
  reflect reality.

**Suspended-app playback:** audio only runs in the app process, and a bare Darwin
wake does **not** resume a suspended app. To make widget/Live-Activity "play"
actually produce sound, the play/stop/toggle intents conform to
`AudioPlaybackIntent` (see "Intents"). The system runs those intents **in the app
process**, launching/resuming it into an audio-producing state, so the reconciler
is alive to start audio. Thus the "isPlaying-true-but-silent" divergence is
retired including the suspended-play path. (A bpm-only change from the extension
while stopped does not — and need not — wake audio; it is pure state that the app
reconciles on next run.)

### Watch (WatchSessionManager + PhoneSessionManager) — redesigned

The watch is a remote control with optimistic UI and **no version authority**.
It does not read the app-group store. Design:

- **Commands stay relative/toggle**, each tagged with a monotonically increasing
  **client command-id**. The phone applies them to *authoritative* state via
  `store.mutate` (deltas resolve against truth, so no stale-cache clobber) and
  **dedupes by command-id** so a `transferUserInfo` retry cannot double-apply.
- **Watch UI is optimistic**, gated by **in-flight-command tracking, not
  version.** While ≥1 command is outstanding (sent, not yet acked/failed), the
  watch ignores incoming authoritative values for the fields it is editing. When
  the in-flight count returns to zero (all acked or all timed-out/failed), the
  watch **snaps to the latest authoritative state** it has received. On command
  failure/timeout it reverts the optimistic value and accepts authoritative.
- This dissolves the gate-vs-heal contradiction: "apply when quiescent" always
  takes the latest authoritative state regardless of any version comparison
  against the optimistic value, so a lost optimistic edit self-heals.
- **Authoritative pushes carry `version`** (WCSession messages *and replies* — net
  new plumbing on both sides; today's reply is `{bpm, isPlaying}` with no version
  and `sendStateToWatch` early-returns when the watch app isn't installed). The
  watch keeps the highest-version authoritative snapshot seen and applies that
  when quiescent; `version` orders authoritative pushes among themselves.
- **Phone reconciliation:** wire up the currently-dead `StateSubscriber.reconcile`
  with a timer + `didBecomeActive`, pushing authoritative state so the watch
  re-syncs after any drop.

### Live Activity (LiveActivityManager) — cross-process correct

- Keep budget throttling (a real ActivityKit OS constraint), but move the shared
  accounting into the store: `lastPushedActivityVersion` and push timestamps live
  in the coordinated app-group store, RMW'd by whichever process pushes.
- **Idempotent by version, cross-process:** before pushing, a process RMW-checks
  `lastPushedActivityVersion`; if it is `>=` the version it would push, it skips.
  So the app path and the extension-fallback path pushing the same versioned
  state collapse to exactly one `activity.update` even though they don't share
  memory (fixes double-push and split-brain budget — the failing cases were
  cross-process, which in-memory dedupe could not fix).
- Keep the `lastSentState` equality guard as a cheap in-process short-circuit.

### Now Playing / widget

Projections of the same versioned state.

### Intents

Two categories, by whether they start/stop audio:

- **Play / Stop / Toggle** conform to **`AudioPlaybackIntent`**. The system runs
  these **in the app process**, resuming the app into an audio-producing state.
  They call `store.mutate { $0.isPlaying = … }`; the engine reconciler (now alive)
  starts/stops audio. This is what makes widget playback work while suspended.
- **Increment / Decrement BPM** run in the widget extension. Each becomes
  `store.mutate { $0.bpm = clamp($0.bpm + 1) }` (absolute, coordinated,
  version-bumped), then projects the **post-mutation actual value** to the Live
  Activity via the cross-process dedupe path — no `store.bpm + 1` estimate that
  diverges on rapid taps. If the app is running (background audio while playing),
  the Darwin wake makes it reconcile the new tempo.

**Requirements:** the app already declares the background audio mode (metronome
playback). `AudioPlaybackIntent` conformance plus that entitlement lets the play
intents start the session from the background. Background audio *start* is
device-only behavior for testing (the simulator does not faithfully reproduce it).

## Data flow

1. A store writer (UI action, intent) calls `store.mutate` with an absolute
   change; the watch instead sends a relative/toggle command with a command-id.
2. `mutate` updates the in-memory projection optimistically (UI is instant), then
   coordinates the off-main RMW, bumps `version`, writes, posts dataless Darwin.
   The phone's watch-command handler routes watch commands through `mutate` too.
3. In-process and cross-process observers wake, re-read `AppState`, publish it.
4. The engine reconciles audio to the new desired state (when running).
5. Store-reader projections apply snapshots if `version > lastApplied`. The watch
   applies the latest authoritative snapshot when it has no in-flight command.
6. Reconcilers (phone→watch, Live Activity) re-push authoritative state so drift
   self-heals; the Live Activity push dedupes on `lastPushedActivityVersion`.

## Error handling

- **Failed audio start:** engine rolls desired `isPlaying` back to `false`.
- **Failed cross-process write:** `NSFileCoordinator` errors are logged; the next
  `mutate` retries; reconcile re-broadcasts authoritative state.
- **Stale delivery (store readers):** rejected by the version gate.
- **Lost/duplicated watch command:** command-id dedupe prevents double-apply;
  in-flight tracking + snap-when-quiescent heals a lost optimistic edit.
- **Live Activity budget pressure:** throttling stays; cross-process dedupe means
  duplicate pushes cost nothing.

## Testing strategy

The cross-process layer is currently untested (`InMemoryStateStore` bypasses it).

- **Pure reducer tests:** absolute clamping, version monotonicity.
- **Version-gate tests:** store-reader projection rejects stale, accepts newer.
- **Real `AppGroupStateStore` tests:** `mutate` monotonicity, JSON round-trip,
  concurrent-write monotonicity, off-main threading, self-wake coalescing.
- **Watch protocol tests:** command-id dedupe on retry; optimistic value held
  while in-flight; snap-to-authoritative when quiescent; lost-edit self-heal.
- **Live Activity dedupe tests:** two simulated processes pushing the same
  version produce one update; budget timestamps shared via the store.
- **Reconciler tests:** introduce a small `AudioOutput` protocol seam so
  `reconcileAudio` idempotency is testable without hardware (also improves
  isolation).
- **Intent tests:** play/stop/toggle intents mutate desired state and invoke the
  reconciler; bpm intents produce absolute mutations. Background-audio *start*
  from a suspended app is verified manually on device (simulator is unreliable).

## Migration

The app has no users, so there is no migration. On launch, if no versioned state
exists, seed defaults (`version 0`, `bpm 180`, `isPlaying false`); volume defaults
to `0.4` in its own key. No legacy-key reading. `pendingBPMDelta` and its code are
deleted outright. The `StateStore` protocol seam stays, so `InMemoryStateStore`
remains the test double.

## Staged rollout (integration risk, not migration risk)

This touches three processes and a WCSession link CI can't exercise well, so it
is staged rather than big-bang:

1. **Store foundation:** `AppState` + versioned `AppGroupStateStore` (off-main
   coordinated RMW, in-memory projection) behind the existing `StateStore`
   protocol, with an adapter and the pure/round-trip/concurrency tests. Volume
   split into its own key.
2. **Engine → reconciler:** single hydration path, `reconcileAudio`, roll-back on
   failure. Now-Playing and Live Activity (single-process behavior) follow.
3. **Live Activity + intents cross-process:** store-persisted dedupe/budget;
   bpm intents to absolute mutations; play/stop/toggle intents conform to
   `AudioPlaybackIntent` (verify background audio start on device).
4. **Watch last:** command-id + in-flight tracking + versioned WCSession
   payloads + phone reconcile. Isolated so a watch bug is not confused with a
   store bug.

## Bugs retired

Structural core + quick wins: wrong-tempo-on-wake, sticky stale BPM on watch,
double-toggle transport mismatch, double ActivityKit push, split-brain budget
accounting, `pendingBPMDelta` RMW race, start/stop reorder, non-idempotent
command double-apply, missing watch reconciliation, intent BPM estimate
divergence, isPlaying-true-but-silent (including widget-initiated play while the
app is suspended, via `AudioPlaybackIntent`).

## Explicitly out of scope (follow-up plan)

Robustness: `AVAudioEngineConfigurationChange` handling (route changes silently
killing audio, with vacuous tests), mid-interruption `didBecomeActive`
reactivation, maintenance-timer run-loop-mode starvation, `sendStateToWatch`
early-return dropping app-context, `endActivity`→`Activity.request` race, and the
low-severity cleanup items.
