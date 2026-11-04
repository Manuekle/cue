import Foundation

/// Ajustes del Copiloto, guardados en UserDefaults.
final class CopilotSettings: ObservableObject {
    enum WhisperModel: String, CaseIterable, Identifiable {
        case base = "openai_whisper-base"
        case small = "openai_whisper-small"
        case turbo = "openai_whisper-large-v3-v20240930_turbo_632MB"

        var id: String { rawValue }
        var label: String {
            switch self {
            case .base: String(localized: "Fast · 145 MB")
            case .small: String(localized: "Balanced · 480 MB")
            case .turbo: String(localized: "Accurate · 630 MB")
            }
        }
    }

    enum Language: String, CaseIterable, Identifiable {
        case spanish = "es", english = "en", auto

        var id: String { rawValue }
        var label: String {
            switch self {
            case .spanish: String(localized: "Spanish")
            case .english: String(localized: "English")
            case .auto: String(localized: "Detect")
            }
        }
        /// Código para Whisper (nil = detectar).
        var whisperCode: String? { self == .auto ? nil : rawValue }
    }

    /// Lo que la IA sabe antes de la conversación: quién eres, de qué va, tus objetivos.
    @Published var context: String { didSet { defaults.set(context, forKey: "copilot.context") } }
    @Published var engine: LLMEngine { didSet { defaults.set(engine.rawValue, forKey: "copilot.engine") } }
    @Published var ollamaModel: String { didSet { defaults.set(ollamaModel, forKey: "copilot.ollamaModel") } }
    /// Modelo elegido para cada proveedor en la nube (clave: `LLMEngine.rawValue`).
    @Published private(set) var cloudModels: [String: String] { didSet { defaults.set(cloudModels, forKey: "copilot.cloudModels") } }
    @Published var whisperModel: WhisperModel { didSet { defaults.set(whisperModel.rawValue, forKey: "copilot.whisper") } }
    @Published var language: Language { didSet { defaults.set(language.rawValue, forKey: "copilot.language") } }
    /// Sugiere sola cuando la otra persona termina de hablar.
    @Published var autoSuggest: Bool { didSet { defaults.set(autoSuggest, forKey: "copilot.auto") } }
    /// Escucha también el audio del Mac (la otra persona en Zoom, Meet…), no solo tu micrófono.
    @Published var captureSystemAudio: Bool { didSet { defaults.set(captureSystemAudio, forKey: "copilot.systemAudio") } }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        context = defaults.string(forKey: "copilot.context") ?? ""
        engine = defaults.string(forKey: "copilot.engine").flatMap(LLMEngine.init(rawValue:))
            ?? (LocalLLM.appleAvailability == nil ? .apple : .ollama)
        ollamaModel = defaults.string(forKey: "copilot.ollamaModel") ?? ""
        cloudModels = defaults.dictionary(forKey: "copilot.cloudModels") as? [String: String] ?? [:]
        whisperModel = defaults.string(forKey: "copilot.whisper").flatMap(WhisperModel.init(rawValue:)) ?? .small
        language = defaults.string(forKey: "copilot.language").flatMap(Language.init(rawValue:)) ?? .spanish
        autoSuggest = defaults.object(forKey: "copilot.auto") as? Bool ?? true
        captureSystemAudio = defaults.object(forKey: "copilot.systemAudio") as? Bool ?? true
    }

    /// Modelo que se usará con ese motor ("" = el del sistema, en Apple Intelligence).
    func model(for engine: LLMEngine) -> String {
        switch engine {
        case .apple: ""
        case .ollama: ollamaModel
        default: cloudModels[engine.rawValue].flatMap { $0.isEmpty ? nil : $0 } ?? engine.defaultModel
        }
    }

    func setModel(_ model: String, for engine: LLMEngine) {
        let value = model.trimmingCharacters(in: .whitespacesAndNewlines)
        switch engine {
        case .apple: break
        case .ollama: ollamaModel = value
        default: cloudModels[engine.rawValue] = value
        }
    }
}
