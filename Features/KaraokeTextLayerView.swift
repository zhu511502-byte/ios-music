import SwiftUI
import UIKit
import CoreText
import QuartzCore
import Combine

/// A high-precision karaoke line rendered by Core Animation rather than
/// SwiftUI text/mask views.
///
/// Text is shaped once with Core Text. During playback a `CADisplayLink` only
/// changes the width of a gradient mask layer — no SwiftUI body evaluation,
/// no text layout, no view rebuild. That keeps the accuracy of per-glyph
/// offsets without the frame drops of the SwiftUI mask approach.
struct KaraokeTextLayerView: UIViewRepresentable {
    let line: LyricLine
    let clock: LyricsClock
    let fontSize: CGFloat
    let isPlaying: Bool
    let letterSpacing: CGFloat

    func makeUIView(context: Context) -> KaraokeTextLayerUIView {
        let view = KaraokeTextLayerUIView()
        view.configure(line: line, clock: clock, fontSize: fontSize, isPlaying: isPlaying, letterSpacing: letterSpacing)
        return view
    }

    func updateUIView(_ uiView: KaraokeTextLayerUIView, context: Context) {
        uiView.configure(line: line, clock: clock, fontSize: fontSize, isPlaying: isPlaying, letterSpacing: letterSpacing)
    }
}

final class KaraokeTextLayerUIView: UIView {
    private let baseLayer = CATextLayer()
    private let highlightLayer = CATextLayer()
    private let maskLayer = CAGradientLayer()

    private var clock: LyricsClock?
    private var cancellable: AnyCancellable?
    private var displayLink: CADisplayLink?
    private var playbackClock: LyricPlaybackClock?
    private var isAppActive = true
    private var lifecycleObservers: [NSObjectProtocol] = []

    private var line: LyricLine?
    private var fontSize: CGFloat = 30
    private var isPlaying = false
    private var letterSpacing: CGFloat = 0

    private var charOffsets: [CGFloat] = []
    private var times: [Double] = []
    private var tokenRanges: [(startX: CGFloat, endX: CGFloat, start: Double, end: Double)] = []
    private var lineStart: Double = 0
    private var lineEnd: Double = 0

    private var lastClockTime: Double = 0
    private var lastClockHost: CFTimeInterval = 0
    private var lastLayoutWidth: CGFloat = 0
    private var lastLineID: Int = -1
    private var lastFontSize: CGFloat = 0
    private var lastLetterSpacing: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    deinit {
        displayLink?.invalidate()
        cancellable?.cancel()
        lifecycleObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: fontSize * 1.2)
    }

    private func setup() {
        backgroundColor = .clear
        isOpaque = false
        layer.masksToBounds = false

        for textLayer in [baseLayer, highlightLayer] {
            textLayer.contentsScale = UIScreen.main.scale
            textLayer.alignmentMode = .left
            textLayer.isWrapped = false
            textLayer.truncationMode = .none
            textLayer.masksToBounds = false
            layer.addSublayer(textLayer)
        }

        maskLayer.contentsScale = UIScreen.main.scale
        maskLayer.startPoint = CGPoint(x: 0, y: 0.5)
        maskLayer.endPoint = CGPoint(x: 1, y: 0.5)
        maskLayer.colors = [
            UIColor.white.cgColor,
            UIColor.white.cgColor,
            UIColor.clear.cgColor,
            UIColor.clear.cgColor
        ]
        highlightLayer.mask = maskLayer
        maskLayer.opacity = 0

        // CADisplayLink is paused automatically by iOS in most cases, but
        // doing it explicitly makes sure a locked screen never keeps a 60 fps
        // Core Animation loop alive in the background.
        lifecycleObservers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.isAppActive = false
            self?.displayLink?.isPaused = true
        })
        lifecycleObservers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.isAppActive = true
            self.displayLink?.isPaused = !self.isPlaying
        })
    }

    func configure(line: LyricLine, clock: LyricsClock, fontSize: CGFloat, isPlaying: Bool, letterSpacing: CGFloat) {
        let lineChanged = self.line?.id != line.id
        let fontChanged = self.fontSize != fontSize
        let spacingChanged = self.letterSpacing != letterSpacing
        let clockChanged = self.clock !== clock

        self.line = line
        self.fontSize = fontSize
        self.isPlaying = isPlaying
        self.letterSpacing = letterSpacing

        if clockChanged || cancellable == nil {
            subscribe(to: clock)
        } else {
            playbackClock?.accept(position: lastClockTime, host: CACurrentMediaTime(), running: isPlaying)
        }
        if lineChanged || fontChanged || spacingChanged || bounds.width != lastLayoutWidth {
            rebuildIfPossible()
        }
        if !isPlaying {
            updateMask(at: lastClockTime)
        }
        displayLink?.isPaused = !isPlaying || !isAppActive
        setNeedsLayout()
    }

    private func subscribe(to clock: LyricsClock) {
        cancellable?.cancel()
        self.clock = clock
        let now = CACurrentMediaTime()
        lastClockTime = clock.time
        lastClockHost = now
        playbackClock = LyricPlaybackClock(position: clock.time, host: now, running: isPlaying)
        cancellable = clock.$time
            .receive(on: RunLoop.main)
            .sink { [weak self] time in
                guard let self else { return }
                let host = CACurrentMediaTime()
                self.lastClockTime = time
                self.lastClockHost = host
                self.playbackClock?.accept(position: time, host: host, running: self.isPlaying)
                if !self.isPlaying {
                    self.updateMask(at: time)
                }
            }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.width > 1, bounds.width != lastLayoutWidth {
            rebuildIfPossible()
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            startDisplayLink()
        } else {
            displayLink?.invalidate()
            displayLink = nil
        }
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFramesPerSecond = 60
        link.add(to: .main, forMode: .common)
        displayLink = link
        link.isPaused = !isPlaying || !isAppActive
    }

    @objc private func tick() {
        guard isPlaying, line != nil, let playbackClock else { return }
        let now = CACurrentMediaTime()
        updateMask(at: playbackClock.frame(host: now))
    }

    private func rebuildIfPossible() {
        guard bounds.width > 1, let line else { return }
        guard line.id != lastLineID || fontSize != lastFontSize || letterSpacing != lastLetterSpacing || bounds.width != lastLayoutWidth else { return }

        lastLineID = line.id
        lastFontSize = fontSize
        lastLetterSpacing = letterSpacing
        lastLayoutWidth = bounds.width

        let available = bounds.width
        let baseFont = UIFont.systemFont(ofSize: fontSize, weight: .bold)
        let baseAttr = NSAttributedString(
            string: line.text,
            attributes: [.font: baseFont, .foregroundColor: UIColor.white, .kern: letterSpacing]
        )
        let baseCT = CTLineCreateWithAttributedString(baseAttr)
        let measured = CGFloat(CTLineGetTypographicBounds(baseCT, nil, nil, nil))
        let fit = measured > 0 ? min(1, available / measured) : 1
        let fittedSize = max(fontSize * 0.72, fontSize * fit)
        let font = UIFont.systemFont(ofSize: fittedSize, weight: .bold)

        let base = NSAttributedString(
            string: line.text,
            attributes: [.font: font, .foregroundColor: UIColor.white.withAlphaComponent(0.30), .kern: letterSpacing]
        )
        let highlight = NSAttributedString(
            string: line.text,
            attributes: [.font: font, .foregroundColor: UIColor.white, .kern: letterSpacing]
        )
        let ctLine = CTLineCreateWithAttributedString(highlight)

        charOffsets = [0]
        tokenRanges = []
        var utf16Index = 0
        for character in line.text {
            utf16Index += String(character).utf16.count
            let offset = CTLineGetOffsetForStringIndex(ctLine, utf16Index, nil)
            charOffsets.append(CGFloat(offset))
        }
        let totalWidth = CGFloat(CTLineGetTypographicBounds(ctLine, nil, nil, nil))
        if !charOffsets.isEmpty {
            charOffsets[charOffsets.count - 1] = totalWidth
        }

        // Preserve KRC/YRC/QRC token boundaries. A token can be a whole
        // English word; using its real start/end is more accurate than
        // inventing per-character times.
        if !line.syllables.isEmpty, line.syllables.map(\.text).joined() == line.text {
            var tokenX: CGFloat = 0
            var tokenIndex = 0
            for syllable in line.syllables {
                tokenIndex += syllable.text.utf16.count
                let endX = CGFloat(CTLineGetOffsetForStringIndex(ctLine, tokenIndex, nil))
                tokenRanges.append((tokenX, endX, syllable.start, syllable.end))
                tokenX = endX
            }
            if let last = tokenRanges.last {
                tokenRanges[tokenRanges.count - 1] = (
                    last.startX, max(last.endX, totalWidth), last.start, last.end
                )
            }
        }

        times = effectiveTimes(for: line)
        // The first syllable can begin slightly before the line timestamp;
        // kunyin uses the earliest of the two so the first character is never
        // left behind at the start of a line.
        lineStart = line.animationStart
        lineEnd = line.endTime
            ?? line.syllables.last?.end
            ?? (lineStart + min(max(Double(line.text.count) * 0.32, 2.0), 4.0))

        baseLayer.string = base
        highlightLayer.string = highlight
        baseLayer.fontSize = fittedSize
        highlightLayer.fontSize = fittedSize
        baseLayer.frame = bounds
        highlightLayer.frame = bounds
        maskLayer.frame = CGRect(x: 0, y: 0, width: 0, height: bounds.height)
        updateMask(at: lastClockTime)
    }

    private func effectiveTimes(for line: LyricLine) -> [Double] {
        if line.wordTimes.count == line.text.count { return line.wordTimes }
        let characters = Array(line.text)
        guard !characters.isEmpty, let start = line.time else { return [] }
        let end = line.endTime ?? (start + min(max(Double(characters.count) * 0.32, 2.0), 4.0))
        let duration = max(end - start, 0.4)
        return characters.indices.map { index in
            start + duration * Double(index) / Double(characters.count)
        }
    }

    private func updateMask(at time: Double) {
        let x: CGFloat

        if !tokenRanges.isEmpty {
            if time <= lineStart {
                x = 0
            } else {
                var result = tokenRanges.last?.endX ?? 0
                for token in tokenRanges {
                    if time >= token.end { continue }
                    if time > token.start {
                        let span = max(token.end - token.start, 0.06)
                        let progress = min(max((time - token.start) / span, 0), 1)
                        result = token.startX + (token.endX - token.startX) * CGFloat(progress)
                    } else {
                        result = token.startX
                    }
                    break
                }
                x = result
            }
        } else {
            guard !charOffsets.isEmpty, charOffsets.count == times.count + 1 else {
                maskLayer.opacity = 0
                return
            }
            if time <= lineStart {
                x = 0
            } else {
                var result = charOffsets.last ?? 0
                for index in times.indices {
                    let start = times[index]
                    let end = index + 1 < times.count ? times[index + 1] : lineEnd
                    if time >= end { continue }
                    if time > start {
                        let span = max(end - start, 0.06)
                        let progress = min(max((time - start) / span, 0), 1)
                        result = charOffsets[index] + (charOffsets[index + 1] - charOffsets[index]) * CGFloat(progress)
                    } else {
                        result = charOffsets[index]
                    }
                    break
                }
                x = result
            }
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let width = max(bounds.width, 1)
        let position = min(max(x, 0), width)
        maskLayer.frame = bounds

        if position <= 0.01 {
            maskLayer.opacity = 0
        } else if position >= width - 0.01 {
            // Fully sung: keep every pixel in the bright layer.
            maskLayer.locations = [0, 1, 1, 1]
            maskLayer.opacity = 1
        } else {
            // A very small feather only antialiases the cut. The previous
            // 14 px feather put the visual edge 7 px behind the real token
            // boundary, which made every syllable look late by half a glyph.
            let feather = min(2.0, width * 0.1)
            let start = max(0, (position - feather) / width)
            let end = min(1, (position + feather) / width)
            maskLayer.locations = [
                NSNumber(value: 0),
                NSNumber(value: Double(start)),
                NSNumber(value: Double(end)),
                NSNumber(value: 1)
            ]
            maskLayer.opacity = 1
        }
        CATransaction.commit()
    }
}
