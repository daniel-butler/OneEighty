//
//  StateStore.swift
//  MetronomeApp
//
//  Protocol for persisting and observing metronome state across processes.
//

import Combine

enum StateStoreCommand: Equatable {
    case start
    case stop
}

enum StoreEvent: Equatable {
    /// Another process changed a persisted value (e.g. BPM from widget).
    case stateChanged
    /// Another process issued a playback command.
    case command(StateStoreCommand)
}

@MainActor
protocol StateStore: AnyObject, Sendable {
    var bpm: Int { get set }
    var isPlaying: Bool { get set }
    var volume: Float { get set }

    /// Emits when another process changes state or issues a command.
    var externalChanges: AnyPublisher<StoreEvent, Never> { get }

    /// Posts a cross-process play or stop command.
    func postCommand(_ command: StateStoreCommand)

    /// Forces a read from the backing store (disk, app group).
    func synchronize()

    /// Tells widgets to reload their timelines.
    func notifyWidgetUpdate()
}
