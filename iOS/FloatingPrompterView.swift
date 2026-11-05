import SwiftUI

/// Pantalla para abrir la ventana flotante y usarla sobre otra app de grabación.
struct FloatingPrompterView: View {
    let text: String
    @ObservedObject var settings: PrompterSettings
    @StateObject private var floating: FloatingPrompter
    @Environment(\.dismiss) private var dismiss

    init(text: String, settings: PrompterSettings) {
        self.text = text
        self.settings = settings
        _floating = StateObject(wrappedValue: FloatingPrompter(settings: settings))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                preview

                Button {
                    floating.toggleWindow()
                } label: {
                    Label(floating.isActive ? "Close floating window" : "Open floating window",
                          image: floating.isActive ? "hi-pip-exit" : "hi-pip")
                }
                .buttonStyle(PrimaryButtonStyle(prominent: !floating.isActive))
                .disabled(!floating.isSupported)
                .accessibilityIdentifier("toggle-pip")

                statusLine

                Picker("Window shape", selection: $settings.floatingVertical) {
                    Label("Horizontal", image: "hi-landscape").tag(false)
                    Label("Vertical", image: "hi-portrait").tag(true)
                }
                .pickerStyle(.segmented)

                autoStartCard

                HStack(spacing: 12) {
                    CircleButton(icon: .previous) { floating.engine.stop() }
                    EngineToggle(engine: floating.engine)
                    Spacer(minLength: 0)
                    ElapsedLabel(engine: floating.engine)
                }

                QuickAdjustBar(settings: settings)
                    .frame(maxWidth: .infinity)

                steps
            }
            .padding(20)
        }
        .background(Theme.background.ignoresSafeArea())
        .safeAreaInset(edge: .top) {
            HStack {
                CircleButton(icon: .cancel) { dismiss() }
                Spacer()
                Text("Floating prompter")
                    .textStyle(.headline)
                Spacer()
                CircleButton(icon: .mirror,
                             active: settings.mirror) {
                    settings.mirror.toggle()
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Theme.background)
        }
        .onAppear { floating.prepare(text: text) }
        .onDisappear { floating.tearDown() }
        .keepsScreenAwake()
    }

    private var preview: some View {
        SampleBufferHost(view: floating.hostView)
            .aspectRatio(settings.floatingVertical ? 3 / 4 : 4 / 3, contentMode: .fit)
            .frame(maxHeight: 360)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                if floating.isActive {
                    VStack(spacing: 10) {
                        HugeIcon(.pip, size: 32)
                            .foregroundStyle(Theme.accent)
                        Text("Your script is in the floating window.\nOpen the app you'll record with.")
                            .textStyle(.callout)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(Theme.secondaryText)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.surface))
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
            .animation(.easeOut(duration: 0.2), value: settings.floatingVertical)
            .onTapGesture { floating.engine.togglePlay() }
    }

    private var statusLine: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(floating.windowState.label)
                .textStyle(.footnote)
                .foregroundStyle(Theme.secondaryText)
            if let signal = floating.lastSignal {
                Text("· \(signal)")
                    .textStyle(.footnote)
                    .foregroundStyle(.white.opacity(0.85))
            }
            Spacer(minLength: 0)
        }
    }

    private var statusColor: Color {
        switch floating.windowState {
        case .preparing: Theme.tertiaryText
        case .ready: Theme.accent
        case .open: .green
        case .failed: Theme.record
        }
    }

    private var autoStartCard: some View {
        Toggle(isOn: $settings.floatingAutoStart) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Auto-start")
                    .textStyle(.headline)
                Text(settings.floatingAutoStart
                     ? "When you start recording in another app, it counts down and starts on its own"
                     : "Off: you start it with ▶ in the window")
                    .textStyle(.footnote, weight: .regular)
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .tint(Theme.accent)
        .padding(16)
        .card()
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("How to use it")
                .textStyle(.headline)
            StepRow(number: 1, text: "Tap **Open floating window**.")
            StepRow(number: 2, text: "Open the app you'll record with: Camera, Instagram, TikTok, WhatsApp…")
            if settings.floatingAutoStart {
                StepRow(number: 3, text: "Hit record. Cue notices, \(countdownText) and the text starts on its own. When you stop recording, it pauses.")
            } else {
                StepRow(number: 3, text: "Start recording and tap **▶** in the window. \(countdownText.capitalizedFirst) and the text starts.")
            }
            StepRow(number: 4, text: "Pinch the window to resize it and drag it close to the camera.")
            Rectangle().fill(Theme.hairline).frame(height: 1)
            Label {
                Text("Cue knows you're recording because iOS pauses its audio when another app starts recording. If an app doesn't do this, tap **▶** in the window. While the window is open, your music is paused.")
            } icon: {
                HugeIcon(.info, size: 20)
            }
            .textStyle(.footnote, weight: .regular)
            .foregroundStyle(Theme.tertiaryText)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var countdownText: String {
        settings.countdown > 0 ? String(localized: "counts down \(settings.countdown) seconds") : String(localized: "skips the countdown")
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// Reproducir/pausa para probar dentro de la app.
private struct EngineToggle: View {
    @ObservedObject var engine: PrompterEngine

    var body: some View {
        Button {
            engine.togglePlay()
        } label: {
            Label(engine.isActive ? "Pause" : "Try it here",
                  image: engine.isActive ? "hi-pause" : "hi-play")
                .textStyle(.callout, weight: .semibold)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(Pill().fill(Theme.surfaceStrong))
        }
        .buttonStyle(PressableStyle())
        .foregroundStyle(.white)
    }
}

private struct StepRow: View {
    let number: Int
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .textStyle(.footnote, weight: .bold)
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Theme.accent))
            Text(text)
                .textStyle(.callout, weight: .regular)
                .foregroundStyle(.white.opacity(0.88))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct SampleBufferHost: UIViewRepresentable {
    let view: SampleBufferView
    func makeUIView(context: Context) -> SampleBufferView { view }
    func updateUIView(_ uiView: SampleBufferView, context: Context) {}
}
