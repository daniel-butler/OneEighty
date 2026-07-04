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

    func testMutateMergesWithExternalDiskState() async throws {
        let (store, url) = makeStore()
        // Another process wrote newer state changing a different field.
        try JSONEncoder().encode(AppState(version: 5, bpm: 200, isPlaying: false))
            .write(to: url, options: .atomic)
        store.mutate { $0.isPlaying = true }   // our change touches a different field
        try await waitUntil { (try? self.readState(url))?.isPlaying == true }
        let disk = try readState(url)
        XCTAssertEqual(disk.bpm, 200)       // external change preserved (merged, not clobbered)
        XCTAssertTrue(disk.isPlaying)       // our change applied
        XCTAssertGreaterThan(disk.version, 5)
    }

    // MARK: - Live Activity Claim/Budget (real store, not InMemoryPlaybackStore)
    //
    // ActivityCoordinationTests exercises this contract against
    // InMemoryPlaybackStore; these mirror it against the production
    // AppGroupPlaybackStore to exercise the real `activityClaimLock` +
    // UserDefaults-backed path (deliberately separate from the file-IO
    // `ioQueue` — see the comment on `activityClaimLock`).

    func testClaimActivityPushDedupesEqualAndOlderVersionsRealStore() {
        let (store, _) = makeStore()
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(store.claimActivityPush(version: 5, at: now), "strictly newer than the unset baseline must claim")
        XCTAssertFalse(store.claimActivityPush(version: 5, at: now), "equal version must be deduped")
        XCTAssertFalse(store.claimActivityPush(version: 3, at: now), "older version must be deduped")
        XCTAssertTrue(store.claimActivityPush(version: 6, at: now), "strictly newer version must be claimed")
    }

    func testActivityPushesInLastHourPrunesOlderStampsRealStore() {
        let (store, _) = makeStore()
        let base = Date(timeIntervalSince1970: 10_000)
        XCTAssertTrue(store.claimActivityPush(version: 1, at: base))
        XCTAssertTrue(store.claimActivityPush(version: 2, at: base.addingTimeInterval(4000)))
        // The push at `base` is 4000s before this query — outside the 3600s
        // window — so only the second push should count.
        XCTAssertEqual(store.activityPushesInLastHour(at: base.addingTimeInterval(4000)), 1)
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
