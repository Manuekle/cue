import SwiftUI

/// Graba con la cámara de Pronter, al estilo de las apps de creadores: el guion va encima
/// del video, cerca del lente, y una barra lateral controla la velocidad.
/// Al tocar grabar hay cuenta regresiva; luego arrancan juntos la grabación y el texto.
/// Con "Seguir mi voz" el texto avanza mientras hablas y espera cuando callas.
struct CameraRecordView: View {
    let text: String
    @ObservedObject var settings: PrompterSettings
    @StateObject private var camera = CameraModel()
    @StateObject private var engine = PrompterEngine()
    @State private var showsFilters = false
    @State private var ringLight = false
    @State private var pausedBySilence = false
    @State private var pinchBase: Double?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            ZStack {
                Color.black.ignoresSafeArea()
                cameraLayer.ignoresSafeArea()

                // Oscurece arriba para leer el guion sobre el video.
                LinearGradient(stops: [.init(color: .black.opacity(0.78), location: 0),
                                       .init(color: .black.opacity(0.55), location: 0.32),
                                       .init(color: .black.opacity(0), location: 0.56)],
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                VStack(spacing: 0) {
                    topBar
                    PrompterView(engine: engine, settings: settings,
                                 fontScale: 0.9, guideRatio: 0.2, horizontalPadding: 22,
                                 showsProgress: false, shadowed: true, showsGuide: false)
                        .frame(height: geo.size.height * (landscape ? 0.55 : 0.42))
                        .simultaneousGesture(pinchToResize)
                    Spacer(minLength: 0)
                    bottomControls
                }

                SideControlBar(engine: engine, settings: settings, ringLight: $ringLight, waitingForVoice: pausedBySilence)
                    .opacity(showsFilters ? 0 : 1)
                    .allowsHitTesting(!showsFilters)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .padding(.trailing, 12)
                    .offset(y: landscape ? geo.size.height * 0.1 : geo.size.height * 0.13)

                if ringLight {
                    RoundedRectangle(cornerRadius: 46, style: .continuous)
                        .strokeBorder(Color.white, lineWidth: 18)
                        .blur(radius: 3)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }

                if let message = camera.message {
                    Toast(text: message)
                        .task(id: message) {
                            try? await Task.sleep(for: .seconds(2.5))
                            camera.message = nil
                        }
                }
            }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .keepsScreenAwake()
        .syncing(engine, with: settings)
        .onAppear {
            engine.load(text: text, reset: true)
            camera.start()
        }
        .onDisappear {
            camera.stop()
            ScreenBrightness.restore()
        }
        .onChange(of: ringLight) { _, on in
            on ? ScreenBrightness.raise() : ScreenBrightness.restore()
        }
        .onChange(of: camera.isRecording) { _, recording in
            if !recording {
                engine.pause()
                pausedBySilence = false
            }
        }
        .onChange(of: camera.isSpeaking) { _, speaking in
            followVoice(speaking: speaking)
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: engine.phase)
        .sensoryFeedback(.selection, trigger: camera.look)
        .animation(.snappy, value: camera.isRecording)
        .animation(.snappy, value: engine.phase)
        .animation(.easeOut(duration: 0.2), value: ringLight)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: showsFilters)
    }

    @ViewBuilder
    private var cameraLayer: some View {
        switch camera.status {
        case .ready:
            FilteredPreview(view: camera.previewView)
        case .starting:
            Color.black
        case .unavailable(let reason):
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "video.slash")
                    .font(.system(size: 34, weight: .semibold, design: .default))
                Text(reason)
                    .textStyle(.callout, weight: .regular)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 60)
                Spacer().frame(height: 200)
            }
            .foregroundStyle(Theme.secondaryText)
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            CircleButton(systemImage: "xmark", size: 38) { dismiss() }
                .opacity(camera.isRecording ? 0 : 1)
                .disabled(camera.isRecording)
            Spacer()
            if let startedAt = camera.recordingStartedAt {
                RecordingTimer(startedAt: startedAt)
            } else {
                Button {
                    settings.voiceFollow.toggle()
                } label: {
                    Label(settings.voiceFollow ? "Follows my voice" : "Fixed speed",
                          systemImage: settings.voiceFollow ? "waveform" : "gauge.with.dots.needle.33percent")
                        .textStyle(.footnote, weight: .semibold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(Pill().fill(settings.voiceFollow ? Theme.accent : Color.black.opacity(0.5)))
                }
                .buttonStyle(PressableStyle())
            }
            Spacer()
            CircleButton(systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right",
                         size: 38, active: settings.mirror) {
                settings.mirror.toggle()
            }
            .opacity(camera.isRecording ? 0 : 1)
            .disabled(camera.isRecording)
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
    }

    private var bottomControls: some View {
        VStack(spacing: 14) {
            statusLine
            if showsFilters {
                FilterTray(camera: camera)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            HStack {
                CircleButton(systemImage: "camera.filters", size: 52, active: showsFilters) {
                    showsFilters.toggle()
                }
                .accessibilityLabel("Filters")
                Spacer()
                RecordButton(isRecording: camera.isRecording, isCountingDown: engine.isCountingDown) {
                    recordTapped()
                }
                Spacer()
                CircleButton(systemImage: "arrow.triangle.2.circlepath.camera", size: 52) { camera.flip() }
                    .opacity(camera.isRecording || camera.status != .ready ? 0.3 : 1)
                    .disabled(camera.isRecording || camera.status != .ready)
            }
            .padding(.horizontal, 36)
        }
        .padding(.top, 18)
        .padding(.bottom, 10)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea())
    }

    @ViewBuilder
    private var statusLine: some View {
        if engine.isCountingDown {
            hint("Get ready…")
        } else if pausedBySilence {
            hint("Waiting for your voice…", systemImage: "waveform")
        } else if camera.isRecording {
            EmptyView()
        } else if engine.phase == .paused || engine.phase == .finished {
            Button {
                engine.stop()
            } label: {
                Label("Back to the start of the text", systemImage: "arrow.up.to.line")
                    .textStyle(.footnote, weight: .semibold)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Pill().fill(Color.black.opacity(0.5)))
            }
            .buttonStyle(PressableStyle())
            .foregroundStyle(.white)
        } else {
            hint(settings.countdown > 0
                 ? "Tap record: counts \(settings.countdown) and starts on its own"
                 : "Tap record: the text starts with the recording")
        }
    }

    private func hint(_ text: LocalizedStringKey, systemImage: String? = nil) -> some View {
        HStack(spacing: 6) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text)
        }
        .textStyle(.footnote, weight: .semibold)
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Pill().fill(Color.black.opacity(0.5)))
    }

    /// Pellizca el texto para agrandarlo o achicarlo.
    private var pinchToResize: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let base = pinchBase ?? settings.fontSize
                pinchBase = base
                settings.fontSize = (base * value.magnification).clamped(to: PrompterSettings.fontRange)
            }
            .onEnded { _ in pinchBase = nil }
    }

    private func recordTapped() {
        if camera.isRecording {
            camera.stopRecording()
            engine.pause()
            return
        }
        if engine.isCountingDown {
            engine.pause()
            return
        }
        if engine.phase == .finished { engine.stop() }
        if camera.canRecord {
            engine.start {
                camera.startRecording()
                // Con "Seguir mi voz", el texto espera hasta que empieces a hablar.
                if settings.voiceFollow && !camera.isSpeaking {
                    engine.pause()
                    pausedBySilence = true
                }
            }
        } else {
            camera.message = String(localized: "No camera: only the text moves")
            engine.start()
        }
    }

    private func followVoice(speaking: Bool) {
        guard settings.voiceFollow, camera.isRecording, !engine.isCountingDown else { return }
        if speaking {
            if pausedBySilence && engine.phase == .paused {
                engine.start(skipCountdown: true)
            }
            pausedBySilence = false
        } else if engine.isPlaying {
            engine.pause()
            pausedBySilence = true
        }
    }
}

/// Barra vertical a la derecha: velocidad, avanzar/pausar el texto y luz de anillo.
private struct SideControlBar: View {
    @ObservedObject var engine: PrompterEngine
    @ObservedObject var settings: PrompterSettings
    @Binding var ringLight: Bool
    let waitingForVoice: Bool

    var body: some View {
        VStack(spacing: 6) {
            barButton("chevron.up") { settings.adjustSpeed(by: 10) }
            VStack(spacing: 0) {
                Text("\(Int(settings.wordsPerMinute))")
                    .textStyle(.callout, weight: .bold)
                    .monospacedDigit()
                Text("wpm")
                    .textStyle(.caption, weight: .medium)
                    .foregroundStyle(Theme.secondaryText)
            }
            .foregroundStyle(.white)
            barButton("chevron.down") { settings.adjustSpeed(by: -10) }
            Rectangle().fill(Theme.hairline).frame(width: 28, height: 1).padding(.vertical, 4)
            barButton(engine.isActive ? "pause.fill" : "play.fill", active: engine.isActive || waitingForVoice) {
                engine.togglePlay()
            }
            barButton("lightbulb.max.fill", active: ringLight) { ringLight.toggle() }
                .accessibilityLabel("Ring light")
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 6)
        .background(Pill().fill(Color.black.opacity(0.55)))
        .overlay(Pill().strokeBorder(Theme.hairline, lineWidth: 1))
    }

    private func barButton(_ systemImage: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .bold, design: .default))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Circle().fill(active ? Theme.accent : Color.white.opacity(0.08)))
        }
        .buttonStyle(PressableStyle())
    }
}

/// Sube el brillo al máximo mientras la luz de anillo está encendida.
enum ScreenBrightness {
    private static var saved: CGFloat?

    private static var screen: UIScreen? {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }.first
    }

    static func raise() {
        guard let screen else { return }
        if saved == nil { saved = screen.brightness }
        screen.brightness = 1
    }

    static func restore() {
        guard let screen, let saved else { return }
        screen.brightness = saved
        self.saved = nil
    }
}

/// Estilos de color, luz y fondo desenfocado.
private struct FilterTray: View {
    @ObservedObject var camera: CameraModel

    var body: some View {
        VStack(spacing: 14) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(VideoLook.allCases) { look in
                        LookChip(look: look, selected: camera.look == look) {
                            camera.look = look
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 6)
            }
            VStack(spacing: 10) {
                FilterSlider(title: "Light", systemImage: "sun.max.fill", value: $camera.light)
                FilterSlider(title: "Background", systemImage: "person.and.background.dotted", value: $camera.background)
            }
            .padding(.horizontal, 22)
        }
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Color.black.opacity(0.7)))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
        .padding(.horizontal, 12)
    }
}

private struct LookChip: View {
    let look: VideoLook
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Circle()
                    .fill(LinearGradient(colors: look.swatch.map { Color(red: $0.red, green: $0.green, blue: $0.blue) },
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 46, height: 46)
                    .overlay(Circle().strokeBorder(selected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.white.opacity(0.15)),
                                                   lineWidth: selected ? 2.5 : 1))
                    .padding(3)
                Text(look.name)
                    .textStyle(.caption, weight: selected ? .bold : .medium)
                    .foregroundStyle(selected ? Theme.accent : .white.opacity(0.8))
            }
        }
        .buttonStyle(PressableStyle())
    }
}

private struct FilterSlider: View {
    let title: LocalizedStringKey
    let systemImage: String
    @Binding var value: Double

    var body: some View {
        HStack(spacing: 12) {
            Label(title, systemImage: systemImage)
                .textStyle(.footnote, weight: .semibold)
                .foregroundStyle(.white)
                .frame(width: 76, alignment: .leading)
            Slider(value: $value, in: 0...1)
                .tint(Theme.accent)
            Text("\(Int(value * 100))")
                .textStyle(.caption, weight: .semibold)
                .monospacedDigit()
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 28, alignment: .trailing)
        }
    }
}

private struct RecordButton: View {
    let isRecording: Bool
    let isCountingDown: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(.white, lineWidth: 5)
                    .frame(width: 84, height: 84)
                    .glow(isRecording ? Theme.record : .clear, radius: 12)
                if isCountingDown {
                    Image(systemName: "xmark")
                        .font(.system(size: 26, weight: .bold, design: .default))
                        .foregroundStyle(.white)
                        .frame(width: 66, height: 66)
                        .background(Circle().fill(Theme.record.opacity(0.6)))
                } else {
                    RoundedRectangle(cornerRadius: isRecording ? 9 : 33, style: .continuous)
                        .fill(Theme.record)
                        .frame(width: isRecording ? 32 : 66, height: isRecording ? 32 : 66)
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isRecording)
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(isRecording ? "Stop recording" : "Record")
    }
}

private struct RecordingTimer: View {
    let startedAt: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            HStack(spacing: 7) {
                Circle()
                    .fill(Theme.record)
                    .frame(width: 8, height: 8)
                    .glow(Theme.record, radius: 5)
                Text(TimeFormat.clock(context.date.timeIntervalSince(startedAt)))
                    .monospacedDigit()
            }
            .textStyle(.callout, weight: .bold)
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Pill().fill(Theme.record.opacity(0.3)))
            .overlay(Pill().strokeBorder(Theme.record.opacity(0.5), lineWidth: 1))
        }
    }
}

struct Toast: View {
    let text: String

    var body: some View {
        Text(text)
            .textStyle(.callout, weight: .semibold)
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(Pill().fill(.black.opacity(0.6)))
            .background(Pill().fill(Color.black.opacity(0.45)))
            .overlay(Pill().strokeBorder(Theme.hairline, lineWidth: 1))
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
    }
}

private struct FilteredPreview: UIViewRepresentable {
    let view: SampleBufferView
    func makeUIView(context: Context) -> SampleBufferView { view }
    func updateUIView(_ uiView: SampleBufferView, context: Context) {}
}
