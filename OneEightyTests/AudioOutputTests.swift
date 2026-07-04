import XCTest
@testable import OneEighty

@MainActor
final class AudioOutputTests: XCTestCase {
    func testFakeTracksLifecycle() {
        let out = FakeAudioOutput()
        out.start(bpm: 190)
        XCTAssertTrue(out.isRunning)
        XCTAssertEqual(out.lastBPM, 190)
        out.stop()
        XCTAssertFalse(out.isRunning)
    }
}
