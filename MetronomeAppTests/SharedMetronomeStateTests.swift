//
//  SharedStateStoreTests.swift
//  MetronomeAppTests
//
//  Tests for SharedStateStore persistence and Darwin notification delivery.
//

import Combine
import XCTest
@testable import MetronomeApp

@MainActor
final class SharedStateStoreTests: XCTestCase {

    private var store: SharedStateStore!
    private var testDefaults: UserDefaults!
    private var testSuiteName: String!

    override func setUp() {
        testSuiteName = "test.SharedStateStore.\(UUID().uuidString)"
        testDefaults = UserDefaults(suiteName: testSuiteName)!
        store = SharedStateStore(userDefaults: testDefaults)
    }

    override func tearDown() {
        store = nil
        UserDefaults.standard.removePersistentDomain(forName: testSuiteName)
        testDefaults = nil
        testSuiteName = nil
    }

    // MARK: - Defaults

    func testBPMDefaultsTo180() {
        XCTAssertEqual(store.bpm, 180)
    }

    func testIsPlayingDefaultsToFalse() {
        XCTAssertFalse(store.isPlaying)
    }

    func testVolumeDefaultsTo04() {
        XCTAssertEqual(store.volume, 0.4)
    }

    // MARK: - Persistence

    func testBPMPersists() {
        store.bpm = 200
        let store2 = SharedStateStore(userDefaults: testDefaults)
        store2.synchronize()
        XCTAssertEqual(store2.bpm, 200)
    }

    func testIsPlayingPersists() {
        store.isPlaying = true
        let store2 = SharedStateStore(userDefaults: testDefaults)
        store2.synchronize()
        XCTAssertTrue(store2.isPlaying)
    }

    func testVolumePersists() {
        store.volume = 0.8
        let store2 = SharedStateStore(userDefaults: testDefaults)
        store2.synchronize()
        XCTAssertEqual(store2.volume, 0.8)
    }

    // MARK: - Command Round-Trip

    func testPostCommandStartEmitsOnExternalChanges() {
        var events: [StoreEvent] = []
        let cancellable = store.externalChanges.sink { events.append($0) }

        store.postCommand(.start)

        let expectation = expectation(description: "command delivered")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)

        let commandEvents = events.compactMap { event -> StateStoreCommand? in
            if case .command(let cmd) = event { return cmd }
            return nil
        }
        XCTAssertTrue(commandEvents.contains(.start))

        cancellable.cancel()
    }

    func testPostCommandStopEmitsOnExternalChanges() {
        var events: [StoreEvent] = []
        let cancellable = store.externalChanges.sink { events.append($0) }

        store.postCommand(.stop)

        let expectation = expectation(description: "command delivered")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)

        let commandEvents = events.compactMap { event -> StateStoreCommand? in
            if case .command(let cmd) = event { return cmd }
            return nil
        }
        XCTAssertTrue(commandEvents.contains(.stop))

        cancellable.cancel()
    }
}
