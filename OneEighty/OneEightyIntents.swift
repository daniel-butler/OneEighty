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
