import Foundation
@preconcurrency import WhisperKit

/// El modelo cargado, para pasarlo de la tarea de carga al actor (WhisperKit no es Sendable;
/// solo lo usa el actor, de a una llamada).
final class LoadedPipe: @unchecked Sendable {
    let pipe: WhisperKit
    init(pipe: WhisperKit) { self.pipe = pipe }
}

/// Whisper en el Mac (WhisperKit, Core ML). Descarga el modelo la primera vez y lo guarda en
/// ~/Library/Application Support/Pronter/Models.
actor WhisperTranscriber {
    private var pipe: WhisperKit?
    private var loadedVariant: String?
    /// Carga en curso: si `prepare` se llama otra vez mientras tanto (p. ej. la precarga y el micrófono),
    /// espera esta misma carga en vez de cargar el modelo dos veces.
    private var loading: (variant: String, task: Task<LoadedPipe, Error>)?

    static var modelsFolder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Pronter/Models", isDirectory: true)
    }

    private static func savedFolderKey(_ variant: String) -> String { "copilot.whisperFolder.\(variant)" }

    /// Carpeta del modelo ya descargado, si existe.
    static func localFolder(for variant: String) -> URL? {
        guard let path = UserDefaults.standard.string(forKey: savedFolderKey(variant)) else { return nil }
        let url = URL(fileURLWithPath: path)
        let encoder = url.appendingPathComponent("AudioEncoder.mlmodelc")
        return FileManager.default.fileExists(atPath: encoder.path) ? url : nil
    }

    var isReady: Bool { pipe != nil }

    /// Descarga (si hace falta) y carga el modelo. `progress` va de 0 a 1 durante la descarga.
    func prepare(variant: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        if loadedVariant == variant, pipe != nil { return }
        if let loading, loading.variant == variant {
            pipe = try await loading.task.value.pipe
            loadedVariant = variant
            return
        }
        pipe = nil
        loadedVariant = nil
        let task = Task { try await Self.load(variant: variant, progress: progress) }
        loading = (variant, task)
        defer { if loading?.variant == variant { loading = nil } }
        pipe = try await task.value.pipe
        loadedVariant = variant
    }

    /// Precarga en segundo plano, solo si el modelo ya está descargado (no descarga nada).
    func prewarm(variant: String) async {
        guard Self.localFolder(for: variant) != nil else { return }
        try? await prepare(variant: variant) { _ in }
    }

    /// La primera vez que se carga un modelo en este Mac, Core ML lo adapta al chip: con el modelo grande
    /// puede tardar unos minutos (luego queda en caché y carga en ~2 s).
    private static func load(variant: String, progress: @escaping @Sendable (Double) -> Void) async throws -> LoadedPipe {
        let folder: URL
        if let local = Self.localFolder(for: variant) {
            folder = local
        } else {
            try FileManager.default.createDirectory(at: Self.modelsFolder, withIntermediateDirectories: true)
            folder = try await WhisperKit.download(variant: variant, downloadBase: Self.modelsFolder) { value in
                progress(value.fractionCompleted)
            }
            UserDefaults.standard.set(folder.path, forKey: Self.savedFolderKey(variant))
        }
        let config = WhisperKitConfig(modelFolder: folder.path, verbose: false, logLevel: .error,
                                      prewarm: true, load: true, download: false)
        return LoadedPipe(pipe: try await WhisperKit(config))
    }

    func transcribe(_ samples: [Float], language: String?) async throws -> String {
        guard let pipe else { return "" }
        // Sin los 5 reintentos a más temperatura que trae por defecto: con ruido de fondo cada reintento
        // volvía a decodificar la frase entera. Una frase hablada cabe de sobra en 128 tokens.
        let options = DecodingOptions(task: .transcribe,
                                      language: language,
                                      temperature: 0,
                                      temperatureFallbackCount: 1,
                                      sampleLength: 128,
                                      usePrefillPrompt: language != nil,
                                      detectLanguage: language == nil,
                                      skipSpecialTokens: true,
                                      withoutTimestamps: true,
                                      suppressBlank: true,
                                      noSpeechThreshold: 0.6)
        let results = try await pipe.transcribe(audioArray: samples, decodeOptions: options)
        let text = results.map(\.text).joined(separator: " ")
        return Self.clean(text)
    }

    /// Quita marcas y las "alucinaciones" típicas de Whisper con silencio o música.
    static func clean(_ raw: String) -> String {
        var text = raw.replacingOccurrences(of: #"\[[^\]]*\]|\([^)]*\)|<\|[^|]*\|>"#, with: "", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        let junk = ["gracias por ver", "suscríbete", "subtítulos", "subtitulado por", "thank you for watching",
                    "thanks for watching", "amara.org", "música", "music"]
        if junk.contains(where: { lower.contains($0) }) && text.count < 60 { return "" }
        if text.allSatisfy({ $0.isPunctuation || $0.isWhitespace }) { return "" }
        return text
    }
}
