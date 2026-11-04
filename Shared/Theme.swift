import CoreText
import SwiftUI

/// Estilo visual de Pronter: vidrio negro, botones perla (plata) y acento azul.
enum Theme {
    /// Azul de marca #0A84FF (AccentColor del catálogo de cada app). Para lo activo / en vivo / IA:
    /// escuchando, reproduciendo, selección, línea de lectura, interruptores. Encima va texto blanco.
    static let accent = Color.accentColor
    /// Negro puro (#000).
    static let background = Color.black
    static let surface = Color.white.opacity(0.055)
    static let surfaceStrong = Color.white.opacity(0.10)
    static let hairline = Color.white.opacity(0.10)
    static let secondaryText = Color.white.opacity(0.64)
    static let tertiaryText = Color.white.opacity(0.40)
    static let record = Color(red: 1.0, green: 0.3, blue: 0.32)

    /// Borde de vidrio: más brillante arriba, casi invisible abajo.
    static let glassStroke = LinearGradient(colors: [.white.opacity(0.26), .white.opacity(0.08), .white.opacity(0.14)],
                                            startPoint: .top, endPoint: .bottom)
    /// Relleno de los botones claros.
    static let pearl = LinearGradient(colors: [.white, Color(white: 0.84)], startPoint: .top, endPoint: .bottom)

    /// Ventana principal del Mac. Sin bordes ni sombras: la jerarquía sale de grises cada vez más claros
    /// (página → panel → tarjeta → control). El notch sigue en negro puro para fundirse con el hardware.
    enum Window {
        /// Respaldo de la página si no hay vidrio: gris muy oscuro, no negro puro.
        static let page = Color(hex: 0x0B0C0E)
        /// Negro sobre el vidrio de la barra lateral (lo de detrás se ve desenfocado y oscuro, como el notch).
        static let glassTint = 0.55
        /// Panel del contenido (opaco), un paso más claro.
        static let panel = Color(hex: 0x151618)
        /// Tarjetas y chips dentro del panel.
        static let raised = Color(hex: 0x1C1D20)
        /// Controles dentro de una tarjeta.
        static let control = Color(hex: 0x26272B)
        /// Fila elegida / controles sobre el vidrio de la barra lateral.
        static let onGlass = Color.white.opacity(0.08)
        /// Texto principal: blanco suavizado.
        static let text = Color(hex: 0xEFF0F2)
        static let secondaryText = Color(hex: 0xA1A3AA)
        static let tertiaryText = Color(hex: 0x6C6F77)
        /// El azul de marca, más claro, para íconos y texto pequeño sobre fondo oscuro.
        static let accentText = Color(hex: 0x4DA8FF)
    }
}

extension Color {
    /// Color sRGB desde 0xRRGGBB.
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}

// MARK: Tipografía

/// Familias de la app: SN Pro (interfaz y títulos), Hanken Grotesk (texto de lectura) y Geist Mono (cifras y atajos).
/// Van en `Shared/Fonts` como estáticas por peso; se registran al arrancar con `AppFont.registerAll()`.
enum AppFont {
    enum Family {
        /// SN Pro: botones, etiquetas, títulos.
        case display
        /// Hanken Grotesk: párrafos, sugerencias, guion.
        case text
        /// Geist Mono: tiempos, contadores, teclas.
        case mono
    }

    private static let files = [
        "SNPro-Regular", "SNPro-Medium", "SNPro-Semibold", "SNPro-Bold",
        "HankenGrotesk-Regular", "HankenGrotesk-Medium", "HankenGrotesk-SemiBold", "HankenGrotesk-Bold",
        "GeistMono-Regular", "GeistMono-Medium", "GeistMono-SemiBold",
    ]

    private static var registered = false

    /// Registra las fuentes del bundle para este proceso. Llamar una vez al arrancar.
    static func registerAll() {
        guard !registered else { return }
        registered = true
        for name in files {
            guard let url = Bundle.main.url(forResource: name, withExtension: "ttf") else {
                NSLog("Pronter: falta la fuente %@", name)
                continue
            }
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                NSLog("Pronter: no se pudo registrar %@: %@", name, String(describing: error?.takeRetainedValue()))
            }
        }
    }

    /// Nombre PostScript del archivo estático más cercano al peso pedido.
    static func name(_ family: Family, _ weight: Font.Weight) -> String {
        switch family {
        case .display:
            switch weight {
            case .bold, .heavy, .black: "SNPro-Bold"
            case .semibold: "SNPro-Semibold"
            case .medium: "SNPro-Medium"
            default: "SNPro-Regular"
            }
        case .text:
            switch weight {
            case .bold, .heavy, .black: "HankenGrotesk-Bold"
            case .semibold: "HankenGrotesk-SemiBold"
            case .medium: "HankenGrotesk-Medium"
            default: "HankenGrotesk-Regular"
            }
        case .mono:
            switch weight {
            case .semibold, .bold, .heavy, .black: "GeistMono-SemiBold"
            case .medium: "GeistMono-Medium"
            default: "GeistMono-Regular"
            }
        }
    }
}

extension Font {
    /// SN Pro de tamaño fijo (interfaz).
    static func display(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        .custom(AppFont.name(.display, weight), fixedSize: size)
    }

    /// Hanken Grotesk de tamaño fijo (lectura).
    static func text(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom(AppFont.name(.text, weight), fixedSize: size)
    }

    /// Geist Mono de tamaño fijo (cifras, tiempos, teclas).
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        .custom(AppFont.name(.mono, weight), fixedSize: size)
    }
}

/// Escala tipográfica. Títulos y etiquetas en SN Pro; párrafos en Hanken Grotesk. Solo los títulos llevan tracking negativo.
enum TextStyle {
    case display, title, headline, body, callout, footnote, caption

    var size: CGFloat {
        switch self {
        case .display: 34
        case .title: 24
        case .headline: 17
        case .body: 17
        case .callout: 15
        case .footnote: 13
        case .caption: 12
        }
    }

    var weight: Font.Weight {
        switch self {
        case .display, .title: .bold
        case .headline: .semibold
        case .body: .regular
        case .callout, .footnote: .medium
        case .caption: .semibold
        }
    }

    /// Familia por defecto de cada estilo.
    var family: AppFont.Family {
        switch self {
        case .display, .title, .headline, .caption: .display
        case .body, .callout, .footnote: .text
        }
    }

    var relativeTo: Font.TextStyle {
        switch self {
        case .display: .largeTitle
        case .title: .title
        case .headline: .headline
        case .body: .body
        case .callout: .callout
        case .footnote: .footnote
        case .caption: .caption
        }
    }
}

/// Tracking negativo solo para texto grande (títulos).
private func titleTracking(for size: CGFloat) -> CGFloat {
    size >= 22 ? size * -0.025 : 0
}

private struct ScaledText: ViewModifier {
    @ScaledMetric private var size: CGFloat
    private let weight: Font.Weight
    private let family: AppFont.Family

    init(size: CGFloat, weight: Font.Weight, family: AppFont.Family, relativeTo: Font.TextStyle) {
        _size = ScaledMetric(wrappedValue: size, relativeTo: relativeTo)
        self.weight = weight
        self.family = family
    }

    func body(content: Content) -> some View {
        content
            .font(.custom(AppFont.name(family, weight), fixedSize: size))
            .tracking(titleTracking(for: size))
    }
}

extension View {
    /// Estilo de la escala de la app (se adapta al tamaño de texto del sistema en iOS).
    func textStyle(_ style: TextStyle, weight: Font.Weight? = nil, family: AppFont.Family? = nil) -> some View {
        modifier(ScaledText(size: style.size, weight: weight ?? style.weight,
                            family: family ?? style.family, relativeTo: style.relativeTo))
    }

    /// SN Pro (o la familia indicada) de tamaño fijo, con tracking de título si es grande.
    func roundedText(size: CGFloat, weight: Font.Weight = .regular, family: AppFont.Family = .display) -> some View {
        font(.custom(AppFont.name(family, weight), fixedSize: size))
            .tracking(titleTracking(for: size))
    }

    /// Resplandor suave. Solo para estados que deben llamar la atención (grabando).
    func glow(_ color: Color, radius: CGFloat = 10) -> some View {
        shadow(color: color.opacity(0.55), radius: radius)
    }

    /// Tarjeta oscura con borde fino de vidrio.
    func card(radius: CGFloat = 20) -> some View {
        background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.glassStroke, lineWidth: 1))
    }

    /// Superficie sin borde: un gris más claro que el fondo (ventana del Mac).
    func surface(_ color: Color = Theme.Window.raised, radius: CGFloat = 14) -> some View {
        background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(color))
    }

    /// Vidrio negro: material translúcido, tinte oscuro y borde con brillo arriba.
    func glass(radius: CGFloat = 16, tint: Double = 0.45) -> some View {
        glass(in: RoundedRectangle(cornerRadius: radius, style: .continuous), tint: tint)
    }

    func glass<S: InsettableShape>(in shape: S, tint: Double = 0.45) -> some View {
        background {
            shape.fill(.ultraThinMaterial)
                .overlay(shape.fill(Color.black.opacity(tint)))
        }
        .overlay(shape.strokeBorder(Theme.glassStroke, lineWidth: 1))
        .environment(\.colorScheme, .dark)
    }
}

// MARK: Botones

/// Botón principal: cápsula perla con texto negro. `prominent: false` da la versión de vidrio;
/// `accent: true`, la azul (para acciones que arrancan algo).
struct PrimaryButtonStyle: ButtonStyle {
    var prominent = true
    var accent = false

    func makeBody(configuration: Configuration) -> some View {
        PrimaryButton(configuration: configuration, prominent: prominent, accent: accent)
    }

    private struct PrimaryButton: View {
        let configuration: Configuration
        let prominent: Bool
        let accent: Bool
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .textStyle(.headline)
                .foregroundStyle(prominent && !accent ? Color.black : Color.white)
                .padding(.vertical, 15)
                .padding(.horizontal, 22)
                .frame(maxWidth: .infinity)
                .background {
                    if accent {
                        Pill().fill(Theme.accent)
                    } else if prominent {
                        Pill().fill(Theme.pearl)
                    } else {
                        Pill().fill(Theme.surfaceStrong)
                    }
                }
                .overlay(Pill().strokeBorder(accent ? AnyShapeStyle(Color.white.opacity(0.22))
                                             : prominent ? AnyShapeStyle(Color.white.opacity(0.6)) : AnyShapeStyle(Theme.glassStroke),
                                             lineWidth: 1))
                .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }
}

/// Se encoge un poco al tocar.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Botón redondo. Acepta un SF Symbol (`systemImage`) o un ícono de Hugeicons (`icon`).
struct CircleButton: View {
    var systemImage: String?
    var icon: HugeIcon.Name?
    var size: CGFloat = 44
    var active = false
    let action: () -> Void

    init(systemImage: String, size: CGFloat = 44, active: Bool = false, action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.size = size
        self.active = active
        self.action = action
    }

    init(icon: HugeIcon.Name, size: CGFloat = 44, active: Bool = false, action: @escaping () -> Void) {
        self.icon = icon
        self.size = size
        self.active = active
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Group {
                if let icon {
                    HugeIcon(icon, size: size * 0.46, filled: true)
                } else if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: size * 0.38, weight: .semibold, design: .default))
                }
            }
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Circle().fill(active ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.white.opacity(0.07))))
                .background(Circle().fill(.ultraThinMaterial))
                .overlay(Circle().strokeBorder(Theme.glassStroke, lineWidth: 1))
        }
        .buttonStyle(PressableStyle())
    }
}

// MARK: Íconos

/// Ícono de Hugeicons (trazo redondeado, licencia MIT) de `Shared/Hugeicons.xcassets`.
/// Es una plantilla: toma el color de `foregroundStyle`.
/// Regla: dentro de botones redondos va relleno (`filled: true`); suelto junto a texto, en trazo.
struct HugeIcon: View {
    enum Name: String {
        case aiMagic = "hi-ai-magic"
        case alert = "hi-alert"
        case arrowDown = "hi-arrow-down"
        case audioWave = "hi-audio-wave"
        case chat = "hi-chat"
        case checkCircle = "hi-check-circle"
        case clock = "hi-clock"
        case command = "hi-command"
        case control = "hi-control"
        case copy = "hi-copy"
        case delete = "hi-delete"
        case file = "hi-file"
        case folder = "hi-folder"
        case info = "hi-info"
        case layoutTop = "hi-layout-top"
        case magicWand = "hi-magic-wand"
        case mic = "hi-mic"
        case minus = "hi-minus"
        case mirror = "hi-mirror"
        case more = "hi-more"
        case noteEdit = "hi-note-edit"
        case option = "hi-option"
        case pause = "hi-pause"
        case play = "hi-play"
        case plus = "hi-plus"
        case previous = "hi-previous"
        case quote = "hi-quote"
        case returnKey = "hi-return"
        case settings = "hi-settings"
        case speed = "hi-speed"
        case stop = "hi-stop"
        case textAlignLeft = "hi-text-align-left"
        case textSize = "hi-text-size"
        case unfold = "hi-unfold"
        case video = "hi-video"
    }

    /// Íconos con variante rellena (`hi-…-fill`, generada con `tools/hugeicons2svg.mjs --fill`).
    static let fillable: Set<Name> = [.aiMagic, .file, .mic, .mirror, .pause, .play, .previous, .stop]

    let name: Name
    var size: CGFloat
    var filled: Bool

    init(_ name: Name, size: CGFloat = 16, filled: Bool = false) {
        self.name = name
        self.size = size
        self.filled = filled
    }

    private var assetName: String {
        filled && Self.fillable.contains(name) ? name.rawValue + "-fill" : name.rawValue
    }

    var body: some View {
        Image(assetName)
            .renderingMode(.template)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Etiqueta pequeña con ícono.
struct Chip: View {
    let systemImage: String
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
            Text(text)
        }
        .textStyle(.caption)
        .foregroundStyle(Theme.secondaryText)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Pill().fill(Theme.surface))
    }
}

/// Marca de Pronter: el icono de la app completo (cuadrado claro con la píldora negra).
struct LogoMark: View {
    var size: CGFloat = 30

    var body: some View {
        Image("BrandMark")
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(height: size)
            .accessibilityHidden(true)
    }
}

struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
        }
    }
}

/// Cápsula dibujada a mano. En macOS 27, `Capsule` (y `RoundedRectangle` con radio = media altura)
/// sale con los extremos planos y rayas sueltas a los lados; esta forma no.
struct Pill: InsettableShape {
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: insetAmount, dy: insetAmount)
        guard r.width > 0, r.height > 0 else { return Path() }
        let radius = min(r.width, r.height) / 2
        var path = Path()
        if r.width >= r.height {
            path.move(to: CGPoint(x: r.minX + radius, y: r.minY))
            path.addLine(to: CGPoint(x: r.maxX - radius, y: r.minY))
            path.addArc(center: CGPoint(x: r.maxX - radius, y: r.midY), radius: radius,
                        startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
            path.addLine(to: CGPoint(x: r.minX + radius, y: r.maxY))
            path.addArc(center: CGPoint(x: r.minX + radius, y: r.midY), radius: radius,
                        startAngle: .degrees(90), endAngle: .degrees(270), clockwise: false)
        } else {
            path.move(to: CGPoint(x: r.maxX, y: r.minY + radius))
            path.addLine(to: CGPoint(x: r.maxX, y: r.maxY - radius))
            path.addArc(center: CGPoint(x: r.midX, y: r.maxY - radius), radius: radius,
                        startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
            path.addLine(to: CGPoint(x: r.minX, y: r.minY + radius))
            path.addArc(center: CGPoint(x: r.midX, y: r.minY + radius), radius: radius,
                        startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
        }
        path.closeSubpath()
        return path
    }

    func inset(by amount: CGFloat) -> Pill {
        var copy = self
        copy.insetAmount += amount
        return copy
    }
}
