import Foundation

/// Motor de IA para las sugerencias: local (Apple Intelligence, Ollama) o en la nube con tu API key.
enum LLMEngine: String, CaseIterable, Identifiable {
    case apple, ollama, ollamaCloud, openai, gemini, claude, muse

    var id: String { rawValue }

    var label: String {
        switch self {
        case .apple: "Apple Intelligence"
        case .ollama: "Ollama (local)"
        case .ollamaCloud: "Ollama Cloud"
        case .openai: "ChatGPT (OpenAI)"
        case .gemini: "Gemini (Google)"
        case .claude: "Claude (Anthropic)"
        case .muse: "Muse (Meta)"
        }
    }

    /// Corre en tu Mac: no necesita API key y nada sale del equipo.
    var isLocal: Bool { self == .apple || self == .ollama }

    /// A quién se envía la conversación (para avisarlo en la interfaz).
    var company: String {
        switch self {
        case .apple, .ollama: String(localized: "your Mac")
        case .ollamaCloud: "Ollama"
        case .openai: "OpenAI"
        case .gemini: "Google"
        case .claude: "Anthropic"
        case .muse: "Meta"
        }
    }

    /// Modelo por defecto (se puede cambiar en la configuración).
    var defaultModel: String {
        switch self {
        case .apple, .ollama: ""
        case .ollamaCloud: "gemma4:31b"
        case .openai: "gpt-5.6-luna"
        case .gemini: "gemini-3.8-flash"
        case .claude: "claude-opus-5-5"
        case .muse: "muse-spark-1.1"
        }
    }

    /// Sugerencias para el menú de modelos, antes de cargar la lista real del proveedor.
    var suggestedModels: [String] {
        switch self {
        case .apple, .ollama: []
        case .ollamaCloud: ["gemma4:31b", "gpt-oss:20b", "deepseek-v4.1-flash", "glm-5.3-flash", "muse-spark-open"]
        case .openai: ["gpt-5.6-luna", "gpt-5.6-terra", "gpt-5.5"]
        case .gemini: ["gemini-3.8-flash"]
        case .claude: ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"]
        case .muse: ["muse-spark-1.1"]
        }
    }

    /// Dónde se crea la API key.
    var keyURL: URL? {
        switch self {
        case .apple, .ollama, .muse: nil
        case .ollamaCloud: URL(string: "https://ollama.com/settings/keys")
        case .openai: URL(string: "https://platform.openai.com/api-keys")
        case .gemini: URL(string: "https://aistudio.google.com/apikey")
        case .claude: URL(string: "https://platform.claude.com/settings/keys")
        }
    }

    /// Base de la API compatible con OpenAI (chat/completions y models).
    fileprivate var openAIBase: URL? {
        switch self {
        case .openai: URL(string: "https://api.openai.com/v1/")
        case .gemini: URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/")
        case .muse: URL(string: "https://api.meta.ai/v1/")
        default: nil
        }
    }

    /// Valores de "esfuerzo de razonamiento" a probar, del más rápido al más lento. nil = no enviarlo.
    /// Cada modelo acepta valores distintos: si uno da error se prueba el siguiente y se recuerda el que funcionó.
    fileprivate var effortCandidates: [String?] {
        switch self {
        case .openai: ["minimal", "low", nil]
        case .gemini: ["none", "minimal", "low", nil]
        case .muse: ["minimal", "low", nil]
        case .claude: ["low", nil]
        default: [nil]
        }
    }
}

/// IA en la nube con streaming: ChatGPT, Gemini y Muse (API compatible con OpenAI) y Claude (API de Anthropic).
/// Ollama Cloud usa la misma API que Ollama local (ver `LocalLLM`).
enum CloudLLM {
    static let ollamaCloudURL = URL(string: "https://ollama.com")!
    private static let anthropicURL = URL(string: "https://api.anthropic.com/v1/")!
    private static let anthropicVersion = "2026-10-21"
    /// Modelos de Claude que aceptan `fallbacks: "default"` (si el modelo rechaza, otro responde en la misma llamada).
    private static let claudeFallbackModels: Set = ["claude-opus-5-5", "claude-opus-5", "claude-fable-5-1", "claude-sonnet-5-5"]

    private static let memo = EffortMemo()

    /// Respuesta en streaming: cada valor es el texto acumulado hasta ahora.
    static func stream(engine: LLMEngine, model: String, apiKey: String,
                       instructions: String, prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard !apiKey.isEmpty else {
                        throw LLMError.message(String(localized: "Missing the \(engine.label) API key. Add it in Cue › Copilot."))
                    }
                    let model = model.isEmpty ? engine.defaultModel : model
                    try await run(engine: engine, model: model, apiKey: apiKey, instructions: instructions,
                                  prompt: prompt) { continuation.yield($0) }
                    continuation.finish()
                } catch let error as URLError where error.code == .notConnectedToInternet {
                    continuation.finish(throwing: LLMError.message(String(localized: "No internet connection.")))
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func run(engine: LLMEngine, model: String, apiKey: String, instructions: String, prompt: String,
                            yield: @escaping (String) -> Void) async throws {
        let candidates = engine.effortCandidates
        let memoKey = "\(engine.rawValue)|\(model)"
        var index = min(await memo.index(for: memoKey) ?? 0, candidates.count - 1)
        while true {
            let request = try makeRequest(engine: engine, model: model, apiKey: apiKey, effort: candidates[index],
                                          instructions: instructions, prompt: prompt)
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                let body = try await collect(bytes)
                let lower = body.lowercased()
                if status == 400, index + 1 < candidates.count,
                   lower.contains("reasoning") || lower.contains("effort") || lower.contains("think") {
                    index += 1
                    continue
                }
                throw LLMError.message(errorMessage(body, status: status, engine: engine))
            }
            await memo.set(index, for: memoKey)
            if engine == .claude {
                try await parseAnthropic(bytes, yield: yield)
            } else {
                try await parseOpenAI(bytes, yield: yield)
            }
            return
        }
    }

    private static func makeRequest(engine: LLMEngine, model: String, apiKey: String, effort: String?,
                                    instructions: String, prompt: String) throws -> URLRequest {
        var body: [String: Any] = ["model": model, "stream": true]
        var request: URLRequest
        if engine == .claude {
            request = URLRequest(url: anthropicURL.appendingPathComponent("messages"))
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
            // El contexto (largo y fijo) va en caché: las siguientes sugerencias lo leen sin reprocesarlo.
            body["system"] = [["type": "text", "text": instructions, "cache_control": ["type": "ephemeral"]]]
            body["messages"] = [["role": "user", "content": prompt]]
            // Respuestas cortas a propósito; el margen es para el razonamiento interno del modelo.
            body["max_tokens"] = 4096
            if let effort { body["output_config"] = ["effort": effort] }
            if claudeFallbackModels.contains(model) {
                request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
                body["fallbacks"] = "default"
            }
        } else {
            guard let base = engine.openAIBase else { throw LLMError.message(String(localized: "This provider has no compatible API.")) }
            request = URLRequest(url: base.appendingPathComponent("chat/completions"))
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            body["messages"] = [["role": "system", "content": instructions], ["role": "user", "content": prompt]]
            if let effort { body["reasoning_effort"] = effort }
        }
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    // MARK: Streaming (SSE)

    /// `data: {"choices":[{"delta":{"content":"…"}}]}` … `data: [DONE]`
    private static func parseOpenAI(_ bytes: URLSession.AsyncBytes, yield: (String) -> Void) async throws {
        var full = ""
        for try await line in bytes.lines {
            guard let object = sseObject(line) else {
                if line.hasPrefix("data:"), line.contains("[DONE]") { break }
                continue
            }
            if let message = errorText(object) { throw LLMError.message(message) }
            guard let choice = (object["choices"] as? [[String: Any]])?.first,
                  let delta = choice["delta"] as? [String: Any],
                  let content = delta["content"] as? String, !content.isEmpty else { continue }
            full += content
            yield(LocalLLM.stripThinking(full))
        }
    }

    /// Eventos de la API de Anthropic: solo interesan los `text_delta` y si el modelo rechazó responder.
    private static func parseAnthropic(_ bytes: URLSession.AsyncBytes, yield: (String) -> Void) async throws {
        var full = ""
        var refused = false
        for try await line in bytes.lines {
            guard let object = sseObject(line) else { continue }
            switch object["type"] as? String {
            case "content_block_delta":
                if let delta = object["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                   let text = delta["text"] as? String {
                    full += text
                    yield(full.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            case "message_delta":
                if let delta = object["delta"] as? [String: Any], delta["stop_reason"] as? String == "refusal" { refused = true }
            case "error":
                throw LLMError.message(errorText(object) ?? String(localized: "Claude returned an error."))
            default:
                break
            }
        }
        if refused { throw LLMError.message(String(localized: "Claude declined to answer this. Try again or switch models.")) }
    }

    private static func sseObject(_ line: String) -> [String: Any]? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard payload.first == "{", let data = payload.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: Errores

    private static func collect(_ bytes: URLSession.AsyncBytes) async throws -> String {
        var text = ""
        for try await line in bytes.lines {
            text += line
            if text.count > 4000 { break }
        }
        return text
    }

    /// Mensaje legible a partir del cuerpo de error (cada proveedor lo envuelve distinto).
    private static func errorMessage(_ body: String, status: Int, engine: LLMEngine) -> String {
        switch status {
        case 401, 403:
            return String(localized: "\(engine.label) rejected the API key. Check it in Cue › Copilot.")
        case 404:
            return String(localized: "\(engine.label) can't find the model. Choose another one in Cue › Copilot.")
        case 429:
            return String(localized: "\(engine.label): usage limit reached or out of credit. Wait a moment or check your account.")
        default:
            break
        }
        let data = Data(body.utf8)
        let json = try? JSONSerialization.jsonObject(with: data)
        let object = (json as? [String: Any]) ?? (json as? [[String: Any]])?.first
        if let object, let message = errorText(object) { return "\(engine.label): \(message)" }
        return String(localized: "\(engine.label) responded \(status).")
    }

    private static func errorText(_ object: [String: Any]) -> String? {
        if let error = object["error"] as? [String: Any] { return error["message"] as? String }
        return object["error"] as? String
    }

    // MARK: Modelos

    /// Modelos de chat disponibles con esa API key (vacío si no se pudo consultar).
    static func models(engine: LLMEngine, apiKey: String) async -> [String] {
        guard !apiKey.isEmpty else { return [] }
        var request: URLRequest
        switch engine {
        case .claude:
            request = URLRequest(url: anthropicURL.appendingPathComponent("models"))
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        case .ollamaCloud:
            request = URLRequest(url: ollamaCloudURL.appendingPathComponent("api/tags"))
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        default:
            guard let base = engine.openAIBase else { return [] }
            request = URLRequest(url: base.appendingPathComponent("models"))
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 8
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        let entries = (object["data"] as? [[String: Any]]) ?? (object["models"] as? [[String: Any]]) ?? []
        let ids = entries.compactMap { ($0["id"] as? String) ?? ($0["name"] as? String) ?? ($0["model"] as? String) }
            .map { $0.hasPrefix("models/") ? String($0.dropFirst(7)) : $0 }
        let excluded = ["embed", "audio", "realtime", "transcribe", "tts", "image", "dall-e", "moderation",
                        "whisper", "search", "codex", "live", "veo", "imagen", "computer-use"]
        let chat = ids.filter { id in
            let lower = id.lowercased()
            return !excluded.contains(where: lower.contains)
        }
        return Array(Set(chat)).sorted { $0.localizedStandardCompare($1) == .orderedDescending }
    }

    /// Abre la conexión TLS antes de la primera sugerencia (ahorra unos cientos de ms).
    static func warmUp(engine: LLMEngine) {
        let url: URL? = switch engine {
        case .claude: anthropicURL
        case .ollamaCloud: ollamaCloudURL
        default: engine.openAIBase
        }
        guard let url else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 5
        URLSession.shared.dataTask(with: request).resume()
    }
}

/// Recuerda qué valor de esfuerzo aceptó cada modelo.
private actor EffortMemo {
    private var indices: [String: Int] = [:]
    func index(for key: String) -> Int? { indices[key] }
    func set(_ index: Int, for key: String) { indices[key] = index }
}
