//
//  NowPlayingTests.swift
//  OneEightyTests
//

import XCTest
import MediaPlayer
@testable import OneEighty

@MainActor
final class NowPlayingTests: XCTestCase {
    func testNowPlayingReflectsStateAfterSync() {
        let store = InMemoryPlaybackStore(AppState(version: 1, bpm: 200, isPlaying: true))
        let engine = OneEightyEngine(store: store, audio: FakeAudioOutput())
        engine.hydrate()   // syncFromStore calls updateNowPlaying()
        let info = MPNowPlayingInfoCenter.default().nowPlayingInfo
        XCTAssertEqual(info?[MPMediaItemPropertyTitle] as? String, "200 SPM")
        XCTAssertEqual(info?[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 1.0)
    }
}
