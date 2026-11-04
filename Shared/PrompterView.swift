import SwiftUI

/// Texto del guion avanzando, con línea de lectura, degradados y cuenta regresiva.
struct PrompterView: View {
    @ObservedObject var engine: PrompterEngine
    @ObservedObject var settings: PrompterSettings
    /// Multiplica el tamaño de letra de los ajustes (útil en paneles pequeños).
    var fontScale: Double = 1
    /// Altura de la línea de lectura, como fracción del alto.
    var guideRatio: CGFloat = 0.3
    var horizontalPadding: CGFloat = 28
    var tapToToggle = true
    var showsProgress = true
    /// Sombra en el texto para leer encima del video.
    var shadowed = false
    /// Oculta la flecha y la banda de lectura (sobre la cámara se ve más limpio).
    var showsGuide = true

    @State private var contentHeight: CGFloat = 1
    @State private var lastDrag: CGFloat?

    private var fontSize: CGFloat { CGFloat(settings.fontSize * fontScale) }

    var body: some View {
        GeometryReader { geo in
            let guideY = (geo.size.height * guideRatio).rounded()
            let lineCenter = guideY + fontSize * 0.62
            ZStack(alignment: .topLeading) {
                if showsGuide {
                    // Banda suave en la línea de lectura.
                    LinearGradient(colors: [Theme.accent.opacity(0), Theme.accent.opacity(0.07), Theme.accent.opacity(0)],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(height: fontSize * 1.35)
                        .offset(y: lineCenter - fontSize * 0.675)
                }

                movingText(size: geo.size, guideY: guideY)

                if showsProgress && engine.phase != .ready {
                    // Pocas veces por segundo basta para una barra fina.
                    TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                        ProgressLine(progress: engine.progress())
                            .frame(width: geo.size.width, height: geo.size.height, alignment: .bottomLeading)
                    }
                }

                if showsGuide {
                    GuideMarker()
                        .frame(width: 11, height: 18)
                        .offset(x: 7, y: lineCenter - 9)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .clipped()
            .scaleEffect(x: settings.mirror ? -1 : 1, y: 1)
            .contentShape(Rectangle())
            .gesture(dragGesture)
            .onTapGesture { if tapToToggle { engine.togglePlay() } }
            .overlay { CountdownOverlay(phase: engine.phase) }
        }
    }

    @ViewBuilder
    private func movingText(size: CGSize, guideY: CGFloat) -> some View {
        #if os(iOS)
        ScrollingTextView(engine: engine, text: engine.text, fontSize: fontSize, centered: settings.centered,
                          guideRatio: guideRatio, horizontalPadding: horizontalPadding, shadowed: shadowed)
            .frame(width: size.width, height: size.height)
        #else
        TimelineView(.animation(paused: !engine.isPlaying)) { _ in
            scriptText
                .frame(width: max(0, size.width - horizontalPadding * 2),
                       alignment: settings.centered ? .top : .topLeading)
                .offset(x: horizontalPadding, y: guideY - CGFloat(engine.progress()) * contentHeight)
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .clipped()
                .mask(fadeMask(height: size.height, guideY: guideY))
        }
        #endif
    }

    private var scriptText: some View {
        Text(engine.text)
            .font(.text(fontSize, .semibold))
            .foregroundStyle(.white)
            .multilineTextAlignment(settings.centered ? .center : .leading)
            .lineSpacing(fontSize * 0.22)
            .fixedSize(horizontal: false, vertical: true)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height)
                }
            }
            .onPreferenceChange(ContentHeightKey.self) { height in
                contentHeight = max(1, height)
                engine.measuredHeight = Double(contentHeight)
            }
    }

    /// Lo ya leído (arriba) se atenúa; abajo se desvanece al borde.
    private func fadeMask(height: CGFloat, guideY: CGFloat) -> some View {
        let h = max(height, 1)
        let guide = (guideY / h).clamped(to: 0.05...0.8)
        let soft = min(fontSize * 0.9 / h, guide * 0.5)
        return LinearGradient(stops: [
            .init(color: .white.opacity(0), location: 0),
            .init(color: .white.opacity(0.32), location: guide * 0.35),
            .init(color: .white.opacity(0.42), location: guide - soft),
            .init(color: .white, location: guide),
            .init(color: .white, location: max(guide + 0.01, 0.82)),
            .init(color: .white.opacity(0), location: 1),
        ], startPoint: .top, endPoint: .bottom)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                let previous = lastDrag ?? 0
                lastDrag = value.translation.height
                let delta = value.translation.height - previous
                engine.scrub(points: -Double(delta))
            }
            .onEnded { _ in lastDrag = nil }
    }
}

private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 1
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Línea fina de progreso del guion.
private struct ProgressLine: View {
    let progress: Double

    var body: some View {
        GeometryReader { geo in
            Pill()
                .fill(Theme.accent)
                .frame(width: max(3, geo.size.width * CGFloat(progress)), height: 3)
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .frame(height: 3)
        .allowsHitTesting(false)
    }
}

/// Flecha que marca la altura de lectura.
struct GuideMarker: View {
    var body: some View {
        Triangle()
            .fill(Theme.accent)
    }
}

/// Número grande con anillo que se vacía cada segundo.
struct CountdownOverlay: View {
    let phase: PrompterEngine.Phase

    var body: some View {
        GeometryReader { geo in
            if case .countdown(let number) = phase {
                let side = min(min(geo.size.width, geo.size.height) * 0.62, 190)
                CountdownBadge(number: number, side: side)
                    .id(number)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .transition(.scale(scale: 1.25).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: phase)
        .allowsHitTesting(false)
    }
}

private struct CountdownBadge: View {
    let number: Int
    let side: CGFloat
    @State private var ring: CGFloat = 1

    var body: some View {
        ZStack {
            Circle().fill(.black.opacity(0.7))
            Circle().fill(RadialGradient(colors: [Theme.accent.opacity(0.18), .clear],
                                         center: .center, startRadius: 0, endRadius: side * 0.5))
            Circle().stroke(.white.opacity(0.1), lineWidth: side * 0.045)
            Circle()
                .trim(from: 0, to: ring)
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: side * 0.045, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(number)")
                .roundedText(size: side * 0.5, weight: .bold)
                .monospacedDigit()
                .foregroundStyle(.white)
        }
        .padding(side * 0.04)
        .frame(width: side, height: side)
        .onAppear {
            withAnimation(.linear(duration: 1)) { ring = 0 }
        }
    }
}

/// Tiempo transcurrido y restante.
struct ElapsedLabel: View {
    @ObservedObject var engine: PrompterEngine
    var showsRemaining = true

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            HStack(spacing: 6) {
                Text(TimeFormat.clock(engine.elapsed()))
                    .foregroundStyle(.white)
                if showsRemaining {
                    Text("−" + TimeFormat.clock(engine.remaining()))
                        .foregroundStyle(Theme.tertiaryText)
                }
            }
            .font(.mono(12, .medium))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("elapsed")
        }
    }
}

/// Botones − valor + en forma de cápsula de vidrio.
struct StepperPill: View {
    let icon: HugeIcon.Name
    let value: String
    let decrease: () -> Void
    let increase: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: decrease) {
                HugeIcon(.minus, size: 13).frame(width: 34, height: 34).contentShape(Rectangle())
            }
            HStack(spacing: 5) {
                HugeIcon(icon, size: 14)
                    .foregroundStyle(Theme.accent)
                Text(value)
                    .font(.mono(12, .medium))
            }
            .frame(minWidth: 54)
            Button(action: increase) {
                HugeIcon(.plus, size: 13).frame(width: 34, height: 34).contentShape(Rectangle())
            }
        }
        .buttonStyle(PressableStyle())
        .foregroundStyle(.white)
        .glass(in: Pill(), tint: 0.6)
    }
}

/// Velocidad y tamaño de letra, para usar dentro de cualquier prompter.
struct QuickAdjustBar: View {
    @ObservedObject var settings: PrompterSettings

    var body: some View {
        HStack(spacing: 10) {
            StepperPill(icon: .speed,
                        value: "\(Int(settings.wordsPerMinute))",
                        decrease: { settings.adjustSpeed(by: -10) },
                        increase: { settings.adjustSpeed(by: 10) })
            .help("Speed (words per minute)")
            StepperPill(icon: .textSize,
                        value: "\(Int(settings.fontSize))",
                        decrease: { settings.adjustFont(by: -4) },
                        increase: { settings.adjustFont(by: 4) })
            .help("Text size")
        }
    }
}
