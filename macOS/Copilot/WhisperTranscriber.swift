import Foundation
import WhisperKit

/// Whisper en el Mac (WhisperKit, Core ML). Descarga el modelo la primera vez y lo guarda en
/// ~/Library/Application Support/Pronter/Models.
actor WhisperTranscriber {
    private var pipe: WhisperKit?
    private var loadedVariant: String?

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
        pipe = nil
        loadedVariant = nil
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
        pipe = try await WhisperKit(config)
        loadedVariant = variant
    }

    func transcribe(_ samples: [Float], language: String?) async throws -> String {
        guard let pipe else { return "" }
        let options = DecodingOptions(task: .transcribe,
                                      language: language,
                                      temperature: 0,
                                      usePrefillPrompt: language != nil,
                                      detectLanguage: language == nil,
                                      skipSpecialTokens: true,
                                      withoutTimestamps: true,
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
