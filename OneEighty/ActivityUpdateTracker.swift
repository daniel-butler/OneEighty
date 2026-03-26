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

    func effectiveInterval(at date: Date = Date()) -> TimeInterval {
        let hourlyCount = updatesInLastHour(relativeTo: date)
        let ratio = Double(hourlyCount) / Double(budgetWarningThreshold)
        if ratio >= 1.0 {
            return minimumInterval * 4
        } else if ratio >= 0.75 {
            return minimumInterval * 2
        }
        return minimumInterval
    }

    func reset() {
        updateTimestamps.removeAll()
        totalUpdateCount = 0
        logger.info("Tracker reset")
    }

    private func pruneOldEntries(relativeTo date: Date) {
        let oneHourAgo = date.addingTimeInterval(-3600)
        updateTimestamps.removeAll { $0 <= oneHourAgo }
    }
}
