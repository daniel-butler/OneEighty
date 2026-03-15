import XCTest
@testable import OneEighty

final class AudioSessionManagerTests: XCTestCase {
    func testDeactivateDoesNotThrow() {
        AudioSessionManager.shared.deactivate()
    }

    func testActivateDoesNotThrow() {
        AudioSessionManager.shared.activate()
    }

    func testDeactivateThenActivateRoundTrip() {
        AudioSessionManager.shared.deactivate()
        AudioSessionManager.shared.activate()
    }
}
