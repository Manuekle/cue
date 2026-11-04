import CoreMedia
import CoreText
import CoreVideo
import QuartzCore
import UIKit

/// Dibuja el prompter en buffers de video para la ventana flotante (Picture in Picture).
final class PrompterFrameRenderer {
    struct State: Equatable {
        var text: String
        var fontSize: CGFloat
        var centered: Bool
        var mirror: Bool
        var progress: Double
        var phase: PrompterEngine.Phase
        /// 0...1 dentro del segundo actual de la cuenta regresiva.
        var countdownFraction: Double
        var elapsed: Int
        var remaining: Int
        /// Mensaje mientras espera para empezar.
        var readyHint: String
    }

    let width: Int
    let height: Int
    private var pool: CVPixelBufferPool?
    private var formatDescription: CMVideoFormatDescription?
    private var layout: TextLayout?
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    private let accent = (UIColor(named: "AccentColor") ?? .systemYellow).cgColor
    private let guideRatio: CGFloat = 0.26

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
        ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
    }

    // MARK: Buffer

    func makeSampleBuffer(_ state: State) -> CMSampleBuffer? {
        guard let pool else { return nil }
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
        guard let pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let context = CGContext(data: CVPixelBufferGetBaseAddress(pixelBuffer),
                                   width: width, height: height, bitsPerComponent: 8,
                                   bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                                   space: colorSpace,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
            draw(state, in: context)
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        if formatDescription == nil {
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
                                                         formatDescriptionOut: &formatDescription)
        }
        guard let formatDescription else { return nil }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
                                                 formatDescription: formatDescription, sampleTiming: &timing,
                                                 sampleBufferOut: &sampleBuffer)
        if let sampleBuffer,
           let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sampleBuffer
    }

    // MARK: Dibujo

    private func draw(_ state: State, in context: CGContext) {
        let size = CGSize(width: width, height: height)
        let bounds = CGRect(origin: .zero, size: size)
        context.setFillColor(UIColor.black.cgColor)
        context.fill(bounds)

        if state.mirror {
            context.translateBy(x: size.width, y: 0)
            context.scaleBy(x: -1, y: 1)
        }
        context.textMatrix = .identity

        let layout = textLayout(for: state)
        let guideY = (size.height * guideRatio).rounded()
        let scroll = CGFloat(state.progress) * layout.height

        // Texto (coordenadas de arriba hacia abajo convertidas a las de CoreGraphics).
        for line in layout.lines {
            let baseline = guideY + line.baseline - scroll
            guard baseline > -layout.lineHeight, baseline < size.height + layout.lineHeight else { continue }
            context.textPosition = CGPoint(x: line.x, y: size.height - baseline)
            CTLineDraw(line.line, context)
        }

        drawFades(in: context, size: size, guideY: guideY, fontSize: state.fontSize)
        drawGuide(in: context, size: size, guideY: guideY, fontSize: state.fontSize)
        if state.phase != .ready {
            drawProgress(state.progress, in: context, size: size)
        }

        switch state.phase {
        case .countdown(let number):
            drawCountdown(number, fraction: state.countdownFraction, in: context, size: size)
        case .ready:
            drawPill(state.readyHint, in: context, size: size)
        case .paused:
            drawPill(String(localized: "Paused"), in: context, size: size)
        case .finished:
            drawPill(String(localized: "End of script"), in: context, size: size)
        case .playing:
            break
        }

        if state.phase == .paused || state.phase == .finished {
            let time = "\(TimeFormat.clock(TimeInterval(state.elapsed)))  −\(TimeFormat.clock(TimeInterval(state.remaining)))"
            drawSmallText(time, in: context, at: CGPoint(x: size.width - 24, y: size.height - 22), alignRight: true)
        }
    }

    private func drawFades(in context: CGContext, size: CGSize, guideY: CGFloat, fontSize: CGFloat) {
        let black = UIColor.black
        // Arriba: lo ya leído queda atenuado.
        if let top = CGGradient(colorsSpace: colorSpace,
                                colors: [black.cgColor, black.withAlphaComponent(0.6).cgColor,
                                         black.withAlphaComponent(0.55).cgColor, black.withAlphaComponent(0).cgColor] as CFArray,
                                locations: [0, 0.35, 0.8, 1]) {
            context.drawLinearGradient(top,
                                       start: CGPoint(x: 0, y: size.height),
                                       end: CGPoint(x: 0, y: size.height - guideY),
                                       options: [])
        }
        // Abajo: se desvanece al borde.
        if let bottom = CGGradient(colorsSpace: colorSpace,
                                   colors: [black.withAlphaComponent(0).cgColor, black.cgColor] as CFArray,
                                   locations: [0, 1]) {
            context.drawLinearGradient(bottom,
                                       start: CGPoint(x: 0, y: size.height * 0.2),
                                       end: CGPoint(x: 0, y: 0),
                                       options: [])
        }
    }

    private func drawGuide(in context: CGContext, size: CGSize, guideY: CGFloat, fontSize: CGFloat) {
        let centerY = size.height - (guideY + fontSize * 0.62)
        let arrowHeight = max(22, fontSize * 0.45)
        context.setFillColor(accent)
        context.beginPath()
        context.move(to: CGPoint(x: 8, y: centerY + arrowHeight / 2))
        context.addLine(to: CGPoint(x: 8 + arrowHeight * 0.6, y: centerY))
        context.addLine(to: CGPoint(x: 8, y: centerY - arrowHeight / 2))
        context.closePath()
        context.fillPath()
    }

    private func drawCountdown(_ number: Int, fraction: Double, in context: CGContext, size: CGSize) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = min(size.width, size.height) * 0.3
        context.setFillColor(UIColor.black.withAlphaComponent(0.75).cgColor)
        context.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))

        let lineWidth = radius * 0.1
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.setStrokeColor(UIColor.white.withAlphaComponent(0.15).cgColor)
        context.strokeEllipse(in: CGRect(x: center.x - radius + lineWidth, y: center.y - radius + lineWidth,
                                         width: (radius - lineWidth) * 2, height: (radius - lineWidth) * 2))
        let remaining = CGFloat(1 - fraction.clamped(to: 0...1))
        if remaining > 0.001 {
            context.saveGState()
            context.setStrokeColor(accent)
            context.addArc(center: center, radius: radius - lineWidth, startAngle: .pi / 2,
                           endAngle: .pi / 2 - remaining * 2 * .pi, clockwise: true)
            context.strokePath()
            context.restoreGState()
        }

        let font = Self.roundedFont(size: radius * 1.05, weight: .bold)
        let line = Self.line("\(number)", font: font, color: UIColor.white.cgColor)
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        context.textPosition = CGPoint(x: center.x - CGFloat(width) / 2, y: center.y - font.capHeight / 2)
        CTLineDraw(line, context)
    }

    private func drawProgress(_ progress: Double, in context: CGContext, size: CGSize) {
        let height: CGFloat = 6
        let width = max(height, size.width * CGFloat(progress.clamped(to: 0...1)))
        context.saveGState()
        context.setFillColor(accent)
        context.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: width, height: height),
                               cornerWidth: height / 2, cornerHeight: height / 2, transform: nil))
        context.fillPath()
        context.restoreGState()
    }

    private func drawPill(_ text: String, in context: CGContext, size: CGSize) {
        let font = Self.roundedFont(size: min(size.width, size.height) * 0.05, weight: .semibold)
        let line = Self.line(text, font: font, color: UIColor.white.cgColor)
        let textWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let padding = font.pointSize * 0.9
        let height = font.pointSize * 2.1
        let rect = CGRect(x: (size.width - textWidth) / 2 - padding,
                          y: size.height - height - size.height * 0.05,
                          width: textWidth + padding * 2,
                          height: height)
        context.setFillColor(UIColor(white: 0.18, alpha: 0.92).cgColor)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: rect.height / 2, cornerHeight: rect.height / 2, transform: nil))
        context.fillPath()
        context.textPosition = CGPoint(x: rect.minX + padding, y: rect.midY - font.capHeight / 2)
        CTLineDraw(line, context)
    }

    private func drawSmallText(_ text: String, in context: CGContext, at point: CGPoint, alignRight: Bool) {
        let font = Self.roundedFont(size: CGFloat(height) * 0.045, weight: .semibold, monospacedDigits: true)
        let line = Self.line(text, font: font, color: UIColor.white.withAlphaComponent(0.75).cgColor)
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        context.textPosition = CGPoint(x: alignRight ? point.x - width : point.x, y: point.y - font.capHeight)
        CTLineDraw(line, context)
    }

    // MARK: Diseño del texto

    private struct TextLayout {
        struct Line { let line: CTLine; let x: CGFloat; let baseline: CGFloat }
        let key: String
        let lines: [Line]
        let height: CGFloat
        let lineHeight: CGFloat
    }

    private func textLayout(for state: State) -> TextLayout {
        let key = "\(state.text.hashValue)|\(state.fontSize)|\(state.centered)"
        if let layout, layout.key == key { return layout }

        let margin = CGFloat(width) * 0.07
        let textWidth = CGFloat(width) - margin * 2
        let font = Self.roundedFont(size: state.fontSize, weight: .semibold)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = state.centered ? .center : .left
        paragraph.lineSpacing = state.fontSize * 0.22
        let attributed = NSAttributedString(string: state.text, attributes: [
            .font: font,
            .paragraphStyle: paragraph,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): UIColor.white.cgColor,
        ])
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(), nil, CGSize(width: textWidth, height: .greatestFiniteMagnitude), nil)
        let frameHeight = ceil(suggested.height) + state.fontSize * 2
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: textWidth, height: frameHeight), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(), path, nil)
        let ctLines = (CTFrameGetLines(frame) as? [CTLine]) ?? []
        var origins = [CGPoint](repeating: .zero, count: ctLines.count)
        CTFrameGetLineOrigins(frame, CFRange(), &origins)

        var lines: [TextLayout.Line] = []
        var contentHeight: CGFloat = 0
        for (line, origin) in zip(ctLines, origins) {
            var descent: CGFloat = 0
            CTLineGetTypographicBounds(line, nil, &descent, nil)
            let baseline = frameHeight - origin.y
            lines.append(.init(line: line, x: margin + origin.x, baseline: baseline))
            contentHeight = max(contentHeight, baseline + descent)
        }
        let layout = TextLayout(key: key, lines: lines, height: max(contentHeight, 1),
                                lineHeight: state.fontSize * 1.4)
        self.layout = layout
        return layout
    }

    private static func line(_ text: String, font: UIFont, color: CGColor) -> CTLine {
        CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            .font: font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]))
    }

    /// SF Rounded.
    private static func roundedFont(size: CGFloat, weight: UIFont.Weight, monospacedDigits: Bool = false) -> UIFont {
        let base = monospacedDigits
            ? UIFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
            : UIFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
        return UIFont(descriptor: descriptor, size: size)
    }
}
