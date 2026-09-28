import AVFoundation

/// Keeps Bird Server running while the phone is locked or another app is in front.
///
/// iOS pauses an app a few seconds after it leaves the screen, and a paused host drops every player. An app that is
/// playing audio keeps running, so this plays silence, mixed with whatever else is playing (music carries on).
/// That's fine for an app you install on your own phone; the App Store wouldn't accept it.
final class KeepAlive {
    private(set) var running = false
    /// Started or stopped by itself (an interruption such as a phone call, and the restart after it).
    var onChange: ((Bool) -> Void)?
    private var engine: AVAudioEngine?
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            self?.interrupted(n)
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            self?.restart()
        })
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    /// Start playing silence. Returns whether it's running.
    @discardableResult
    func start() -> Bool {
        guard !running else { return true }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            let e = AVAudioEngine()
            guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1) else { return false }
            let silence = AVAudioSourceNode(format: format) { isSilence, _, _, buffers in
                isSilence.pointee = true
                for b in UnsafeMutableAudioBufferListPointer(buffers) {
                    if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) }
                }
                return noErr
            }
            e.attach(silence)
            e.connect(silence, to: e.mainMixerNode, format: format)
            try e.start()
            engine = e
            running = true
        } catch {
            engine?.stop()
            engine = nil
            running = false
        }
        return running
    }

    func stop() {
        guard running || engine != nil else { return }
        engine?.stop()
        engine = nil
        running = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// A call or an alarm stops our audio; pick it up again afterwards.
    private func interrupted(_ n: Notification) {
        guard running, let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw), type == .ended else { return }
        restart()
    }

    private func restart() {
        guard running else { return }
        engine?.stop()
        engine = nil
        running = false
        start()
        onChange?(running)
    }
}
