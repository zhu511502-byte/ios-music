import Foundation
import AVFoundation

/// Owns the process-wide playback audio session.
///
/// iOS can interrupt or fully reset the audio session while the phone is
/// locked (phone calls, other players, system sounds, media daemon restarts).
/// This controller keeps one observer for the lifetime of the app and always
/// reports the interruption back to the playback coordinator so it can rebuild
/// the player instead of silently staying paused.
@MainActor
final class AudioSessionController {
    static let shared = AudioSessionController()

    private var isConfigured = false
    private var interruptionObserver: NSObjectProtocol?
    private var mediaResetObserver: NSObjectProtocol?
    private var routeObserver: NSObjectProtocol?

    private init() {}

    func configure() {
        guard !isConfigured else {
            activate()
            return
        }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playback,
                mode: .default,
                options: [.allowAirPlay, .allowBluetoothA2DP]
            )
            try session.setActive(true)
            isConfigured = true
        } catch {
            print("Audio session configure failed: \(error)")
            return
        }

        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: .main
        ) { notification in
            guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }

            if type == .began {
                NotificationCenter.default.post(name: .lxAudioInterruptionBegan, object: nil)
            } else if type == .ended {
                let optionsRaw = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
                NotificationCenter.default.post(
                    name: .lxAudioInterruptionEnded,
                    object: nil,
                    userInfo: ["shouldResume": options.contains(.shouldResume)]
                )
            }
        }

        mediaResetObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: session,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isConfigured = false
                self?.configure()
                NotificationCenter.default.post(name: .lxAudioSessionReset, object: nil)
            }
        }

        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: .main
        ) { notification in
            guard let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
            if reason == .oldDeviceUnavailable {
                NotificationCenter.default.post(name: .lxAudioRouteChanged, object: nil)
            }
        }
    }

    func activate() {
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Audio session activate failed: \(error)")
        }
    }
}

extension Notification.Name {
    static let lxAudioInterruptionBegan = Notification.Name("lx.audio.interruption.began")
    static let lxAudioInterruptionEnded = Notification.Name("lx.audio.interruption.ended")
    static let lxAudioSessionReset = Notification.Name("lx.audio.session.reset")
    static let lxAudioRouteChanged = Notification.Name("lx.audio.route.changed")
}
