//
//  InMemoryStateStore.swift
//  MetronomeAppTests
//
//  In-memory StateStore for tests. No UserDefaults, no Darwin notifications.
//

import Combine
@testable import MetronomeApp

@MainActor
final class InMemoryStateStore: StateStore {
    var bpm: Int = 180
    var isPlaying: Bool = false
    var volume: Float = 0.4

    private let externalChangesSubject = PassthroughSubject<StoreEvent, Never>()

    var externalChanges: AnyPublisher<StoreEvent, Never> {
        externalChangesSubject.eraseToAnyPublisher()
    }

    /// Tests call this to simulate an external process changing state.
    func simulateExternalChange(_ event: StoreEvent) {
        externalChangesSubject.send(event)
    }

    func postCommand(_ command: StateStoreCommand) {
        // No-op in tests — no cross-process IPC
    }

    func synchronize() {
        // No-op in tests — no disk backing store
    }

    func notifyWidgetUpdate() {
        // No-op in tests — no WidgetKit
    }
}
