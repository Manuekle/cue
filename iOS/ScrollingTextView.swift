import SwiftUI
import UIKit

/// Texto del guion movido por Core Animation: el texto se dibuja una vez y en cada cuadro
/// solo cambia el desplazamiento. Mucho más liviano que volver a evaluar SwiftUI 60 veces
/// por segundo, sobre todo encima de la cámara.
struct ScrollingTextView: UIViewRepresentable {
    let engine: PrompterEngine
    let text: String
    let fontSize: CGFloat
    let centered: Bool
    let guideRatio: CGFloat
    let horizontalPadding: CGFloat
    /// Sombra para leer sobre video.
    var shadowed = false

    func makeUIView(context: Context) -> ScrollingTextUIView {
        ScrollingTextUIView(engine: engine)
    }

    func updateUIView(_ view: ScrollingTextUIView, context: Context) {
        view.configure(.init(text: text, fontSize: fontSize, centered: centered, guideRatio: guideRatio,
                             horizontalPadding: horizontalPadding, shadowed: shadowed))
    }

    static func dismantleUIView(_ view: ScrollingTextUIView, coordinator: ()) {
        view.stop()
    }
}

final class ScrollingTextUIView: UIView {
    struct Configuration: Equatable {
        var text: String
        var fontSize: CGFloat
        var centered: Bool
        var guideRatio: CGFloat
        var horizontalPadding: CGFloat
        var shadowed: Bool
    }

    private let engine: PrompterEngine
    private let textView: UITextView
    private let fade = CAGradientLayer()
    private var configuration: Configuration?
    private var laidOutWidth: CGFloat = 0
    private var contentHeight: CGFloat = 1
    private var displayLink: CADisplayLink?
    private var lastOffset: CGFloat = .nan

    init(engine: PrompterEngine) {
        self.engine = engine
        // TextKit 1 para tener la altura exacta del texto completo.
        textView = UITextView(usingTextLayoutManager: false)
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        clipsToBounds = true
        backgroundColor = .clear

        textView.isEditable = false
        textView.isSelectable = false
        textView.isScrollEnabled = true
        textView.showsVerticalScrollIndicator = false
        textView.backgroundColor = .clear
        textView.textContainer.lineFragmentPadding = 0
        textView.contentInsetAdjustmentBehavior = .never
        textView.layoutManager.allowsNonContiguousLayout = false
        addSubview(textView)

        fade.colors = [UIColor.clear.cgColor, UIColor.white.withAlphaComponent(0.4).cgColor,
                       UIColor.white.cgColor, UIColor.white.cgColor, UIColor.clear.cgColor]
        layer.mask = fade

        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    func configure(_ new: Configuration) {
        guard new != configuration else { return }
        let textChanged = new.text != configuration?.text || new.fontSize != configuration?.fontSize
            || new.centered != configuration?.centered || new.shadowed != configuration?.shadowed
        configuration = new
        if textChanged {
            textView.attributedText = Self.attributed(new)
            laidOutWidth = 0
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let configuration, bounds.width > 0 else { return }
        textView.frame = bounds.insetBy(dx: configuration.horizontalPadding, dy: 0)
        let guideY = (bounds.height * configuration.guideRatio).rounded()
        textView.contentInset = UIEdgeInsets(top: guideY, left: 0, bottom: bounds.height, right: 0)

        if laidOutWidth != textView.bounds.width {
            laidOutWidth = textView.bounds.width
            textView.layoutManager.ensureLayout(for: textView.textContainer)
            let used = textView.layoutManager.usedRect(for: textView.textContainer)
            contentHeight = max(1, ceil(used.height))
            engine.measuredHeight = Double(contentHeight)
        }

        let guide = (guideY / bounds.height).clamped(to: 0.05...0.8)
        let soft = min(configuration.fontSize * 0.9 / bounds.height, guide * 0.5)
        fade.frame = bounds
        fade.locations = [0, NSNumber(value: Double(guide * 0.35)), NSNumber(value: Double(guide - soft)),
                          NSNumber(value: Double(guide)), NSNumber(value: 0.84), 1]
        fade.colors = [UIColor.clear.cgColor, UIColor.white.withAlphaComponent(0.32).cgColor,
                       UIColor.white.withAlphaComponent(0.45).cgColor, UIColor.white.cgColor,
                       UIColor.white.cgColor, UIColor.clear.cgColor]
        lastOffset = .nan
        tick()
    }

    @objc private func tick() {
        guard let configuration, bounds.height > 0 else { return }
        let guideY = (bounds.height * configuration.guideRatio).rounded()
        let offset = (CGFloat(engine.progress()) * contentHeight - guideY).rounded(.toNearestOrAwayFromZero)
        guard offset != lastOffset else { return }
        lastOffset = offset
        textView.contentOffset = CGPoint(x: 0, y: offset)
    }

    private static func attributed(_ configuration: Configuration) -> NSAttributedString {
        let font = UIFont(name: AppFont.name(.text, .semibold), size: configuration.fontSize)
            ?? UIFont.systemFont(ofSize: configuration.fontSize, weight: .semibold)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = configuration.centered ? .center : .natural
        paragraph.lineSpacing = configuration.fontSize * 0.22
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.white,
            .paragraphStyle: paragraph,
        ]
        if configuration.shadowed {
            let shadow = NSShadow()
            shadow.shadowColor = UIColor.black.withAlphaComponent(0.85)
            shadow.shadowBlurRadius = 6
            shadow.shadowOffset = CGSize(width: 0, height: 1)
            attributes[.shadow] = shadow
        }
        return NSAttributedString(string: configuration.text, attributes: attributes)
    }
}
