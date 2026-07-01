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
