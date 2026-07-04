/// Audio side-effects the reconciler drives. Real impl wraps AVAudioEngine +
/// TickScheduler; the fake records calls for tests.
@MainActor
protocol AudioOutput: AnyObject {
    var isRunning: Bool { get }
    func start(bpm: Int)
    func stop()
    func updateBPM(_ bpm: Int)
    func setVolume(_ volume: Float)
}
