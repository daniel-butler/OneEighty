//
//  OneEightyIntents.swift
//  OneEighty
//
//  Created by Claude on 12/23/25.
//

import AppIntents
import Foundation
import os

private let logger = Logger(subsystem: "app.rekuro.OneEighty", category: "Intents")

struct ToggleOneEightyIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Toggle OneEighty"
    static var description = IntentDescription("Toggles metronome playback on/off")

    @MainActor
    func perform() async throws -> some IntentResult {
        let store = AppGroupPlaybackStore.shared
        store.mutate { $0.isPlaying.toggle() }
        logger.info("ToggleOneEightyIntent — isPlaying=\(store.state.isPlaying)")
        LiveActivityManager.shared.apply(store.state)
        return .result()
    }
}

struct StartOneEightyIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Start OneEighty"
    static var description = IntentDescription("Starts the metronome playback")

    @MainActor
    func perform() async throws -> some IntentResult {
        logger.info("StartOneEightyIntent.perform()")
        let store = AppGroupPlaybackStore.shared
        store.mutate { $0.isPlaying = true }
        LiveActivityManager.shared.apply(store.state)
        return .result()
    }
}

struct StopOneEightyIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Stop OneEighty"
    static var description = IntentDescription("Stops the metronome playback")

    @MainActor
    func perform() async throws -> some IntentResult {
        logger.info("StopOneEightyIntent.perform()")
        let store = AppGroupPlaybackStore.shared
        store.mutate { $0.isPlaying = false }
        LiveActivityManager.shared.apply(store.state)
        return .result()
    }
}

struct IncrementBPMIntent: AppIntent {
    static var title: LocalizedStringResource = "Increment SPM"
    static var description = IntentDescription("Increases SPM by 1")

    // Runs in the widget extension process when triggered from the Dynamic
    // Island/Lock Screen. ActivityKit's Activity<T> API (request, and even
    // enumerating .activities) is gated on the CALLING process's own
    // NSSupportsLiveActivities entitlement — the extension doesn't have one
    // and can't get one, so it must never touch LiveActivityManager. Mutating
    // the store is enough: the main app picks up the change via the Darwin
    // notification wake path and pushes the Live Activity update itself.
    @MainActor
    func perform() async throws -> some IntentResult {
        logger.info("IncrementBPMIntent — mutating store absolutely")
        let store = AppGroupPlaybackStore.shared
        store.mutate { $0.bpm += 1 }
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
        return .result()
    }
}
