//  InMemoryPlaybackStoreTests.swift
import XCTest
import Combine
@testable import OneEighty

@MainActor
final class InMemoryPlaybackStoreTests: XCTestCase {
    func testMutateBumpsVersionAndClamps() {
        let store = InMemoryPlaybackStore()
        store.mutate { $0.bpm = 999 }
        XCTAssertEqual(store.state.version, 1)
        XCTAssertEqual(store.state.bpm, 230)
    }

    func testStatePublisherEmitsCurrentThenChanges() {
        let store = InMemoryPlaybackStore()
        var seen: [Int] = []
        var bag = Set<AnyCancellable>()
        store.statePublisher.sink { seen.append($0.bpm) }.store(in: &bag)
        store.mutate { $0.bpm = 190 }
        XCTAssertEqual(seen, [180, 190])   // current value, then the change
    }
}
