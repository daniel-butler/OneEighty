//
//  SharedStateStore.swift
//  MetronomeApp
//
//  Production StateStore backed by UserDefaults app group and Darwin notifications.
//  Replaces SharedMetronomeState and StateChangeObserver.
//

import Combine
import os

#if canImport(WidgetKit)
import WidgetKit
#endif

private let logger = Logger(subsystem: "com.danielbutler.MetronomeApp", category: "SharedStateStore")

private enum DarwinNotification {
    static let stateChanged = "com.danielbutler.MetronomeApp.stateChanged"
    static let commandStart = "com.danielbutler.MetronomeApp.command.start"
    static let commandStop = "com.danielbutler.MetronomeApp.command.stop"
}

@MainActor
final class SharedStateStore: StateStore {
    static let shared = SharedStateStore()

    private nonisolated let defaults: UserDefaults

    private nonisolated var observerPointer: UnsafeMutableRawPointer {
        Unmanaged.passUnretained(self).toOpaque()
    }

    private let externalChangesSubject = PassthroughSubject<StoreEvent, Never>()

    var externalChanges: AnyPublisher<StoreEvent, Never> {
        externalChangesSubject.eraseToAnyPublisher()
    }

    var bpm: Int {
        get { defaults.object(forKey: "bpm") as? Int ?? 180 }
        set {
            defaults.set(newValue, forKey: "bpm")
            logger.info("SharedStateStore.bpm SET \(newValue)")
            postDarwinNotification(DarwinNotification.stateChanged)
        }
    }

    var isPlaying: Bool {
        get { defaults.object(forKey: "isPlaying") as? Bool ?? false }
        set {
            defaults.set(newValue, forKey: "isPlaying")
            logger.info("SharedStateStore.isPlaying SET \(newValue)")
        }
    }

    var volume: Float {
        get { defaults.object(forKey: "volume") as? Float ?? 0.4 }
        set {
            defaults.set(newValue, forKey: "volume")
        }
    }

    private init() {
        defaults = UserDefaults(suiteName: "group.com.danielbutler.MetronomeApp") ?? .standard
        startObserving()
    }

    init(userDefaults: UserDefaults) {
        defaults = userDefaults
        startObserving()
    }

    func synchronize() {
        defaults.synchronize()
    }

    func postCommand(_ command: StateStoreCommand) {
        switch command {
        case .start:
            postDarwinNotification(DarwinNotification.commandStart)
        case .stop:
            postDarwinNotification(DarwinNotification.commandStop)
        }
    }

    func notifyWidgetUpdate() {
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    // MARK: - Darwin Notifications (Send)

    private nonisolated func postDarwinNotification(_ name: String) {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(center, CFNotificationName(name as CFString), nil, nil, true)
        logger.info("Posted Darwin notification: \(name)")
    }

    // MARK: - Darwin Notifications (Receive)

    private func startObserving() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = observerPointer

        let stateCallback: CFNotificationCallback = { _, observer, _, _, _ in
            guard let observer else { return }
            let instance = Unmanaged<SharedStateStore>.fromOpaque(observer).takeUnretainedValue()
            Task { @MainActor in
                instance.defaults.synchronize()
                instance.externalChangesSubject.send(.stateChanged)
            }
        }

        let startCallback: CFNotificationCallback = { _, observer, _, _, _ in
            guard let observer else { return }
            let instance = Unmanaged<SharedStateStore>.fromOpaque(observer).takeUnretainedValue()
            Task { @MainActor in
                instance.externalChangesSubject.send(.command(.start))
            }
        }

        let stopCallback: CFNotificationCallback = { _, observer, _, _, _ in
            guard let observer else { return }
            let instance = Unmanaged<SharedStateStore>.fromOpaque(observer).takeUnretainedValue()
            Task { @MainActor in
                instance.externalChangesSubject.send(.command(.stop))
            }
        }

        CFNotificationCenterAddObserver(center, observer,
            stateCallback,
            DarwinNotification.stateChanged as CFString,
            nil, .deliverImmediately)

        CFNotificationCenterAddObserver(center, observer,
            startCallback,
            DarwinNotification.commandStart as CFString,
            nil, .deliverImmediately)

        CFNotificationCenterAddObserver(center, observer,
            stopCallback,
            DarwinNotification.commandStop as CFString,
            nil, .deliverImmediately)
    }

    deinit {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterRemoveEveryObserver(center, observerPointer)
    }
}
