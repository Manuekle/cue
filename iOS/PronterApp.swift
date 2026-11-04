import SwiftUI

/// Punto de entrada: fija el idioma de la interfaz antes de crear la app.
@main
enum PronterMain {
    static func main() {
        AppLanguage.applyAtLaunch()
        PronterApp.main()
    }
}

struct PronterApp: App {
    @StateObject private var store = ScriptStore()
    @StateObject private var settings = PrompterSettings()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        AppFont.registerAll()
    }

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(store)
                .environmentObject(settings)
                .fontDesign(.default)
                .tint(Theme.accent)
                .preferredColorScheme(.dark)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { store.saveNow() }
        }
    }
}

/// Mantiene la pantalla encendida mientras la vista está visible.
struct KeepAwake: ViewModifier {
    func body(content: Content) -> some View {
        content
            .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
            .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }
}

extension View {
    func keepsScreenAwake() -> some View { modifier(KeepAwake()) }
}
