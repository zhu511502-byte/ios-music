import Foundation
import AVFoundation

@MainActor
final class AudioSessionController {
    static let shared = AudioSessionController()

    private init() {}

    func configure() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
        } catch {
            print("Audio session configure failed: \(error)")
        }
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: .main
        ) { notification in
            guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            if type == .began {
                NotificationCenter.default.post(name: .lxAudioInterruptionBegan, object: nil)
            } else if let optionsRaw = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt,
                      AVAudioSession.InterruptionOptions(rawValue: optionsRaw).contains(.shouldResume) {
                NotificationCenter.default.post(name: .lxAudioInterruptionEnded, object: nil)
            }
        }
    }

    func activate() {
        try? AVAudioSession.sharedInstance().setActive(true)
    }
}

extension Notification.Name {
    static let lxAudioInterruptionBegan = Notification.Name("lx.audio.interruption.began")
    static let lxAudioInterruptionEnded = Notification.Name("lx.audio.interruption.ended")
    static let lxAudioRouteChanged = Notification.Name("lx.audio.route.changed")
}
