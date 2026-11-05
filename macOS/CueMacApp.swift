import SwiftUI

/// Punto de entrada: fija el idioma de la interfaz antes de crear la app.
@main
enum CueMain {
    static func main() {
        AppLanguage.applyAtLaunch()
        CueMacApp.main()
    }
}

struct CueMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var model = MacAppModel.shared

    init() {
        AppFont.registerAll()
    }

    var body: some Scene {
        Window("Cue", id: "main") {
            MacMainView(model: model, store: model.store, settings: model.settings)
                .tint(Theme.accent)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 980, height: 640)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New script") { model.newScript() }
                    .keyboardShortcut("n")
            }
            CommandMenu("Prompter") {
                Button(model.isPanelVisible && model.isPanelExpanded ? "Collapse prompter" : "Show prompter") { model.togglePrompter() }
                    .keyboardShortcut("p", modifiers: [.control, .option])
                Button("Play / pause") { model.togglePlay() }
                    .keyboardShortcut(.space, modifiers: [.control, .option])
                Button("Back to start") { model.restart() }
                    .keyboardShortcut("r", modifiers: [.control, .option])
                Divider()
                Button("Faster") { model.settings.adjustSpeed(by: 10) }
                    .keyboardShortcut(.upArrow, modifiers: [.control, .option])
                Button("Slower") { model.settings.adjustSpeed(by: -10) }
                    .keyboardShortcut(.downArrow, modifiers: [.control, .option])
            }
        }

        Settings {
            MacSettingsView(settings: model.settings)
                .tint(Theme.accent)
                .preferredColorScheme(.dark)
        }

        MenuBarExtra {
            MenuBarContent(model: model, settings: model.settings, engine: model.engine, store: model.store)
        } label: {
            Image(systemName: "text.alignleft")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MacAppModel.shared.showPill()
        MacAppModel.shared.panel.installNotchMonitor()
    }

    /// Sigue vivo en la barra de menú para detectar la cámara aunque cierres la ventana.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        MacAppModel.shared.store.saveNow()
    }
}

private struct MenuBarContent: View {
    @ObservedObject var model: MacAppModel
    @ObservedObject var settings: PrompterSettings
    @ObservedObject var engine: PrompterEngine
    @ObservedObject var store: ScriptStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(model.isPanelVisible && model.isPanelExpanded ? "Collapse prompter" : "Show prompter") { model.togglePrompter() }
        Toggle("Show tab in the notch", isOn: $settings.showsNotchTab)
        Button(engine.isActive ? "Pause" : "Play") { model.togglePlay() }
        Button("Back to start") { model.restart() }
        Divider()
        Picker("Session", selection: Binding(
            get: { store.currentSessionID },
            set: { model.selectSession($0) }
        )) {
            Text("All").tag(Optional<Session.ID>.none)
            ForEach(store.sessions) { session in
                Text(session.name).tag(Optional(session.id))
            }
        }
        Picker("Script", selection: $model.selectedID) {
            ForEach(store.visibleScripts) { script in
                Text(script.displayTitle).tag(Optional(script.id))
            }
        }
        Divider()
        Button("Open Cue…") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        SettingsLink { Text("Settings…") }
        Divider()
        Button("Quit Cue") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

private struct MacSettingsView: View {
    @ObservedObject var settings: PrompterSettings

    var body: some View {
        VStack(spacing: 0) {
            PrompterSettingsForm(settings: settings, showsAutoStart: true)
                .formStyle(.grouped)
            VStack(alignment: .leading, spacing: 8) {
                Text("Global shortcuts, from any app")
                    .textStyle(.headline)
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow { ShortcutKey("⌃⌥ Space"); Text("Play / pause") }
                    GridRow { ShortcutKey("⌃⌥ P"); Text("Open / collapse prompter") }
                    GridRow { ShortcutKey("⌃⌥ R"); Text("Back to start") }
                    GridRow { ShortcutKey("⌃⌥ ↑ / ↓"); Text("Faster / slower") }
                    GridRow { ShortcutKey("⌃⌥ ← / →"); Text("Previous / next script") }
                    GridRow { ShortcutKey("⌥⌘ 1–9"); Text("Go to script 1–9 in the list") }
                    GridRow { ShortcutKey("⌃⌥ ↩"); Text("Copilot: what do I say?") }
                    GridRow { ShortcutKey("⌃⌥ L"); Text("Copilot: listen / stop") }
                    GridRow { ShortcutKey("⌃⌥⌘ 1–9"); Text("Switch to session 1–9") }
                    GridRow { ShortcutKey("⌃⌥⌘ 0"); Text("Show all scripts") }
                }
                .textStyle(.callout, weight: .regular)
                .foregroundStyle(Theme.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .frame(width: 480, height: 680)
    }
}

private struct ShortcutKey: View {
    let keys: LocalizedStringKey
    init(_ keys: LocalizedStringKey) { self.keys = keys }

    var body: some View {
        Text(keys)
            .textStyle(.footnote, weight: .semibold)
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .card(radius: 7)
    }
}
