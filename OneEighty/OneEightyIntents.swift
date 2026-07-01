//
//  OneEightyIntents.swift
//  OneEighty
//
//  Created by Claude on 12/23/25.
//

import AppIntents
import Foundation
import os

private let logger = Logger(subsystem: "com.danielbutler.OneEighty", category: "Intents")

struct ToggleOneEightyIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle OneEighty"
    static var description = IntentDescription("Toggles metronome playback on/off")

    @MainActor
    func perform() async throws -> some IntentResult {
        // NOTE: temporary minimal patch — this intent is not yet migrated to
        // AppGroupPlaybackStore (that's Task 12). It's routed through
        // AppGroupPlaybackStore here only to keep the target compiling after
        // IntentActivityDebouncer's deletion in Task 11.
        let sharedStore = SharedStateStore.shared
        let wasPlaying = sharedStore.isPlaying
        let nowPlaying = !wasPlaying
        logger.info("ToggleOneEightyIntent — wasPlaying=\(wasPlaying), nowPlaying=\(nowPlaying)")

        sharedStore.isPlaying = nowPlaying

        let store = AppGroupPlaybackStore.shared
        store.mutate { $0.isPlaying = nowPlaying }
        LiveActivityManager.shared.apply(store.state)

        sharedStore.postCommand(nowPlaying ? .start : .stop)
        return .result()
    }
}

struct StartOneEightyIntent: AppIntent {
    static var title: LocalizedStringResource = "Start OneEighty"
    static var description = IntentDescription("Starts the metronome playback")

    @MainActor
    func perform() async throws -> some IntentResult {
        logger.info("StartOneEightyIntent.perform()")
        // NOTE: temporary minimal patch — see ToggleOneEightyIntent. Full
        // migration to AppGroupPlaybackStore is Task 12.
        let sharedStore = SharedStateStore.shared
        sharedStore.isPlaying = true

        let store = AppGroupPlaybackStore.shared
        store.mutate { $0.isPlaying = true }
        LiveActivityManager.shared.apply(store.state)

        sharedStore.postCommand(.start)
        return .result()
    }
}

struct StopOneEightyIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop OneEighty"
    static var description = IntentDescription("Stops the metronome playback")

    @MainActor
    func perform() async throws -> some IntentResult {
        logger.info("StopOneEightyIntent.perform()")
        // NOTE: temporary minimal patch — see ToggleOneEightyIntent. Full
        // migration to AppGroupPlaybackStore is Task 12.
        let sharedStore = SharedStateStore.shared
        sharedStore.isPlaying = false

        let store = AppGroupPlaybackStore.shared
        store.mutate { $0.isPlaying = false }
        LiveActivityManager.shared.apply(store.state)

        sharedStore.postCommand(.stop)
        return .result()
    }
}

struct IncrementBPMIntent: AppIntent {
    static var title: LocalizedStringResource = "Increment SPM"
    static var description = IntentDescription("Increases SPM by 1")

    @MainActor
    func perform() async throws -> some IntentResult {
        logger.info("IncrementBPMIntent — mutating store absolutely")
        let store = AppGroupPlaybackStore.shared
        store.mutate { $0.bpm += 1 }
        LiveActivityManager.shared.apply(store.state)   // post-mutation actual value
        return .result()
    }
}

struct DecrementBPMIntent: AppIntent {
    static var title: LocalizedStringResource = "Decrement SPM"
    static var description = IntentDescription("Decreases SPM by 1")

    @MainActor
    func perform() async throws -> some IntentResult {
        logger.info("DecrementBPMIntent — mutating store absolutely")
        let store = AppGroupPlaybackStore.shared
        store.mutate { $0.bpm -= 1 }
        LiveActivityManager.shared.apply(store.state)
        return .result()
    }
}
