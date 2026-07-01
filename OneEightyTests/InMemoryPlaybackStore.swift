//  InMemoryPlaybackStore.swift
import Combine
@testable import OneEighty

/// In-memory PlaybackStore for tests. No files, no Darwin, no cross-process IO.
@MainActor
final class InMemoryPlaybackStore: PlaybackStore {
    private let subject: CurrentValueSubject<AppState, Never>
    var volume: Float = 0.4

    init(_ initial: AppState = .defaultState) {
        subject = CurrentValueSubject(initial)
    }

    var state: AppState { subject.value }
    var statePublisher: AnyPublisher<AppState, Never> { subject.eraseToAnyPublisher() }

    func mutate(_ transform: @escaping (inout AppState) -> Void) {
        var next = subject.value
        transform(&next)
        next.version = subject.value.version + 1
        next.clampInvariants()
        subject.send(next)
    }

    /// Simulate another process changing authoritative state (arrives as a newer version).
    func simulateExternal(_ transform: @escaping (inout AppState) -> Void) {
        mutate(transform)
    }
}
