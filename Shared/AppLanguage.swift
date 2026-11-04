import Foundation
#if os(macOS)
import AppKit
#endif

/// Idioma de la interfaz. Inglés por defecto (aunque el sistema esté en otro idioma); el usuario puede
/// elegir español en Ajustes. Se aplica al arrancar, antes de crear la interfaz, así que cambiarlo pide reiniciar.
enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case spanish = "es"

    var id: String { rawValue }

    /// Nombre en su propio idioma: no se traduce.
    var nativeName: String {
        switch self {
        case .english: "English"
        case .spanish: "Español"
        }
    }

    private static let key = "PronterLanguage"

    /// El elegido por el usuario; inglés si nunca eligió.
    static var current: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .english
    }

    /// El que está usando este proceso (el de `current` en el arranque).
    static let launched = current

    /// Fija el idioma del proceso. Llamar en `main`, antes de que nada lea textos traducidos.
    static func applyAtLaunch() {
        UserDefaults.standard.set([current.rawValue], forKey: "AppleLanguages")
    }

    /// Guarda la elección; se ve al volver a abrir la app.
    static func choose(_ language: AppLanguage) {
        UserDefaults.standard.set(language.rawValue, forKey: key)
        UserDefaults.standard.set([language.rawValue], forKey: "AppleLanguages")
    }

    #if os(macOS)
    /// Cierra y vuelve a abrir Pronter para aplicar el idioma.
    static func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", path]
        try? task.run()
        NSApp.terminate(nil)
    }
    #endif
}
