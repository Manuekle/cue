import SwiftUI

/// Ventana principal: barra lateral + panel de contenido (editor del guion o configuración del Copiloto).
/// Sin bordes: la página es gris muy oscuro y el panel, las tarjetas y los controles van subiendo de tono.
struct MacMainView: View {
    @ObservedObject var model: MacAppModel
    @ObservedObject var store: ScriptStore
    @ObservedObject var settings: PrompterSettings

    var body: some View {
        HStack(spacing: 0) {
            MacSidebar(model: model, store: store, settings: settings, copilot: model.copilot)
                .frame(width: 260)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.Window.panel))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding([.top, .bottom, .trailing], 8)
        }
        // Barra lateral de vidrio (como el notch); el panel del contenido va opaco encima.
        .background {
            ZStack {
                WindowGlass()
                Color.black.opacity(Theme.Window.glassTint)
            }
        }
        .ignoresSafeArea()
        .frame(minWidth: 860, minHeight: 560)
        .font(.display(13))
        .foregroundStyle(Theme.Window.text)
    }

    @ViewBuilder private var detail: some View {
        if model.showsCopilotSetup {
            CopilotSetupView(model: model, copilot: model.copilot, settings: model.copilot.settings)
        } else if let id = model.selectedID, store.script(id: id) != nil {
            MacScriptEditor(scriptID: id, model: model, store: store, settings: settings)
                .id(id)
        } else {
            EmptyScriptView(hasSession: store.currentSession != nil) { model.newScript() }
        }
    }
}

private struct EmptyScriptView: View {
    let hasSession: Bool
    let create: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            HugeIcon(.noteEdit, size: 26)
                .foregroundStyle(Theme.Window.secondaryText)
                .frame(width: 60, height: 60)
                .surface(Theme.Window.raised, radius: 18)
            VStack(spacing: 6) {
                Text("No script")
                    .font(.display(20, .semibold))
                Text(hasSession ? "This session is empty. Create a new script." : "Create a script to get started.")
                    .font(.text(14))
                    .foregroundStyle(Theme.Window.secondaryText)
            }
            Button(action: create) {
                HStack(spacing: 7) {
                    HugeIcon(.plus, size: 13)
                    Text("New script")
                }
            }
            .buttonStyle(WindowButtonStyle(kind: .accent))
        }
    }
}

// MARK: Barra lateral

/// Vidrio de la ventana: desenfoque real de lo que hay detrás (mismo material que el notch).
private struct WindowGlass: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        // Sigue siendo vidrio aunque la ventana no esté activa.
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

private struct MacSidebar: View {
    @ObservedObject var model: MacAppModel
    @ObservedObject var store: ScriptStore
    @ObservedObject var settings: PrompterSettings
    @ObservedObject var copilot: CopilotModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Fila de los semáforos de la ventana.
            Color.clear.frame(height: 32)

            HStack(spacing: 11) {
                LogoMark(size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Cue")
                        .font(.display(16, .semibold))
                    Text("Prompter & copilot")
                        .font(.display(11.5, .medium))
                        .foregroundStyle(Theme.Window.tertiaryText)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)

            VStack(spacing: 2) {
                NavRow(icon: .textAlignLeft, title: "Scripts", selected: !model.showsCopilotSetup) {
                    Text("\(store.visibleScripts.count)")
                        .font(.mono(11.5, .medium))
                        .foregroundStyle(Theme.Window.tertiaryText)
                } action: {
                    model.showsCopilotSetup = false
                }
                NavRow(icon: .aiMagic, title: "Copilot", selected: model.showsCopilotSetup) {
                    if copilot.isListening {
                        LiveDot(active: true, size: 6).frame(width: 14, height: 14)
                    } else {
                        ShortcutHint(modifiers: [.control, .option], key: "L")
                    }
                } action: {
                    model.showsCopilotSetup = true
                }
            }
            .padding(.top, 22)

            // Sección de guiones: la sesión actual (menú) y "+" para crear.
            HStack(spacing: 6) {
                SessionMenu(store: store, onSelect: { _ in model.ensureValidSelection() }) {
                    SessionMenuLabel(name: store.currentSession?.name ?? String(localized: "All scripts"))
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Switch session")
                Spacer()
                SidebarIconButton(icon: .plus, help: "New script (⌘N)") { model.newScript() }
            }
            .padding(.leading, 4)
            .padding(.top, 24)
            .padding(.bottom, 4)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 2) {
                    ForEach(store.visibleScripts) { script in
                        ScriptRow(script: script, selected: !model.showsCopilotSetup && model.selectedID == script.id,
                                  wpm: settings.wordsPerMinute) {
                            model.selectedID = script.id
                            model.showsCopilotSetup = false
                        }
                        .contextMenu {
                            Menu("Move to session", systemImage: "folder") {
                                ForEach(store.sessions) { session in
                                    Button(session.name) { model.moveScript(script.id, to: session.id) }
                                        .disabled(script.sessionID == session.id)
                                }
                                if script.sessionID != nil {
                                    Divider()
                                    Button("Remove from session") { model.moveScript(script.id, to: nil) }
                                }
                            }
                            .disabled(store.sessions.isEmpty)
                            Button("Delete", role: .destructive) { model.delete(script.id) }
                        }
                    }
                }
            }

            AutoStartCard(settings: settings, monitor: model.monitor)
                .padding(.top, 8)
                .padding(.bottom, 12)
        }
        .padding(.horizontal, 12)
    }
}

/// Etiqueta de sección en Geist Mono, mayúsculas y espaciada.
struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.mono(10, .medium))
            .tracking(1.2)
            .foregroundStyle(Theme.Window.tertiaryText)
    }
}

/// "Todos los guiones ⌄": título de la sección y menú de sesiones.
private struct SessionMenuLabel: View {
    let name: String
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Text(name)
                .font(.display(13, .semibold))
                .lineLimit(1)
            HugeIcon(.arrowDown, size: 12)
                .foregroundStyle(Theme.Window.tertiaryText)
        }
        .foregroundStyle(Theme.Window.text.opacity(hovering ? 1 : 0.86))
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(Pill().fill(Theme.Window.onGlass.opacity(hovering ? 0.7 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// Atajo discreto (íconos de Hugeicons + letra en Geist Mono), sin tecla dibujada.
struct ShortcutHint: View {
    let modifiers: [Keycap.Key]
    var key: String?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(modifiers.indices, id: \.self) { index in
                switch modifiers[index] {
                case .control: HugeIcon(.control, size: 11)
                case .option: HugeIcon(.option, size: 11)
                case .command: HugeIcon(.command, size: 11)
                case .returnKey: HugeIcon(.returnKey, size: 11)
                case .letter(let text): Text(text).font(.mono(11, .medium))
                }
            }
            if let key {
                Text(key).font(.mono(11, .medium))
            }
        }
        .foregroundStyle(Theme.Window.tertiaryText)
    }
}

private struct SidebarIconButton: View {
    let icon: HugeIcon.Name
    let help: LocalizedStringKey
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HugeIcon(icon, size: 16)
                .foregroundStyle(hovering ? Theme.Window.text : Theme.Window.secondaryText)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Theme.Window.onGlass.opacity(hovering ? 1 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

private struct NavRow<Trailing: View>: View {
    let icon: HugeIcon.Name
    let title: LocalizedStringKey
    let selected: Bool
    @ViewBuilder let trailing: Trailing
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                HugeIcon(icon, size: 18, filled: selected)
                    .foregroundStyle(selected ? Theme.Window.text : Theme.Window.secondaryText)
                Text(title)
                    .font(.display(14, .medium))
                Spacer(minLength: 4)
                trailing
            }
            .foregroundStyle(selected ? Theme.Window.text : Theme.Window.secondaryText)
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(SidebarHighlight(selected: selected, hovering: hovering))
            .contentShape(Pill())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct ScriptRow: View {
    let script: Script
    let selected: Bool
    let wpm: Double
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                HugeIcon(.file, size: 17, filled: selected)
                    .foregroundStyle(selected ? Theme.Window.text : Theme.Window.tertiaryText)
                Text(script.displayTitle)
                    .font(.display(14, .medium))
                    .foregroundStyle(selected ? Theme.Window.text : Theme.Window.secondaryText)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(TimeFormat.estimate(words: script.wordCount, wpm: wpm))
                    .font(.mono(11))
                    .foregroundStyle(Theme.Window.tertiaryText)
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(SidebarHighlight(selected: selected, hovering: hovering))
            .contentShape(Pill())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("\(script.wordCount.formatted()) words · \(TimeFormat.estimate(words: script.wordCount, wpm: wpm)) min")
    }
}

/// Fondo de una fila sobre el vidrio: cápsula clara si está elegida, más tenue al pasar el mouse. Sin borde.
private struct SidebarHighlight: View {
    let selected: Bool
    let hovering: Bool

    var body: some View {
        Pill().fill(Theme.Window.onGlass.opacity(selected ? 1 : (hovering ? 0.55 : 0)))
    }
}

/// Auto-inicio al final de la barra lateral.
private struct AutoStartCard: View {
    @ObservedObject var settings: PrompterSettings
    @ObservedObject var monitor: RecordingMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                HugeIcon(.magicWand, size: 15)
                    .foregroundStyle(settings.autoStart == .off ? Theme.Window.tertiaryText : Theme.Window.accentText)
                Text("Auto-start")
                    .font(.display(12.5, .semibold))
                Spacer()
                HStack(spacing: 8) {
                    StatusIcon(icon: .video, on: monitor.cameraInUse, color: Theme.record,
                               help: monitor.cameraInUse ? "Camera on" : "Camera off")
                    StatusIcon(icon: .mic, on: monitor.microphoneInUse, color: .orange,
                               help: monitor.microphoneInUse ? "Microphone in use" : "Microphone free")
                }
            }
            MenuField(title: settings.autoStart.label, fill: Theme.Window.onGlass) {
                Picker("Auto-start", selection: $settings.autoStart) {
                    ForEach(PrompterSettings.AutoStart.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.05)))
    }
}

private struct StatusIcon: View {
    let icon: HugeIcon.Name
    let on: Bool
    let color: Color
    let help: LocalizedStringKey

    var body: some View {
        HugeIcon(icon, size: 13)
            .foregroundStyle(on ? color : Theme.Window.tertiaryText.opacity(0.7))
            .help(help)
    }
}

// MARK: Editor

private struct MacScriptEditor: View {
    let scriptID: Script.ID
    @ObservedObject var model: MacAppModel
    @ObservedObject var store: ScriptStore
    @ObservedObject var settings: PrompterSettings

    private var script: Binding<Script> {
        Binding(get: { store.script(id: scriptID) ?? Script(title: "", body: "") },
                set: { store.update($0) })
    }

    var body: some View {
        let words = script.wrappedValue.wordCount
        VStack(spacing: 0) {
            // Barra superior: dónde estás y la acción principal.
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    HugeIcon(.folder, size: 13)
                    Text(store.currentSession?.name ?? String(localized: "All scripts"))
                        .font(.display(12.5, .medium))
                        .lineLimit(1)
                }
                .foregroundStyle(Theme.Window.tertiaryText)
                Spacer()
                Button {
                    model.panelMode = .script
                    model.showPrompter()
                    model.engine.start()
                } label: {
                    HStack(spacing: 7) {
                        HugeIcon(.play, size: 12, filled: true)
                        Text("Start")
                        HStack(spacing: 1) {
                            HugeIcon(.command, size: 11)
                            HugeIcon(.returnKey, size: 11)
                        }
                        .opacity(0.6)
                    }
                }
                .buttonStyle(WindowButtonStyle(kind: .accent))
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(words == 0)
                .help("Opens the prompter in the notch and starts the countdown (⌘↩)")
            }
            .padding(.horizontal, 18)
            .frame(height: 52)

            VStack(alignment: .leading, spacing: 0) {
                TextField("Title", text: script.title)
                    .textFieldStyle(.plain)
                    .font(.display(30, .bold))
                    .tracking(-0.6)
                    .foregroundStyle(Theme.Window.text)
                    .padding(.leading, -7)

                HStack(spacing: 8) {
                    MetaItem(icon: .textAlignLeft, text: String(localized: "\(words.formatted()) words"))
                    MetaItem(icon: .clock, text: "≈ \(TimeFormat.estimate(words: words, wpm: settings.wordsPerMinute)) min")
                    MetaItem(icon: .speed, text: String(localized: "\(Int(settings.wordsPerMinute)) wpm"))
                }
                .padding(.top, 14)

                TextEditor(text: script.body)
                    .font(.text(17))
                    .lineSpacing(8)
                    .foregroundStyle(Theme.Window.text.opacity(0.92))
                    .scrollContentBackground(.hidden)
                    .scrollIndicators(.never)
                    // NSTextView deja 5 pt a los lados: así el texto queda alineado con el título.
                    .padding(.horizontal, -5)
                    .overlay(alignment: .topLeading) {
                        if script.wrappedValue.body.isEmpty {
                            Text("Write or paste your script here…")
                                .font(.text(17))
                                .foregroundStyle(Theme.Window.tertiaryText)
                                .allowsHitTesting(false)
                        }
                    }
                    .padding(.top, 26)
            }
            .frame(maxWidth: 720, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 40)
            .padding(.top, 18)
            .frame(maxWidth: .infinity)
        }
        // macOS enfoca solo el título al abrir y lo deja seleccionado entero: al aparecer, no enfocamos nada.
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { NSApp.keyWindow?.makeFirstResponder(nil) }
        }
    }
}

private struct MetaItem: View {
    let icon: HugeIcon.Name
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            HugeIcon(icon, size: 14)
                .foregroundStyle(Theme.Window.tertiaryText)
            Text(text)
                .font(.mono(11.5))
                .foregroundStyle(Theme.Window.secondaryText)
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Pill().fill(Theme.Window.raised))
    }
}

// MARK: Controles de la ventana

/// Botón en cápsula sin borde: azul (acción principal) o gris (secundaria).
struct WindowButtonStyle: ButtonStyle {
    enum Kind { case accent, neutral }
    var kind: Kind = .neutral

    func makeBody(configuration: Configuration) -> some View {
        StyledButton(configuration: configuration, kind: kind)
    }

    private struct StyledButton: View {
        let configuration: Configuration
        let kind: Kind
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.display(13, .semibold))
                .foregroundStyle(kind == .accent ? Color.white : Theme.Window.text)
                .padding(.horizontal, 14)
                .frame(height: 32)
                .background(Pill().fill(kind == .accent ? Theme.accent : Theme.Window.control))
                .overlay(Pill().fill(Color.white.opacity(hovering && isEnabled ? 0.07 : 0)))
                .contentShape(Pill())
                .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.4)
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
                .onHover { hovering = $0 }
        }
    }
}

/// Menú desplegable con aspecto de campo relleno (sin borde). El contenido suele ser un `Picker` `.inline`.
struct MenuField<Content: View>: View {
    let title: String
    var fill: Color = Theme.Window.control
    @ViewBuilder let content: Content
    @State private var hovering = false

    var body: some View {
        Menu {
            content
        } label: {
            HStack(spacing: 6) {
                Text(title)
                    .font(.display(12.5, .medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                HugeIcon(.unfold, size: 12)
                    .foregroundStyle(Theme.Window.tertiaryText)
            }
            .foregroundStyle(Theme.Window.text)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(hovering ? 0.04 : 0)))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .onHover { hovering = $0 }
    }
}

/// Fondo de campo de texto relleno, sin borde.
struct FieldBackground: ViewModifier {
    var fill: Color = Theme.Window.control

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(fill))
    }
}

extension View {
    func fieldBackground(_ fill: Color = Theme.Window.control) -> some View {
        modifier(FieldBackground(fill: fill))
    }
}
