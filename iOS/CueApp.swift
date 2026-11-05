import SwiftUI

/// Punto de entrada: fija el idioma de la interfaz antes de crear la app.
@main
enum CueMain {
    static func main() {
        AppLanguage.applyAtLaunch()
        CueApp.main()
    }
}

struct CueApp: App {
    @StateObject private var store = ScriptStore()
    @StateObject private var settings = PrompterSettings()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        AppFont.registerAll()
        Self.styleUIKitChrome()
    }

    /// Barras de navegación, botones de barra y controles segmentados con las fuentes de la app
    /// (si no, UIKit los dibuja en SF Pro).
    private static func styleUIKitChrome() {
        func font(_ family: AppFont.Family, _ weight: Font.Weight, _ size: CGFloat) -> UIFont {
            UIFont(name: AppFont.name(family, weight), size: size) ?? .systemFont(ofSize: size)
        }
        let nav = UINavigationBar.appearance()
        nav.titleTextAttributes = [.font: font(.display, .semibold, 17)]
        nav.largeTitleTextAttributes = [.font: font(.display, .semibold, 34)]
        for state: UIControl.State in [.normal, .highlighted, .disabled] {
            UIBarButtonItem.appearance().setTitleTextAttributes([.font: font(.display, .medium, 17)], for: state)
        }
        UISegmentedControl.appearance().setTitleTextAttributes([.font: font(.display, .medium, 13)], for: .normal)
        UISegmentedControl.appearance().setTitleTextAttributes([.font: font(.display, .semibold, 13)], for: .selected)
    }

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(store)
                .environmentObject(settings)
                .font(.text(17, .medium))
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
