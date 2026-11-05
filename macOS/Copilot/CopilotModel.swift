import AppKit
import AVFoundation
import Foundation
import os

/// Una frase de la conversación.
struct TranscriptLine: Identifiable, Equatable {
    enum Speaker {
        case me, them

        var label: String {
            switch self {
            case .me: String(localized: "You")
            case .them: String(localized: "Them")
            }
        }
        /// Cómo se nombra en el prompt de la IA.
        var promptLabel: String {
            switch self {
            case .me: "Me"
            case .them: "Them"
            }
        }
    }

    let id = UUID()
    let speaker: Speaker
    var text: String
    var date: Date
}

/// Copiloto de conversación: escucha (Whisper), transcribe y pide a la IA (local o en la nube) qué decir a continuación.
@MainActor
final class CopilotModel: ObservableObject {
    enum Status: Equatable {
        case idle
        case downloading(Double)
        case preparing
        case listening
        case failed(String)

        var text: String {
            switch self {
            case .idle: String(localized: "Paused")
            case .downloading(let progress): String(localized: "Downloading Whisper · \(Int(progress * 100))%")
            case .preparing: String(localized: "Preparing Whisper…")
            case .listening: String(localized: "Listening…")
            case .failed(let message): message
            }
        }
    }

    let settings = CopilotSettings()

    @Published private(set) var status: Status = .idle {
        didSet {
            if status == .listening {
                if listeningSince == nil { listeningSince = .now }
            } else {
                listeningSince = nil
            }
        }
    }
    /// Desde cuándo se está escuchando (para el reloj del panel). nil si no se escucha.
    @Published private(set) var listeningSince: Date?
    @Published private(set) var lines: [TranscriptLine] = []
    @Published private(set) var suggestion = ""
    @Published private(set) var isThinking = false {
        didSet { thinkingSince = isThinking ? (thinkingSince ?? .now) : nil }
    }
    /// Desde cuándo espera la respuesta (para avisar si tarda).
    @Published private(set) var thinkingSince: Date?
    @Published private(set) var suggestionError: String?
    /// Aviso no bloqueante (p. ej. sin permiso para el audio del sistema: solo se escucha tu micrófono).
    @Published private(set) var notice: String?
    @Published private(set) var ollamaModels: [String] = []
    /// Modelos que ofrece cada proveedor en la nube con tu API key (se cargan desde la configuración).
    @Published private(set) var cloudModels: [LLMEngine: [String]] = [:]

    var isListening: Bool { status == .listening }
    var isBusy: Bool {
        switch status {
        case .downloading, .preparing, .listening: true
        default: false
        }
    }

    private let transcriber = WhisperTranscriber()
    private let microphone = MicrophoneCapture()
    private let systemAudio = SystemAudioCapture()
    private let micSegmenter = SpeechSegmenter()
    /// La otra persona: frase cerrada con menos silencio, para responder antes.
    private let systemSegmenter = SpeechSegmenter(silence: 0.5)
    private var segments: SegmentQueue?
    private static let log = Logger(subsystem: "com.manudev.cue", category: "copilot")
    /// Cuándo se pidió la sugerencia en curso (para medir lo que tarda la IA).
    private var suggestionStartedAt: Date?
    private var workerTask: Task<Void, Never>?
    private var suggestionTask: Task<Void, Never>?
    private var autoSuggestTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?

    init() {
        Task { await refreshOllamaModels() }
    }

    // MARK: Escuchar

    func toggleListening() {
        if isBusy { stop() } else { start() }
    }

    func start() {
        guard !isBusy else { return }
        notice = nil
        startTask = Task { await startListening() }
    }

    func stop() {
        startTask?.cancel()
        startTask = nil
        microphone.stop()
        systemAudio.stop()
        segments?.finish()
        segments = nil
        workerTask = nil
        autoSuggestTask?.cancel()
        status = .idle
    }

    func clearConversation() {
        lines.removeAll()
        suggestion = ""
        suggestionError = nil
    }

    private func startListening() async {
        status = .preparing
        switch settings.engine {
        case .apple: break
        case .ollama: LocalLLM.warmUpOllama(model: settings.ollamaModel, instructions: Self.instructions(context: settings.context))
        default: CloudLLM.warmUp(engine: settings.engine)
        }
        do {
            let variant = settings.whisperModel.rawValue
            if WhisperTranscriber.localFolder(for: variant) == nil { status = .downloading(0) }
            try await transcriber.prepare(variant: variant) { progress in
                Task { @MainActor [weak self] in
                    guard let self, case .downloading = self.status else { return }
                    self.status = progress >= 1 ? .preparing : .downloading(progress)
                }
            }
            if case .downloading = status { status = .preparing }
        } catch {
            if !Task.isCancelled { status = .failed(String(localized: "Couldn't load Whisper: \(error.localizedDescription)")) }
            return
        }
        guard !Task.isCancelled else { return }

        let queue = SegmentQueue()
        segments = queue
        micSegmenter.onSegment = { queue.push(.me, $0) }
        systemSegmenter.onSegment = { queue.push(.them, $0) }
        let micSegmenter = micSegmenter
        let systemSegmenter = systemSegmenter
        microphone.onSamples = { micSegmenter.append($0) }
        systemAudio.onSamples = { systemSegmenter.append($0) }
        systemAudio.onStop = { [weak self] error in
            Task { @MainActor in self?.notice = String(localized: "System audio stopped: \(error.localizedDescription)") }
        }

        let transcriber = transcriber
        let language = settings.language.whisperCode
        // Whisper transcribe de a una frase: lo de la otra persona va primero, porque es lo que dispara la respuesta.
        workerTask = Task { [weak self] in
            while let (speaker, samples) = await queue.next() {
                let started = Date()
                guard let text = try? await transcriber.transcribe(samples, language: language), !text.isEmpty else { continue }
                Self.log.info("whisper \(speaker == .them ? "them" : "me", privacy: .public): \(Double(samples.count) / 16_000, format: .fixed(precision: 1))s audio in \(Date().timeIntervalSince(started) * 1000, format: .fixed(precision: 0))ms")
                self?.append(text, from: speaker)
            }
        }

        var listening = false
        if await AVCaptureDevice.requestAccess(for: .audio) {
            do {
                try microphone.start()
                listening = true
            } catch {
                notice = String(localized: "Couldn't open the microphone: \(error.localizedDescription)")
            }
        } else {
            notice = String(localized: "No microphone permission. Turn it on in System Settings › Privacy › Microphone.")
        }
        if settings.captureSystemAudio {
            do {
                try await systemAudio.start()
                listening = true
            } catch {
                notice = String(localized: "To hear the other person, allow Cue “Screen & System Audio Recording” in System Settings › Privacy.")
            }
        }
        guard !Task.isCancelled else { return }
        if listening {
            status = .listening
        } else {
            stop()
            status = .failed(notice ?? String(localized: "There's no audio to listen to."))
        }
    }

    private func append(_ text: String, from speaker: TranscriptLine.Speaker) {
        let now = Date()
        if var last = lines.last, last.speaker == speaker, now.timeIntervalSince(last.date) < 6 {
            last.text += " " + text
            last.date = now
            lines[lines.count - 1] = last
        } else {
            lines.append(TranscriptLine(speaker: speaker, text: text, date: now))
            if lines.count > 200 { lines.removeFirst(lines.count - 200) }
        }
        // Solo vale la pena sugerir si dijo algo con sentido: Whisper a veces "oye" una palabra suelta en el ruido.
        if speaker == .them, settings.autoSuggest, let last = lines.last, Self.isMeaningful(last.text) {
            scheduleAutoSuggestion()
        }
    }

    /// Una pregunta, o al menos tres palabras.
    static func isMeaningful(_ text: String) -> Bool {
        if text.contains("?") || text.contains("¿") { return true }
        return text.split(whereSeparator: { $0.isWhitespace }).filter { $0.count > 1 }.count >= 3
    }

    /// Pide la respuesta casi al instante (la frase ya se cerró tras medio segundo de silencio). Si la otra
    /// persona sigue hablando, llega otra frase y la sugerencia se vuelve a pedir con todo el contexto.
    private func scheduleAutoSuggestion() {
        autoSuggestTask?.cancel()
        autoSuggestTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self?.suggest()
        }
    }

    // MARK: Sugerencia

    /// "¿Qué digo?": pide a la IA una respuesta para lo último de la conversación.
    func suggest() {
        suggestionTask?.cancel()
        autoSuggestTask?.cancel()
        let instructions = Self.instructions(context: settings.context)
        let prompt = Self.prompt(lines: Array(lines.suffix(16)))
        let engine = settings.engine
        let model = settings.model(for: engine)
        isThinking = true
        suggestionError = nil
        suggestion = ""
        suggestionStartedAt = .now
        suggestionTask = Task { [weak self] in
            do {
                for try await text in LocalLLM.stream(engine: engine, model: model, instructions: instructions, prompt: prompt) {
                    guard !Task.isCancelled else { return }
                    if let self, self.suggestion.isEmpty, let started = self.suggestionStartedAt {
                        Self.log.info("ai \(engine.rawValue, privacy: .public) first text in \(Date().timeIntervalSince(started) * 1000, format: .fixed(precision: 0))ms")
                    }
                    self?.suggestion = Self.tidy(text)
                }
            } catch {
                guard !Task.isCancelled else { return }
                self?.suggestionError = error.localizedDescription
            }
            guard !Task.isCancelled else { return }
            self?.isThinking = false
        }
    }

    /// Carga Whisper en segundo plano en cuanto se abre el Copiloto, para que al pulsar el micrófono ya esté listo.
    func prewarm() {
        guard !isBusy else { return }
        let transcriber = transcriber
        let variant = settings.whisperModel.rawValue
        Task.detached(priority: .utility) { await transcriber.prewarm(variant: variant) }
    }

    func copySuggestion() {
        guard !suggestion.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(suggestion, forType: .string)
    }

    func refreshOllamaModels() async {
        ollamaModels = await LocalLLM.ollamaModels()
        if settings.ollamaModel.isEmpty || !ollamaModels.contains(settings.ollamaModel) {
            let preferred = ["qwen2.5:7b", "llama3.2:latest"]
            if let pick = preferred.first(where: ollamaModels.contains) ?? ollamaModels.first {
                settings.ollamaModel = pick
            }
        }
    }

    /// Carga los modelos disponibles con la API key guardada. Si el modelo elegido no existe, toma uno que sí.
    func refreshCloudModels(for engine: LLMEngine) async {
        guard !engine.isLocal else { return }
        let list = await CloudLLM.models(engine: engine, apiKey: KeychainStore.apiKey(for: engine))
        cloudModels[engine] = list
        let current = settings.model(for: engine)
        if !list.isEmpty, !list.contains(current) {
            if let preferred = engine.suggestedModels.first(where: list.contains) ?? list.first {
                settings.setModel(preferred, for: engine)
            }
        }
    }

    // MARK: Prompt

    static func instructions(context: String) -> String {
        let trimmed = context.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        You are someone's copilot during a live conversation (interview, meeting, call or sales pitch). \
        You see the transcript and instantly give them what they can say next.

        Context the person prepared before starting:
        <context>
        \(trimmed.isEmpty ? "(no context)" : trimmed)
        </context>

        Response format (required):
        - Only the text the person will say out loud, in the first person.
        - One or two sentences, 40 words max.
        - Plain text: no headings, no markdown, no bullets, no quotes, no "Answer:" and no explaining what you do.
        - Don't ask yourself questions or talk about the person in the third person.

        How to decide what to say:
        - Reply to the last thing the other person ("Them") said. If they asked something, answer it directly using the context.
        - The transcript comes from speech recognition and may contain misspelled or meaningless words: infer \
        the intent. If the last line makes no sense or looks like noise, suggest a short sentence to ask them to repeat \
        or to continue the current topic.
        - Use facts from the context when they help (numbers, names, decisions). Don't invent facts that aren't in the \
        context or the conversation.
        - Speak in the language of the conversation, with a natural, confident tone.
        """
    }

    static func prompt(lines: [TranscriptLine]) -> String {
        guard !lines.isEmpty else {
            return "The conversation hasn't started yet. Give me a good opening line based on the context."
        }
        let transcript = lines.map { "\($0.speaker.promptLabel): \($0.text)" }.joined(separator: "\n")
        var prompt = """
        Recent transcript ("Them" is the other person; "Me" is the person you're helping):
        \(transcript)
        """
        if let last = lines.last(where: { $0.speaker == .them }) {
            prompt += "\n\nThe last thing the other person said: \(last.text)"
        }
        prompt += "\n\nWrite only what Me should say now."
        return prompt
    }

    /// Quita títulos, negritas, comillas y etiquetas que algunos modelos añaden ("### Respuesta", "Yo: …").
    static func tidy(_ text: String) -> String {
        var result = text
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
            .joined(separator: "\n")
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = ["Me:", "You:", "Answer:", "Suggestion:", "You could say:", "Say:",
                        "Yo:", "Tú:", "Respuesta:", "Sugerencia:", "Puedes decir:", "Podrías decir:", "Di:"]
        for prefix in prefixes where result.lowercased().hasPrefix(prefix.lowercased()) {
            result = String(result.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”«» "))
    }
}

/// Frases pendientes de transcribir. Las de la otra persona salen primero; si tus frases se acumulan,
/// se descartan las más viejas (solo dan contexto y no deben retrasar la respuesta).
final class SegmentQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var them: [[Float]] = []
    private var me: [[Float]] = []
    private var waiter: CheckedContinuation<(TranscriptLine.Speaker, [Float])?, Never>?
    private var finished = false
    private static let maxPendingMine = 2

    func push(_ speaker: TranscriptLine.Speaker, _ samples: [Float]) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        if let waiter {
            self.waiter = nil
            lock.unlock()
            waiter.resume(returning: (speaker, samples))
            return
        }
        if speaker == .them {
            them.append(samples)
        } else {
            me.append(samples)
            if me.count > Self.maxPendingMine { me.removeFirst(me.count - Self.maxPendingMine) }
        }
        lock.unlock()
    }

    /// La siguiente frase, o nil cuando se dejó de escuchar.
    func next() async -> (TranscriptLine.Speaker, [Float])? {
        await withCheckedContinuation { continuation in
            lock.lock()
            if !them.isEmpty {
                let item = them.removeFirst()
                lock.unlock()
                continuation.resume(returning: (.them, item))
            } else if !me.isEmpty {
                let item = me.removeFirst()
                lock.unlock()
                continuation.resume(returning: (.me, item))
            } else if finished {
                lock.unlock()
                continuation.resume(returning: nil)
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }

    func finish() {
        lock.lock()
        finished = true
        let waiter = waiter
        self.waiter = nil
        them.removeAll()
        me.removeAll()
        lock.unlock()
        waiter?.resume(returning: nil)
    }
}
