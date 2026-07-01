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
