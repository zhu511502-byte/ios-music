import Foundation
import QuartzCore

/// Smooths the sparse `AVPlayer` time samples used by karaoke lyrics.
///
/// `AVPlayer` delivers periodic time observations at roughly 100 ms, and each
/// observation can be a few milliseconds late depending on main-thread load.
/// Interpolating with a display link alone makes the mask edge jump whenever a
/// new sample arrives. This clock advances every frame at playback rate and
/// absorbs sample error slowly, matching kunyin's `LyricPlaybackClock`.
final class LyricPlaybackClock {
    private var rendered: Double
    private var anchorPosition: Double
    private var anchorHost: CFTimeInterval
    private var lastFrameHost: CFTimeInterval
    private var running: Bool

    private let smoothSeconds = 0.25
    private let forwardJumpSeconds = 0.30
    private let seekBackwardSeconds = 0.50
    private let maxFrameSeconds = 0.10

    init(position: Double, host: CFTimeInterval, running: Bool) {
        let value = max(position, 0)
        rendered = value
        anchorPosition = value
        anchorHost = host
        lastFrameHost = host
        self.running = running
    }

    /// Feed a new player position sample.
    @discardableResult
    func accept(position: Double, host: CFTimeInterval, running: Bool) -> Double {
        let movedBackward = position < anchorPosition
        anchorPosition = position
        anchorHost = host

        let error = position - rendered
        if !running || !self.running || movedBackward ||
            error > forwardJumpSeconds || error < -seekBackwardSeconds {
            rendered = position
            lastFrameHost = host
        }
        self.running = running
        return rendered
    }

    /// A user seek must align immediately even when it is a small backward jump.
    @discardableResult
    func seek(to position: Double, host: CFTimeInterval, running: Bool) -> Double {
        anchorPosition = position
        anchorHost = host
        rendered = position
        lastFrameHost = host
        self.running = running
        return position
    }

    /// Called from the display link. `host` should be the display-link timestamp.
    func frame(host: CFTimeInterval, rate: Double = 1) -> Double {
        guard running else { return rendered }
        let dt = min(max(host - lastFrameHost, 0), maxFrameSeconds)
        if host > lastFrameHost { lastFrameHost = host }

        let truth = anchorPosition + (host - anchorHost) * rate
        let advance = dt * rate
        let target = rendered + advance
        let error = truth - target

        if error > forwardJumpSeconds {
            rendered = truth
            return rendered
        }

        // Positive error means we are behind: catch up at no more than 1.5x.
        // Negative error means we are ahead: slow down without going backward.
        let correction = error * (1 - exp(-dt / smoothSeconds))
        let step = advance + correction
        if error >= 0 {
            rendered += min(max(step, advance * 0.5), advance * 1.5)
        } else {
            rendered += min(max(step, advance * 0.05), advance)
        }
        return rendered
    }
}
