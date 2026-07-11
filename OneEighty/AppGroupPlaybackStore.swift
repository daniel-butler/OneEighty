//  AppGroupPlaybackStore.swift
import Combine
import Foundation
import os

private let logger = Logger(subsystem: "app.rekuro.OneEighty", category: "PlaybackStore")

private enum DarwinName {
    static let changed = "app.rekuro.OneEighty.state.changed"
}

@MainActor
final class AppGroupPlaybackStore: PlaybackStore {
    static let shared = AppGroupPlaybackStore()

    private let subject: CurrentValueSubject<AppState, Never>
    var statePublisher: AnyPublisher<AppState, Never> { subject.eraseToAnyPublisher() }
    var state: AppState { subject.value }

    private nonisolated let fileURL: URL
    private nonisolated let defaults: UserDefaults
    private nonisolated let ioQueue = DispatchQueue(label: "app.rekuro.OneEighty.store.io")

    /// Dedicated synchronization for the Live Activity claim/budget state ONLY.
    /// Deliberately NOT `ioQueue`: the claim methods are called from `@MainActor`
    /// (`LiveActivityManager.apply`) on every state change, and `ioQueue` runs the
    /// coordinated cross-process file writes in `mutate`. Sharing it would block
    /// the main thread behind coordinated file IO — the exact priority inversion
    /// the off-main design avoids. This lock guards only the small, fast
    /// defaults-backed claim state, so main-actor callers never wait on file IO.
    private nonisolated let activityClaimLock = OSAllocatedUnfairLock()

    var volume: Float {
        get { defaults.object(forKey: "volume") as? Float ?? 0.4 }
        set { defaults.set(newValue, forKey: "volume") }
    }

    private nonisolated var observerPointer: UnsafeMutableRawPointer {
        Unmanaged.passUnretained(self).toOpaque()
    }

    convenience init() {
        let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: "group.app.rekuro.OneEighty")
        let url = (container ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("state.json")
        let defaults = UserDefaults(suiteName: "group.app.rekuro.OneEighty") ?? .standard
        self.init(fileURL: url, defaults: defaults)
    }

    init(fileURL: URL, defaults: UserDefaults) {
        self.fileURL = fileURL
        self.defaults = defaults
        // Seed the projection from disk (or default) synchronously at init.
        let seed = Self.readFromDisk(fileURL) ?? .defaultState
        subject = CurrentValueSubject(seed)
        startObserving()
    }

    func mutate(_ transform: @escaping (inout AppState) -> Void) {
        // 1. Optimistic main-actor projection for instant UI.
        var optimistic = subject.value
        transform(&optimistic)
        optimistic.version = subject.value.version + 1
        optimistic.clampInvariants()
        logger.info("publish optimistic v\(optimistic.version) bpm=\(optimistic.bpm) isPlaying=\(optimistic.isPlaying)")
        subject.send(optimistic)

        // 2. Authoritative coordinated write off the main actor.
        let url = fileURL
        ioQueue.async {
            var authoritative = AppState.defaultState
            let coordinator = NSFileCoordinator()
            var coordError: NSError?
            coordinator.coordinate(writingItemAt: url, options: [], error: &coordError) { writeURL in
                var current = Self.readFromDisk(writeURL) ?? .defaultState
                transform(&current)
                current.version += 1
                current.clampInvariants()
                do {
                    let data = try JSONEncoder().encode(current)
                    try data.write(to: writeURL, options: .atomic)
                } catch {
                    // The projection + Darwin post still proceed below; log so a
                    // silently-dropped authoritative write is diagnosable.
                    logger.error("coordinated write failed to encode/persist state: \(error.localizedDescription)")
                }
                authoritative = current
            }
            if let coordError { logger.error("coordinate write failed: \(coordError.localizedDescription)") }
            Self.postDarwin()
            Task { @MainActor [weak self] in self?.adoptAuthoritative(authoritative) }
        }
    }

    /// Update the projection to an authoritative value if it is newer.
    private func adoptAuthoritative(_ authoritative: AppState) {
        let projectionVersion = subject.value.version
        if authoritative.version >= projectionVersion, authoritative != subject.value {
            logger.info("publish authoritative v\(authoritative.version) bpm=\(authoritative.bpm) isPlaying=\(authoritative.isPlaying) (projection was v\(projectionVersion))")
            subject.send(authoritative)
        } else {
            logger.info("authoritative v\(authoritative.version) dropped — not newer than projection v\(projectionVersion)")
        }
    }

    // MARK: - Disk

    private nonisolated static func readFromDisk(_ url: URL) -> AppState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AppState.self, from: data)
    }

    // MARK: - Darwin

    private nonisolated static func postDarwin() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(center, CFNotificationName(DarwinName.changed as CFString), nil, nil, true)
    }

    private func startObserving() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let callback: CFNotificationCallback = { _, observer, _, _, _ in
            guard let observer else { return }
            let instance = Unmanaged<AppGroupPlaybackStore>.fromOpaque(observer).takeUnretainedValue()
            instance.handleExternalWake()
        }
        CFNotificationCenterAddObserver(center, observerPointer, callback,
            DarwinName.changed as CFString, nil, .deliverImmediately)
    }

    /// Darwin wake: re-read the file off-main, adopt if newer. Coalesced self-wakes are harmless.
    nonisolated func handleExternalWake() {
        let url = fileURL
        ioQueue.async {
            var latest: AppState?
            let coordinator = NSFileCoordinator()
            coordinator.coordinate(readingItemAt: url, options: [], error: nil) { readURL in
                latest = Self.readFromDisk(readURL)
            }
            if let latest {
                Task { @MainActor [weak self] in self?.adoptAuthoritative(latest) }
            }
        }
    }

    deinit {
        CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(), observerPointer)
    }

    // MARK: - Live Activity coordination

    func claimActivityPush(version: UInt64, at date: Date) -> Bool {
        activityClaimLock.withLock {
            let last = UInt64(defaults.integer(forKey: "lastPushedActivityVersion"))
            guard version > last else { return false }
            // `Int(exactly:)` avoids a trap if `version` ever exceeds Int.max.
            defaults.set(Int(exactly: version) ?? Int.max, forKey: "lastPushedActivityVersion")
            var stamps = (defaults.array(forKey: "activityPushStamps") as? [Double]) ?? []
            stamps.append(date.timeIntervalSince1970)
            stamps = stamps.filter { $0 > date.timeIntervalSince1970 - 3600 }
            defaults.set(stamps, forKey: "activityPushStamps")
            return true
        }
    }

    func activityPushesInLastHour(at date: Date) -> Int {
        activityClaimLock.withLock {
            let stamps = (defaults.array(forKey: "activityPushStamps") as? [Double]) ?? []
            return stamps.filter { $0 > date.timeIntervalSince1970 - 3600 }.count
        }
    }
}
