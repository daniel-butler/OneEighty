@testable import OneEighty

@MainActor
final class FakeAudioOutput: AudioOutput {
    private(set) var isRunning = false
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var lastBPM: Int?
    private(set) var lastVolume: Float?

    func start(bpm: Int) { isRunning = true; startCount += 1; lastBPM = bpm }
    func stop() { isRunning = false; stopCount += 1 }
    func updateBPM(_ bpm: Int) { lastBPM = bpm }
    func setVolume(_ volume: Float) { lastVolume = volume }
}
