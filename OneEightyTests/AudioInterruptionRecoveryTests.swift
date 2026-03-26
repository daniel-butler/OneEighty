//
//  AudioInterruptionRecoveryTests.swift
//  OneEightyTests
//
//  Tests for audio interruption recovery based on Apple's documentation:
//  - AVAudioSession interruption handling (began/ended with and without .shouldResume)
//  - AVAudioEngineConfigurationChange coordination
//  - Foreground recovery (didBecomeActive fallback)
//  - Edge cases around user-initiated stops during interruption
//
//  References:
//  - https://developer.apple.com/documentation/avfaudio/handling-audio-interruptions
//  - Apple Audio Session Programming Guide: "There is no guarantee that a begin
//    interruption will have a corresponding end interruption."
//  - Apple: Non-media apps (games, metronomes) should ignore .shouldResume and
//    always resume when the interruption ends.
//

import AVFoundation
import Combine
import XCTest
@testable import OneEighty

@MainActor
final class AudioInterruptionRecoveryTests: XCTestCase {

    private var store: InMemoryStateStore!
    private var engine: OneEightyEngine!
    private var cancellables: Set<AnyCancellable>!

    override func setUp() {
        store = InMemoryStateStore()
        engine = OneEightyEngine(store: store)
        engine.setup()
        cancellables = []
    }

    override func tearDown() {
        cancellables.removeAll()
        engine.teardown()
        engine = nil
        store = nil
    }

    // MARK: - Helpers

    private func postInterruptionBegan() async {
        NotificationCenter.default.post(name: .audioInterruptionBegan, object: nil)
        await Task.yield()
        await Task.yield()
    }

    private func postInterruptionEnded() async {
        NotificationCenter.default.post(name: .audioInterruptionEnded, object: nil)
        await Task.yield()
        await Task.yield()
    }

    private func postDidBecomeActive() async {
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        await Task.yield()
        await Task.yield()
    }

    private func postEngineConfigChange() async {
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: nil)
        await Task.yield()
        await Task.yield()
    }

    // MARK: - 1. Foreground Recovery (didBecomeActive)
    //
    // Apple docs: "There is no guarantee that a begin interruption will have a
    // corresponding end interruption. Your app needs to be aware of a switch to
    // a foreground running state or the user pressing a Play button."

    /// The core bug: Watch Fitness takes audio, .ended never fires, user opens the app.
    func testResumesOnDidBecomeActiveAfterInterruptionWithNoEnded() async {
        engine.togglePlayback()
        XCTAssertTrue(engine.isPlaying)

        await postInterruptionBegan()
        XCTAssertFalse(engine.isPlaying)

        // .ended never fires (Watch workout scenario)
        // User opens the app
        await postDidBecomeActive()

        XCTAssertTrue(engine.isPlaying, "Engine should auto-resume when app becomes active after interruption")
        XCTAssertTrue(store.isPlaying, "Store should reflect resumed state")
    }

    /// BPM must survive the full interruption + foreground recovery cycle.
    func testBPMPreservedAcrossInterruptionAndForegroundRecovery() async {
        engine.setBPM(200)
        engine.togglePlayback()

        await postInterruptionBegan()
        XCTAssertEqual(engine.bpm, 200)

        await postDidBecomeActive()

        XCTAssertEqual(engine.bpm, 200, "BPM should be preserved after foreground recovery")
        XCTAssertTrue(engine.isPlaying)
    }

    /// If engine wasn't playing before interruption, didBecomeActive should NOT resume.
    func testDoesNotResumeOnDidBecomeActiveIfWasNotPlaying() async {
        XCTAssertFalse(engine.isPlaying)

        await postInterruptionBegan()
        await postDidBecomeActive()

        XCTAssertFalse(engine.isPlaying, "Should not resume if was not playing before interruption")
    }

    /// didBecomeActive without any interruption should be a no-op.
    func testDidBecomeActiveWithoutInterruptionIsNoOp() async {
        XCTAssertFalse(engine.isPlaying)
        await postDidBecomeActive()
        XCTAssertFalse(engine.isPlaying, "Should not start playing just because app became active")
    }

    /// didBecomeActive while already playing (no interruption) should be a no-op.
    func testDidBecomeActiveWhilePlayingIsNoOp() async {
        engine.togglePlayback()
        XCTAssertTrue(engine.isPlaying)

        await postDidBecomeActive()

        XCTAssertTrue(engine.isPlaying, "Should remain playing — no double-start")
    }

    /// Multiple didBecomeActive notifications should only resume once.
    func testMultipleDidBecomeActiveOnlyResumesOnce() async {
        engine.togglePlayback()
        XCTAssertTrue(engine.isPlaying)

        await postInterruptionBegan()
        XCTAssertFalse(engine.isPlaying)

        var stateChanges: [PlaybackState] = []
        engine.statePublisher
            .dropFirst()
            .sink { stateChanges.append($0) }
            .store(in: &cancellables)

        await postDidBecomeActive()
        await postDidBecomeActive()
        await postDidBecomeActive()

        XCTAssertTrue(engine.isPlaying)
        // Should only have one playing=true transition, not three
        let resumeCount = stateChanges.filter { $0.isPlaying }.count
        XCTAssertEqual(resumeCount, 1, "Should only resume once despite multiple didBecomeActive")
    }

    // MARK: - 2. shouldResume Gate
    //
    // Apple docs: "Apps that don't present a playback interface, such as a game,
    // can ignore this flag and reactivate and resume playback when the interruption
    // ends."
    //
    // OneEighty is a metronome — it should always resume, regardless of .shouldResume.

    /// Interruption ended WITHOUT .shouldResume should still post audioInterruptionEnded.
    /// This tests the AudioSessionManager layer — it currently gates on .shouldResume.
    func testInterruptionEndedWithoutShouldResumeStillNotifies() async {
        var receivedEnded = false
        let observer = NotificationCenter.default.addObserver(
            forName: .audioInterruptionEnded,
            object: nil,
            queue: .main
        ) { _ in receivedEnded = true }
        defer { NotificationCenter.default.removeObserver(observer) }

        // Post a raw AVAudioSession interruption ended WITHOUT .shouldResume
        let userInfo: [AnyHashable: Any] = [
            AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue
            // Deliberately omitting AVAudioSessionInterruptionOptionKey
        ]
        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: userInfo
        )
        await Task.yield()
        await Task.yield()

        XCTAssertTrue(receivedEnded, "audioInterruptionEnded should be posted even without .shouldResume for a metronome app")
    }

    /// Interruption ended WITH .shouldResume should still post (no regression).
    func testInterruptionEndedWithShouldResumeStillNotifies() async {
        var receivedEnded = false
        let observer = NotificationCenter.default.addObserver(
            forName: .audioInterruptionEnded,
            object: nil,
            queue: .main
        ) { _ in receivedEnded = true }
        defer { NotificationCenter.default.removeObserver(observer) }

        let userInfo: [AnyHashable: Any] = [
            AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
            AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue
        ]
        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: userInfo
        )
        await Task.yield()
        await Task.yield()

        XCTAssertTrue(receivedEnded, "audioInterruptionEnded should be posted when .shouldResume is set")
    }

    /// Full engine-level test: raw interruption without .shouldResume should resume playback.
    func testEngineResumesAfterInterruptionEndedWithoutShouldResume() async {
        engine.togglePlayback()
        XCTAssertTrue(engine.isPlaying)

        // Post raw interruption began
        let beganInfo: [AnyHashable: Any] = [
            AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue
        ]
        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: beganInfo
        )
        await Task.yield()
        await Task.yield()

        XCTAssertFalse(engine.isPlaying)

        // Post raw interruption ended WITHOUT .shouldResume
        let endedInfo: [AnyHashable: Any] = [
            AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue
        ]
        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: endedInfo
        )
        await Task.yield()
        await Task.yield()

        XCTAssertTrue(engine.isPlaying, "Metronome should resume after interruption ends, regardless of .shouldResume")
    }

    // MARK: - 3. User-Initiated Stop During Interruption
    //
    // If the user explicitly stops the metronome while interrupted,
    // no automatic recovery path should restart it.

    /// User stops playback during interruption, then .ended fires — should stay stopped.
    func testUserStopDuringInterruptionPreventsResume() async {
        engine.togglePlayback()
        XCTAssertTrue(engine.isPlaying)

        await postInterruptionBegan()
        XCTAssertFalse(engine.isPlaying)

        // User explicitly stops via external command
        store.simulateExternalChange(.command(.stop))

        await postInterruptionEnded()

        XCTAssertFalse(engine.isPlaying, "Should not resume if user explicitly stopped during interruption")
    }

    /// User stops during interruption, then opens the app — should stay stopped.
    func testUserStopDuringInterruptionPreventsForegroundResume() async {
        engine.togglePlayback()
        XCTAssertTrue(engine.isPlaying)

        await postInterruptionBegan()
        XCTAssertFalse(engine.isPlaying)

        // User explicitly stops
        store.simulateExternalChange(.command(.stop))

        await postDidBecomeActive()

        XCTAssertFalse(engine.isPlaying, "Should not resume on foreground if user explicitly stopped during interruption")
    }

    // MARK: - 4. AVAudioEngineConfigurationChange
    //
    // Apple sample code: config change notification can fire AFTER interruption ended,
    // stopping the engine again. Must coordinate with interruption state.

    /// Config change during interruption should be deferred until interruption ends.
    func testConfigChangeDuringInterruptionDeferredUntilEnded() async {
        engine.togglePlayback()
        XCTAssertTrue(engine.isPlaying)

        await postInterruptionBegan()
        XCTAssertFalse(engine.isPlaying)

        // Config change fires while still interrupted
        await postEngineConfigChange()

        // Should still be stopped (deferred)
        XCTAssertFalse(engine.isPlaying, "Should remain stopped during interruption even after config change")

        // Interruption ends — should resume AND apply config change
        await postInterruptionEnded()

        XCTAssertTrue(engine.isPlaying, "Should resume after interruption ends, with config change applied")
    }

    /// Config change fires right after interruption ended — engine should survive.
    func testConfigChangeImmediatelyAfterInterruptionEndedDoesNotKillAudio() async {
        engine.togglePlayback()
        XCTAssertTrue(engine.isPlaying)

        await postInterruptionBegan()
        await postInterruptionEnded()
        XCTAssertTrue(engine.isPlaying)

        // Config change fires after — should not kill the playing state
        await postEngineConfigChange()

        XCTAssertTrue(engine.isPlaying, "Engine should handle config change after resuming without stopping playback")
    }

    /// Config change while playing (no interruption) — should keep playing.
    func testConfigChangeWhilePlayingRestartsWithoutGap() async {
        engine.togglePlayback()
        XCTAssertTrue(engine.isPlaying)

        await postEngineConfigChange()

        XCTAssertTrue(engine.isPlaying, "Should remain playing after config change — engine reconnects and restarts")
        XCTAssertEqual(engine.bpm, 180, "BPM should be preserved across config change")
    }

    /// Config change while stopped — no-op, engine should stay stopped.
    func testConfigChangeWhileStoppedIsNoOp() async {
        XCTAssertFalse(engine.isPlaying)

        await postEngineConfigChange()

        XCTAssertFalse(engine.isPlaying, "Should remain stopped after config change when not playing")
    }

    // MARK: - 5. Compound Scenarios
    //
    // Real-world sequences that combine multiple notification types.

    /// Repeated Watch interruptions during a run (km announcements).
    func testRepeatedInterruptionsAllRecover() async {
        engine.togglePlayback()
        XCTAssertTrue(engine.isPlaying)

        // Simulate 5 Watch Fitness km announcements
        for i in 1...5 {
            await postInterruptionBegan()
            XCTAssertFalse(engine.isPlaying, "Should pause during interruption \(i)")

            await postInterruptionEnded()
            XCTAssertTrue(engine.isPlaying, "Should resume after interruption \(i)")
        }

        XCTAssertEqual(engine.bpm, 180, "BPM should be preserved through all interruptions")
    }

    /// Interruption → config change → didBecomeActive (all three firing).
    func testInterruptionThenConfigChangeThenForegroundRecovery() async {
        engine.togglePlayback()
        XCTAssertTrue(engine.isPlaying)

        await postInterruptionBegan()
        XCTAssertFalse(engine.isPlaying)

        // Config change while interrupted
        await postEngineConfigChange()
        XCTAssertFalse(engine.isPlaying)

        // .ended never fires, user opens app
        await postDidBecomeActive()

        XCTAssertTrue(engine.isPlaying, "Should resume via foreground recovery even after config change during interruption")
    }

    /// Interruption ended fires, then config change, then didBecomeActive — should not double-resume.
    func testNoDoubleResumeWhenAllNotificationsFire() async {
        engine.togglePlayback()
        XCTAssertTrue(engine.isPlaying)

        await postInterruptionBegan()

        var stateChanges: [PlaybackState] = []
        engine.statePublisher
            .dropFirst()
            .sink { stateChanges.append($0) }
            .store(in: &cancellables)

        await postInterruptionEnded()
        await postEngineConfigChange()
        await postDidBecomeActive()

        XCTAssertTrue(engine.isPlaying)
        let resumeCount = stateChanges.filter { $0.isPlaying }.count
        XCTAssertEqual(resumeCount, 1, "Should only resume once even if multiple recovery paths fire")
    }

    /// BPM change via widget during interruption, then foreground recovery.
    func testExternalBPMChangeDuringInterruptionPreservedOnRecovery() async {
        engine.setBPM(190)
        engine.togglePlayback()

        await postInterruptionBegan()

        // Widget changes BPM while interrupted
        store.bpm = 210
        store.simulateExternalChange(.stateChanged)
        XCTAssertEqual(engine.bpm, 210, "BPM should update even during interruption")

        await postDidBecomeActive()

        XCTAssertTrue(engine.isPlaying, "Should resume on foreground")
        XCTAssertEqual(engine.bpm, 210, "BPM set during interruption should be preserved")
    }

    /// Interruption began arrives twice (duplicate) — should not corrupt state.
    func testDuplicateInterruptionBeganDoesNotCorruptState() async {
        engine.togglePlayback()
        XCTAssertTrue(engine.isPlaying)

        await postInterruptionBegan()
        await postInterruptionBegan() // duplicate

        XCTAssertFalse(engine.isPlaying)

        await postInterruptionEnded()

        XCTAssertTrue(engine.isPlaying, "Should recover normally after duplicate interruptionBegan")
    }

    /// Interruption ended arrives without a preceding began — should be harmless.
    func testSpuriousInterruptionEndedIsHarmless() async {
        engine.togglePlayback()
        XCTAssertTrue(engine.isPlaying)

        // Ended without began — should not change state
        await postInterruptionEnded()

        XCTAssertTrue(engine.isPlaying, "Spurious interruptionEnded should not affect playing state")
    }

    /// didBecomeActive after normal interruption recovery — should not re-resume.
    func testDidBecomeActiveAfterNormalRecoveryIsNoOp() async {
        engine.togglePlayback()
        await postInterruptionBegan()
        await postInterruptionEnded()
        XCTAssertTrue(engine.isPlaying)

        var stateChanges: [PlaybackState] = []
        engine.statePublisher
            .dropFirst()
            .sink { stateChanges.append($0) }
            .store(in: &cancellables)

        await postDidBecomeActive()

        XCTAssertTrue(engine.isPlaying)
        XCTAssertTrue(stateChanges.isEmpty, "No state change should be emitted — already recovered")
    }
}
