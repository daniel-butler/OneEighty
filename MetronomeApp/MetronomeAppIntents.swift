//
//  MetronomeAppIntents.swift
//  MetronomeApp
//
//  Created by Claude on 12/23/25.
//

import ActivityKit
import AppIntents
import Foundation
import os

private let logger = Logger(subsystem: "com.danielbutler.MetronomeApp", category: "Intents")

@MainActor
final class IntentUpdateTracker {
    static let shared = IntentUpdateTracker()

    let tracker = ActivityUpdateTracker()

    private init() {}

    func recordIntentUpdate(intent: String, bpm: Int, isPlaying: Bool) {
        tracker.recordUpdate()
        logger.info("\(intent) pushed update — bpm=\(bpm), isPlaying=\(isPlaying), hourly=\(self.tracker.updatesInLastHour())")
    }

    func reset() {
        tracker.reset()
    }
}

/// Update the Live Activity directly from the widget extension process.
/// This is the only reliable way to update the UI when the app is backgrounded.
private func pushActivityUpdate(bpm: Int, isPlaying: Bool, intent: String) async {
    let state = MetronomeActivityAttributes.ContentState(bpm: bpm, isPlaying: isPlaying)
    for activity in Activity<MetronomeActivityAttributes>.activities {
        await activity.update(.init(state: state, staleDate: nil))
    }
    await IntentUpdateTracker.shared.recordIntentUpdate(intent: intent, bpm: bpm, isPlaying: isPlaying)
}

struct ToggleMetronomeIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle Metronome"
    static var description = IntentDescription("Toggles metronome playback on/off")

    @MainActor
    func perform() async throws -> some IntentResult {
        let store = SharedStateStore.shared
        let wasPlaying = store.isPlaying
        let nowPlaying = !wasPlaying
        logger.info("ToggleMetronomeIntent — wasPlaying=\(wasPlaying), nowPlaying=\(nowPlaying)")

        store.isPlaying = nowPlaying
        let bpm = store.bpm
        await pushActivityUpdate(bpm: bpm, isPlaying: nowPlaying, intent: "ToggleMetronome")

        store.postCommand(nowPlaying ? .start : .stop)
        return .result()
    }
}

struct StartMetronomeIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Metronome"
    static var description = IntentDescription("Starts the metronome playback")

    @MainActor
    func perform() async throws -> some IntentResult {
        logger.info("StartMetronomeIntent.perform()")
        let store = SharedStateStore.shared
        store.isPlaying = true
        let bpm = store.bpm
        await pushActivityUpdate(bpm: bpm, isPlaying: true, intent: "StartMetronome")
        store.postCommand(.start)
        return .result()
    }
}

struct StopMetronomeIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop Metronome"
    static var description = IntentDescription("Stops the metronome playback")

    @MainActor
    func perform() async throws -> some IntentResult {
        logger.info("StopMetronomeIntent.perform()")
        let store = SharedStateStore.shared
        store.isPlaying = false
        let bpm = store.bpm
        await pushActivityUpdate(bpm: bpm, isPlaying: false, intent: "StopMetronome")
        store.postCommand(.stop)
        return .result()
    }
}

struct IncrementBPMIntent: AppIntent {
    static var title: LocalizedStringResource = "Increment SPM"
    static var description = IntentDescription("Increases SPM by 1")

    @MainActor
    func perform() async throws -> some IntentResult {
        let store = SharedStateStore.shared
        let currentBPM = store.bpm
        logger.info("IncrementBPMIntent — current=\(currentBPM)")
        if currentBPM < 230 {
            let newBPM = currentBPM + 1
            store.bpm = newBPM
            let isPlaying = store.isPlaying
            await pushActivityUpdate(bpm: newBPM, isPlaying: isPlaying, intent: "IncrementBPM")
        }
        return .result()
    }
}

struct DecrementBPMIntent: AppIntent {
    static var title: LocalizedStringResource = "Decrement SPM"
    static var description = IntentDescription("Decreases SPM by 1")

    @MainActor
    func perform() async throws -> some IntentResult {
        let store = SharedStateStore.shared
        let currentBPM = store.bpm
        logger.info("DecrementBPMIntent — current=\(currentBPM)")
        if currentBPM > 150 {
            let newBPM = currentBPM - 1
            store.bpm = newBPM
            let isPlaying = store.isPlaying
            await pushActivityUpdate(bpm: newBPM, isPlaying: isPlaying, intent: "DecrementBPM")
        }
        return .result()
    }
}
