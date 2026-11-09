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

    func makeUIView(context: Context) -> KaraokeTextLayerUIView {
        let view = KaraokeTextLayerUIView()
        view.configure(line: line, clock: clock, fontSize: fontSize, isPlaying: isPlaying)
        return view
    }

    func updateUIView(_ uiView: KaraokeTextLayerUIView, context: Context) {
        uiView.configure(line: line, clock: clock, fontSize: fontSize, isPlaying: isPlaying)
    }
}

final class KaraokeTextLayerUIView: UIView {
    private let baseLayer = CATextLayer()
    private let highlightLayer = CATextLayer()
    private let maskLayer = CAGradientLayer()

    private var clock: LyricsClock?
    private var cancellable: AnyCancellable?
    private var displayLink: CADisplayLink?

    private var line: LyricLine?
    private var fontSize: CGFloat = 30
    private var isPlaying = false

    private var charOffsets: [CGFloat] = []
    private var times: [Double] = []
    private var lineStart: Double = 0
    private var lineEnd: Double = 0

    private var lastClockTime: Double = 0
    private var lastClockHost: CFTimeInterval = 0
    private var lastLayoutWidth: CGFloat = 0
    private var lastLineID: Int = -1
    private var lastFontSize: CGFloat = 0

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
            UIColor.clear.cgColor
        ]
        highlightLayer.mask = maskLayer
        maskLayer.opacity = 0
    }

    func configure(line: LyricLine, clock: LyricsClock, fontSize: CGFloat, isPlaying: Bool) {
        let lineChanged = self.line?.id != line.id
        let fontChanged = self.fontSize != fontSize
        let clockChanged = self.clock !== clock

        self.line = line
        self.fontSize = fontSize
        self.isPlaying = isPlaying

        if clockChanged || cancellable == nil {
            subscribe(to: clock)
        }
        if lineChanged || fontChanged || bounds.width != lastLayoutWidth {
            rebuildIfPossible()
        }
        if !isPlaying {
            updateMask(at: lastClockTime)
        }
        displayLink?.isPaused = !isPlaying
        setNeedsLayout()
    }

    private func subscribe(to clock: LyricsClock) {
        cancellable?.cancel()
        self.clock = clock
        lastClockTime = clock.time
        lastClockHost = CACurrentMediaTime()
        cancellable = clock.$time
            .receive(on: RunLoop.main)
            .sink { [weak self] time in
                guard let self else { return }
                self.lastClockTime = time
                self.lastClockHost = CACurrentMediaTime()
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
        link.isPaused = !isPlaying
    }

    @objc private func tick() {
        guard isPlaying, line != nil else { return }
        let now = CACurrentMediaTime()
        let current = lastClockTime + max(0, now - lastClockHost)
        updateMask(at: current)
    }

    private func rebuildIfPossible() {
        guard bounds.width > 1, let line else { return }
        guard line.id != lastLineID || fontSize != lastFontSize || bounds.width != lastLayoutWidth else { return }

        lastLineID = line.id
        lastFontSize = fontSize
        lastLayoutWidth = bounds.width

        let available = bounds.width
        let baseFont = UIFont.systemFont(ofSize: fontSize, weight: .bold)
        let baseAttr = NSAttributedString(
            string: line.text,
            attributes: [.font: baseFont, .foregroundColor: UIColor.white]
        )
        let baseCT = CTLineCreateWithAttributedString(baseAttr)
        let measured = CGFloat(CTLineGetTypographicBounds(baseCT, nil, nil, nil))
        let fit = measured > 0 ? min(1, available / measured) : 1
        let fittedSize = max(fontSize * 0.72, fontSize * fit)
        let font = UIFont.systemFont(ofSize: fittedSize, weight: .bold)

        let base = NSAttributedString(
            string: line.text,
            attributes: [.font: font, .foregroundColor: UIColor.white.withAlphaComponent(0.30)]
        )
        let highlight = NSAttributedString(
            string: line.text,
            attributes: [.font: font, .foregroundColor: UIColor.white]
        )
        let ctLine = CTLineCreateWithAttributedString(highlight)

        charOffsets = [0]
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

        times = effectiveTimes(for: line)
        lineStart = line.time ?? 0
        lineEnd = line.endTime ?? (lineStart + min(max(Double(line.text.count) * 0.32, 2.0), 4.0))

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
        guard !charOffsets.isEmpty, charOffsets.count == times.count + 1 else {
            maskLayer.opacity = 0
            return
        }

        let x: CGFloat
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

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let width = max(0, min(x, bounds.width))
        maskLayer.frame = CGRect(x: 0, y: 0, width: width, height: bounds.height)
        if width > 0 {
            let feather = min(14, width)
            let stop = max(0, (width - feather) / width)
            maskLayer.locations = [NSNumber(value: 0), NSNumber(value: Double(stop)), NSNumber(value: 1)]
            maskLayer.opacity = 1
        } else {
            maskLayer.opacity = 0
        }
        CATransaction.commit()
    }
}
