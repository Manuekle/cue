import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// IA local: Apple Intelligence (modelo del sistema, en el Mac) u Ollama (localhost:11434).
/// Nada sale de tu Mac. Ollama Cloud usa la misma API, con otra dirección y tu API key.
enum LocalLLM {
    static let ollamaURL = URL(string: "http://localhost:11434")!

    /// nil si Apple Intelligence está lista; si no, el motivo.
    static var appleAvailability: String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return nil
            case .unavailable(.deviceNotEligible): return String(localized: "This Mac doesn't support Apple Intelligence.")
            case .unavailable(.appleIntelligenceNotEnabled): return String(localized: "Turn on Apple Intelligence in System Settings.")
            case .unavailable(.modelNotReady): return String(localized: "Apple Intelligence is still downloading its model.")
            case .unavailable: return String(localized: "Apple Intelligence isn't available.")
            }
        }
        #endif
        return String(localized: "Apple Intelligence needs macOS 26 or later.")
    }

    /// Respuesta en streaming del motor elegido: cada valor es el texto acumulado hasta ahora.
    static func stream(engine: LLMEngine, model: String, instructions: String, prompt: String) -> AsyncThrowingStream<String, Error> {
        switch engine {
        case .apple:
            return appleStream(instructions: instructions, prompt: prompt)
        case .ollama:
            return ollamaStream(model: model, instructions: instructions, prompt: prompt)
        case .ollamaCloud:
            let key = KeychainStore.apiKey(for: .ollamaCloud)
            guard !key.isEmpty else {
                return AsyncThrowingStream { $0.finish(throwing: LLMError.message(String(localized: "Missing the Ollama Cloud API key. Add it in Cue › Copilot."))) }
            }
            return ollamaStream(model: model.isEmpty ? engine.defaultModel : model, instructions: instructions,
                                prompt: prompt, base: CloudLLM.ollamaCloudURL, apiKey: key)
        case .openai, .gemini, .claude, .muse:
            return CloudLLM.stream(engine: engine, model: model, apiKey: KeychainStore.apiKey(for: engine),
                                   instructions: instructions, prompt: prompt)
        }
    }

    // MARK: Apple Intelligence

    private static func appleStream(instructions: String, prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            #if canImport(FoundationModels)
            if #available(macOS 26.0, *) {
                if let reason = appleAvailability {
                    continuation.finish(throwing: LLMError.message(reason))
                    return
                }
                let task = Task {
                    do {
                        let session = LanguageModelSession(instructions: instructions)
                        let stream = session.streamResponse(to: prompt, options: GenerationOptions(temperature: 0.6))
                        for try await snapshot in stream {
                            continuation.yield(snapshot.content)
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
                return
            }
            #endif
            continuation.finish(throwing: LLMError.message(appleAvailability ?? String(localized: "Apple Intelligence isn't available.")))
        }
    }

    // MARK: Ollama

    private struct ChatChunk: Decodable {
        struct Message: Decodable { let content: String? }
        let message: Message?
        let done: Bool?
        let error: String?
    }

    /// Modelos que no aceptan `think: false` (p. ej. gpt-oss): se recuerda para no repetir el intento.
    private static var thinkRejected = Set<String>()
    private static let thinkLock = NSLock()

    private static func ollamaStream(model: String, instructions: String, prompt: String,
                                     base: URL = ollamaURL, apiKey: String? = nil) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard !model.isEmpty else { throw LLMError.message(String(localized: "Choose an Ollama model in the Cue window.")) }
                    let cloud = apiKey != nil
                    var sendThink = !thinkLock.withLock { thinkRejected.contains(model) }
                    var bytes: URLSession.AsyncBytes
                    while true {
                        var request = URLRequest(url: base.appendingPathComponent("api/chat"))
                        request.httpMethod = "POST"
                        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                        if let apiKey { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
                        request.timeoutInterval = 120
                        var options: [String: Any] = ["temperature": 0.6]
                        // Ollama corta el contexto a 4096 tokens por defecto: con un contexto largo la IA perdía
                        // el principio (quién eres, de qué va) y respondía cosas raras.
                        if !cloud { options["num_ctx"] = 16384 }
                        var body: [String: Any] = [
                            "model": model,
                            "stream": true,
                            "options": options,
                            "messages": [
                                ["role": "system", "content": instructions],
                                ["role": "user", "content": prompt],
                            ],
                        ]
                        if !cloud { body["keep_alive"] = "30m" }
                        // Sin "pensar en voz alta" la respuesta empieza mucho antes.
                        if sendThink { body["think"] = false }
                        request.httpBody = try JSONSerialization.data(withJSONObject: body)
                        let (stream, response) = try await URLSession.shared.bytes(for: request)
                        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                            var text = ""
                            for try await line in stream.lines { text += line }
                            let decoded = try? JSONDecoder().decode(ChatChunk.self, from: Data(text.utf8))
                            if sendThink, http.statusCode == 400, text.lowercased().contains("think") {
                                thinkLock.withLock { _ = thinkRejected.insert(model) }
                                sendThink = false
                                continue
                            }
                            switch http.statusCode {
                            case 401, 403: throw LLMError.message(String(localized: "Ollama Cloud rejected the API key. Check it in Cue › Copilot."))
                            case 404: throw LLMError.message(decoded?.error ?? String(localized: "Ollama can't find the model \(model)."))
                            default: throw LLMError.message(decoded?.error ?? String(localized: "Ollama responded \(http.statusCode)."))
                            }
                        }
                        bytes = stream
                        break
                    }
                    var full = ""
                    for try await line in bytes.lines {
                        guard let chunk = try? JSONDecoder().decode(ChatChunk.self, from: Data(line.utf8)) else { continue }
                        if let error = chunk.error { throw LLMError.message(error) }
                        full += chunk.message?.content ?? ""
                        continuation.yield(stripThinking(full))
                        if chunk.done == true { break }
                    }
                    continuation.finish()
                } catch let error as URLError where error.code == .cannotConnectToHost || error.code == .networkConnectionLost {
                    continuation.finish(throwing: LLMError.message(String(localized: "Ollama isn't running. Open it or use Apple Intelligence.")))
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Carga el modelo y lee las instrucciones (con tu contexto) antes de la primera sugerencia.
    /// Con un contexto largo esa primera lectura tarda decenas de segundos; después Ollama la reutiliza
    /// y cada sugerencia empieza en una fracción de segundo. Usa las mismas opciones que `ollamaStream`.
    static func warmUpOllama(model: String, instructions: String) {
        guard !model.isEmpty else { return }
        var request = URLRequest(url: ollamaURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 300
        var body: [String: Any] = [
            "model": model,
            "stream": false,
            "keep_alive": "30m",
            "options": ["temperature": 0.6, "num_ctx": 16384, "num_predict": 1],
            "messages": [["role": "system", "content": instructions]],
        ]
        if !thinkLock.withLock({ thinkRejected.contains(model) }) { body["think"] = false }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: request).resume()
    }

    /// Modelos de chat instalados en Ollama (sin los de embeddings).
    static func ollamaModels() async -> [String] {
        struct Tags: Decodable {
            struct Model: Decodable { let name: String }
            let models: [Model]
        }
        var request = URLRequest(url: ollamaURL.appendingPathComponent("api/tags"))
        request.timeoutInterval = 3
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let tags = try? JSONDecoder().decode(Tags.self, from: data) else { return [] }
        return tags.models.map(\.name).filter { !$0.contains("embed") }
    }

    /// Algunos modelos (qwen3, deepseek-r1) piensan en voz alta dentro de <think>…</think>.
    static func stripThinking(_ text: String) -> String {
        var result = text.replacingOccurrences(of: #"(?s)<think>.*?</think>"#, with: "", options: .regularExpression)
        if let open = result.range(of: "<think>") { result = String(result[..<open.lowerBound]) }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum LLMError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self {
        case .message(let text): text
        }
    }
}
