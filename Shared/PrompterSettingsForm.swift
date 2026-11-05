import SwiftUI

struct PrompterSettingsForm: View {
    @ObservedObject var settings: PrompterSettings
    var showsAutoStart = false
    @State private var language = AppLanguage.current

    var body: some View {
        Form {
            Section {
                Picker(selection: $language) {
                    ForEach(AppLanguage.allCases) { option in
                        Text(verbatim: option.nativeName).tag(option)
                    }
                } label: {
                    RowLabel(title: "Language", icon: .globe)
                }
                .onChange(of: language) { _, newValue in AppLanguage.choose(newValue) }
                if language != AppLanguage.launched {
                    #if os(macOS)
                    Button("Restart Cue now") { AppLanguage.relaunch() }
                    #endif
                }
            } footer: {
                if language != AppLanguage.launched {
                    #if os(macOS)
                    SectionFooter("Cue needs to restart to change the language.")
                    #else
                    SectionFooter("Close Cue and open it again to change the language.")
                    #endif
                }
            }

            Section {
                SliderRow(title: "Speed", value: String(localized: "\(Int(settings.wordsPerMinute)) words/min"),
                          icon: .speed) {
                    Slider(value: $settings.wordsPerMinute, in: PrompterSettings.speedRange, step: 5)
                }
                SliderRow(title: "Text size", value: "\(Int(settings.fontSize))",
                          icon: .textSize) {
                    Slider(value: $settings.fontSize, in: PrompterSettings.fontRange, step: 1)
                }
                Picker(selection: $settings.centered) {
                    Text("Centered").tag(true)
                    Text("Left").tag(false)
                } label: {
                    RowLabel(title: "Alignment", icon: .textAlignCenter)
                }
            } header: {
                SectionTitle("Reading")
            } footer: {
                SectionFooter("People speak at about 130–160 words per minute.")
            }

            Section {
                Picker(selection: $settings.countdown) {
                    ForEach(PrompterSettings.countdownOptions, id: \.self) { seconds in
                        Text(seconds == 0 ? "No countdown" : "\(seconds) seconds").tag(seconds)
                    }
                } label: {
                    RowLabel(title: "Countdown", icon: .timer)
                }
            } footer: {
                SectionFooter("Time to get settled before the text starts moving.")
            }

            if showsAutoStart {
                Section {
                    Toggle(isOn: $settings.showsNotchTab) {
                        RowLabel(title: "Show tab in the notch", icon: .layoutTop)
                    }
                } footer: {
                    SectionFooter("When it's off, the prompter only appears when you open it (⌃⌥P, the menu bar or a click on the notch) and hides completely when you close it.")
                }

                Section {
                    Picker(selection: $settings.autoStart) {
                        ForEach(PrompterSettings.AutoStart.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    } label: {
                        RowLabel(title: "Auto-start", icon: .magicWand)
                    }
                } footer: {
                    SectionFooter("When Zoom, FaceTime, QuickTime, OBS or another app turns on the camera, Cue shows your script and starts the countdown. It pauses when the camera turns off.")
                }
            }

            Section {
                Toggle(isOn: $settings.mirror) {
                    RowLabel(title: "Mirror mode", icon: .mirror)
                }
            } footer: {
                SectionFooter("Flips the text for use with teleprompter glass.")
            }
        }
        .textStyle(.body)
        .textCase(nil)
        .tint(Theme.accent)
    }
}

private struct RowLabel: View {
    let title: LocalizedStringKey
    let icon: HugeIcon.Name

    var body: some View {
        Label {
            Text(title).textStyle(.body, weight: .medium)
        } icon: {
            HugeIcon(icon, size: 18)
                .foregroundStyle(Theme.accent)
        }
    }
}

private struct SliderRow<SliderView: View>: View {
    let title: LocalizedStringKey
    let value: String
    let icon: HugeIcon.Name
    @ViewBuilder let slider: () -> SliderView

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                RowLabel(title: title, icon: icon)
                Spacer()
                Text(value)
                    .font(.mono(14, .medium))
                    .foregroundStyle(.white)
            }
            slider()
        }
        .padding(.vertical, 4)
    }
}

private struct SectionTitle: View {
    let text: LocalizedStringKey
    init(_ text: LocalizedStringKey) { self.text = text }

    var body: some View {
        Text(text)
            .textStyle(.footnote, weight: .semibold)
            .foregroundStyle(Theme.secondaryText)
    }
}

private struct SectionFooter: View {
    let text: LocalizedStringKey
    init(_ text: LocalizedStringKey) { self.text = text }

    var body: some View {
        Text(text)
            .textStyle(.footnote, weight: .regular)
            .foregroundStyle(Theme.tertiaryText)
    }
}

extension View {
    /// Mantiene la velocidad y la cuenta regresiva del motor iguales a los ajustes.
    func syncing(_ engine: PrompterEngine, with settings: PrompterSettings) -> some View {
        self
            .onAppear {
                engine.wordsPerMinute = settings.wordsPerMinute
                engine.countdownSeconds = settings.countdown
            }
            .onChange(of: settings.wordsPerMinute) { _, value in engine.wordsPerMinute = value }
            .onChange(of: settings.countdown) { _, value in engine.countdownSeconds = value }
    }
}
