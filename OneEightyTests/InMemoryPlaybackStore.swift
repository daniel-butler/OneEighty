//  InMemoryPlaybackStore.swift
import Combine
import Foundation
@testable import OneEighty

/// In-memory PlaybackStore for tests. No files, no Darwin, no cross-process IO.
@MainActor
final class InMemoryPlaybackStore: PlaybackStore {
    private let subject: CurrentValueSubject<AppState, Never>
    var volume: Float = 0.4

    private var lastPushedVersion: UInt64 = 0
    private var pushTimestamps: [Date] = []

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

    func claimActivityPush(version: UInt64, at date: Date) -> Bool {
        guard version > lastPushedVersion else { return false }
        lastPushedVersion = version
        pushTimestamps.append(date)
        return true
    }

    func activityPushesInLastHour(at date: Date) -> Int {
        pushTimestamps.filter { $0 > date.addingTimeInterval(-3600) }.count
    }
}
