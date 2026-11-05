import Foundation
import SwiftUI

/// Ajustes del prompter, guardados en UserDefaults.
final class PrompterSettings: ObservableObject {
    static let speedRange: ClosedRange<Double> = 60...260
    static let fontRange: ClosedRange<Double> = 20...110
    static let countdownOptions = [0, 3, 5, 10]

    enum AutoStart: String, CaseIterable, Identifiable {
        case off, camera, cameraOrMicrophone
        var id: String { rawValue }
        var label: String {
            switch self {
            case .off: String(localized: "Off")
            case .camera: String(localized: "When the camera turns on")
            case .cameraOrMicrophone: String(localized: "When the camera or mic is in use")
            }
        }
    }

    /// Velocidad de lectura en palabras por minuto.
    @Published var wordsPerMinute: Double { didSet { save(wordsPerMinute, "wpm") } }
    @Published var fontSize: Double { didSet { save(fontSize, "fontSize") } }
    @Published var countdown: Int { didSet { save(countdown, "countdown") } }
    @Published var mirror: Bool { didSet { save(mirror, "mirror") } }
    @Published var centered: Bool { didSet { save(centered, "centered") } }
    /// Solo Mac: arranca el prompter cuando otra app empieza a grabar.
    @Published var autoStart: AutoStart { didSet { save(autoStart.rawValue, "autoStart") } }
    /// Solo iOS: la ventana flotante arranca sola al detectar que grabas en otra app.
    @Published var floatingAutoStart: Bool { didSet { save(floatingAutoStart, "floatingAutoStart") } }
    /// Solo iOS: ventana flotante vertical u horizontal.
    @Published var floatingVertical: Bool { didSet { save(floatingVertical, "floatingVertical") } }
    /// Al grabar con Cue, el texto avanza mientras hablas y espera cuando callas.
    @Published var voiceFollow: Bool { didSet { save(voiceFollow, "voiceFollow") } }
    /// Solo Mac: la pestaña (píldora) queda siempre en el notch. Desactivada, el prompter solo aparece
    /// al abrirlo (⌃⌥P, menú, clic en el notch) y se oculta del todo al cerrarlo.
    @Published var showsNotchTab: Bool { didSet { save(showsNotchTab, "showsNotchTab") } }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        #if os(macOS)
        let defaultFont = 34.0
        #else
        let defaultFont = 40.0
        #endif
        wordsPerMinute = defaults.object(forKey: "wpm") as? Double ?? 140
        fontSize = defaults.object(forKey: "fontSize") as? Double ?? defaultFont
        countdown = defaults.object(forKey: "countdown") as? Int ?? 3
        mirror = defaults.object(forKey: "mirror") as? Bool ?? false
        centered = defaults.object(forKey: "centered") as? Bool ?? true
        autoStart = AutoStart(rawValue: defaults.string(forKey: "autoStart") ?? "") ?? .camera
        floatingAutoStart = defaults.object(forKey: "floatingAutoStart") as? Bool ?? true
        floatingVertical = defaults.object(forKey: "floatingVertical") as? Bool ?? false
        voiceFollow = defaults.object(forKey: "voiceFollow") as? Bool ?? true
        showsNotchTab = defaults.object(forKey: "showsNotchTab") as? Bool ?? true
    }

    func adjustSpeed(by delta: Double) {
        wordsPerMinute = (wordsPerMinute + delta).clamped(to: Self.speedRange)
    }

    func adjustFont(by delta: Double) {
        fontSize = (fontSize + delta).clamped(to: Self.fontRange)
    }

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

enum TimeFormat {
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Duración aproximada de lectura de un texto a cierta velocidad.
    static func estimate(words: Int, wpm: Double) -> String {
        guard words > 0 else { return "0:00" }
        return clock(Double(words) / wpm * 60)
    }
}
