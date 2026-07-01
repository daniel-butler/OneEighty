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
