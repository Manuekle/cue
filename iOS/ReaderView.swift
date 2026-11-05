import SwiftUI

/// Prompter a pantalla completa (sin cámara).
struct ReaderView: View {
    let text: String
    @ObservedObject var settings: PrompterSettings
    @StateObject private var engine = PrompterEngine()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            PrompterView(engine: engine, settings: settings)
                .ignoresSafeArea(edges: .bottom)

            VStack {
                HStack {
                    CircleButton(icon: .cancel) { dismiss() }
                    Spacer()
                    ElapsedLabel(engine: engine)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(Pill().fill(Color.black.opacity(0.45)))
                        .overlay(Pill().strokeBorder(Theme.hairline, lineWidth: 1))
                    Spacer()
                    CircleButton(icon: .mirror,
                                 active: settings.mirror) {
                        settings.mirror.toggle()
                    }
                }
                .padding(.horizontal, 16)

                Spacer()

                if !engine.isActive {
                    PlaybackControls(engine: engine, settings: settings)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.snappy, value: engine.isActive)
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .keepsScreenAwake()
        .syncing(engine, with: settings)
        .onAppear { engine.load(text: text, reset: true) }
        .sensoryFeedback(.impact(weight: .light), trigger: engine.phase)
    }
}

/// Botón grande de reproducir + reiniciar + ajustes rápidos.
struct PlaybackControls: View {
    @ObservedObject var engine: PrompterEngine
    @ObservedObject var settings: PrompterSettings

    var body: some View {
        VStack(spacing: 16) {
            Text(hint)
                .textStyle(.footnote)
                .foregroundStyle(Theme.secondaryText)
            HStack(spacing: 30) {
                CircleButton(icon: .previous) { engine.stop() }
                    .disabled(engine.phase == .ready)
                    .opacity(engine.phase == .ready ? 0.4 : 1)
                PlayButton { engine.togglePlay() }
                CircleButton(icon: settings.centered ? .textAlignCenter : .textAlignLeft) {
                    settings.centered.toggle()
                }
            }
            QuickAdjustBar(settings: settings)
        }
        .padding(.top, 52)
        .padding(.bottom, 18)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity)
        .background(LinearGradient(stops: [.init(color: .clear, location: 0),
                                           .init(color: Theme.background.opacity(0.97), location: 0.22),
                                           .init(color: Theme.background, location: 1)],
                                   startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea())
    }

    private var hint: String {
        switch engine.phase {
        case .finished: String(localized: "End of script · ▶ to replay")
        case .paused: String(localized: "Paused · drag the text to move")
        default: settings.countdown > 0 ? String(localized: "▶ counts \(settings.countdown) and starts · tap the text to pause") : String(localized: "▶ to start · tap the text to pause")
        }
    }
}

/// Botón grande de reproducir.
struct PlayButton: View {
    var icon: HugeIcon.Name = .play
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HugeIcon(icon, size: 30, filled: true)
                .foregroundStyle(.white)
                .offset(x: icon == .play ? 2 : 0)
                .frame(width: 78, height: 78)
                .background(Circle().fill(Theme.accent))
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel("Start")
    }
}
