import Foundation
import os

enum UpdatePriority {
    case critical  // play/stop — bypasses all throttling
    case normal    // BPM changes — subject to rate limiting
}

@MainActor
final class ActivityUpdateTracker {
    let minimumInterval: TimeInterval
    let budgetWarningThreshold: Int
    private(set) var updateTimestamps: [Date] = []
    /// Monotonic count of all updates recorded (not affected by window pruning).
    private(set) var totalUpdateCount: Int = 0
    private let logger = Logger(subsystem: "com.danielbutler.OneEighty", category: "UpdateTracker")

    init(minimumInterval: TimeInterval = 0.3, budgetWarningThreshold: Int = 40) {
        self.minimumInterval = minimumInterval
        self.budgetWarningThreshold = budgetWarningThreshold
    }

    func shouldThrottle(priority: UpdatePriority, at date: Date = Date()) -> Bool {
        if priority == .critical { return false }
        guard let lastUpdate = updateTimestamps.last else { return false }
        return date.timeIntervalSince(lastUpdate) < minimumInterval
    }

    func recordUpdate(at date: Date = Date()) {
        totalUpdateCount += 1
        updateTimestamps.append(date)
        pruneOldEntries(relativeTo: date)

        let hourlyCount = updatesInLastHour(relativeTo: date)
        if isApproachingBudgetLimit(at: date) {
            logger.warning("High update rate: \(hourlyCount) updates in last hour (threshold: \(self.budgetWarningThreshold))")
        } else {
            logger.info("Update #\(self.totalUpdateCount) recorded. \(hourlyCount) in last hour.")
        }
    }

    func isApproachingBudgetLimit(at date: Date = Date()) -> Bool {
        updatesInLastHour(relativeTo: date) >= budgetWarningThreshold
    }

    func updatesInLastHour(relativeTo date: Date = Date()) -> Int {
        let oneHourAgo = date.addingTimeInterval(-3600)
        return updateTimestamps.filter { $0 > oneHourAgo }.count
    }

    // MARK: - Delivery confirmation tracking

    private(set) var hasPendingUpdate: Bool = false
    private(set) var pendingSentTime: Date?

    func markUpdateSent(at date: Date = Date()) {
        hasPendingUpdate = true
        pendingSentTime = date
    }

    func markUpdateConfirmed() {
        hasPendingUpdate = false
        pendingSentTime = nil
    }

    func isPendingUpdateStale(at date: Date = Date(), timeout: TimeInterval = 2.0) -> Bool {
        guard hasPendingUpdate, let sentTime = pendingSentTime else { return false }
        return date.timeIntervalSince(sentTime) > timeout
    }

    func reset() {
        updateTimestamps.removeAll()
        totalUpdateCount = 0
        hasPendingUpdate = false
        pendingSentTime = nil
        logger.info("Tracker reset")
    }

    private func pruneOldEntries(relativeTo date: Date) {
        let oneHourAgo = date.addingTimeInterval(-3600)
        updateTimestamps.removeAll { $0 <= oneHourAgo }
    }
}
