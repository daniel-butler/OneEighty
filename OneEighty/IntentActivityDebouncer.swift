import ActivityKit
import Foundation
import os

private let logger = Logger(subsystem: "com.danielbutler.OneEighty", category: "IntentDebouncer")

@MainActor
final class IntentActivityDebouncer {
    static let shared = IntentActivityDebouncer()

    let batchInterval: TimeInterval
    private(set) var flushCount: Int = 0

    private var batchTimer: Timer?
    private var pendingBPM: Int?
    private var pendingIsPlaying: Bool?

    /// Pluggable sink for activity updates. In-app this is wired to LiveActivityManager;
    /// in the widget extension it falls back to a direct ActivityKit push.
    private var updateHandler: ((Int, Bool) -> Void)?

    var hasPending: Bool { pendingBPM != nil }

    private init() {
        self.batchInterval = 0.1
    }

    /// Wire the debouncer to route flushes through LiveActivityManager (called once at app launch).
    func setUpdateHandler(_ handler: @escaping (Int, Bool) -> Void) {
        updateHandler = handler
    }

    func submit(bpm: Int, isPlaying: Bool, priority: UpdatePriority) {
        if priority == .critical {
            flushPending()
            push(bpm: bpm, isPlaying: isPlaying)
            return
        }

        pendingBPM = bpm
        pendingIsPlaying = isPlaying
        batchTimer?.invalidate()
        batchTimer = Timer.scheduledTimer(withTimeInterval: batchInterval, repeats: false) { _ in
            Task { @MainActor [weak self] in
                self?.flushPending()
            }
        }
    }

    private func flushPending() {
        batchTimer?.invalidate()
        batchTimer = nil
        guard let bpm = pendingBPM, let isPlaying = pendingIsPlaying else { return }
        pendingBPM = nil
        pendingIsPlaying = nil
        push(bpm: bpm, isPlaying: isPlaying)
    }

    private func push(bpm: Int, isPlaying: Bool) {
        flushCount += 1
        logger.info("Flushing update #\(self.flushCount) — bpm=\(bpm), isPlaying=\(isPlaying)")

        if let handler = updateHandler {
            handler(bpm, isPlaying)
        } else {
            // Fallback: direct ActivityKit push (widget extension, no LiveActivityManager)
            let state = OneEightyActivityAttributes.ContentState(bpm: bpm, isPlaying: isPlaying)
            Task {
                for activity in Activity<OneEightyActivityAttributes>.activities {
                    await activity.update(.init(state: state, staleDate: nil))
                }
            }
        }
    }

    func resetForTesting() {
        batchTimer?.invalidate()
        batchTimer = nil
        pendingBPM = nil
        pendingIsPlaying = nil
        flushCount = 0
        // Note: updateHandler is structural wiring, not test state — don't clear it
    }
}
