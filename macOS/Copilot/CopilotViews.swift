import SwiftUI

// MARK: Panel flotante

/// Contenido del prompter en modo Copiloto: "Respuesta IA" con la sugerencia grande y, debajo, lo último que se dijo.
struct CopilotPanelContent: View {
    @ObservedObject var copilot: CopilotModel
    var fontSize: CGFloat = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            responseHeader
            suggestionArea
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            TranscriptStrip(lines: Array(copilot.lines.suffix(2)), notice: copilot.notice)
        }
    }

    private var responseHeader: some View {
        HStack(spacing: 7) {
            HugeIcon(.aiMagic, size: 15)
                .foregroundStyle(Theme.accent)
            Text("AI answer")
                .font(.display(13.5, .semibold))
                .foregroundStyle(.white)
            Spacer(minLength: 8)
            HStack(spacing: 3) {
                LiveDot(active: copilot.isListening, size: 6)
                    .frame(width: 14, height: 14)
                Text(copilot.status.text)
                    .font(.display(12, .medium))
                    .foregroundStyle(.white.opacity(copilot.isListening ? 0.8 : 0.45))
                    .lineLimit(1)
            }
            if !copilot.suggestion.isEmpty {
                Button { copilot.copySuggestion() } label: {
                    HugeIcon(.copy, size: 14)
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                .help("Copy suggestion")
            }
        }
        .frame(height: 24)
    }

    @ViewBuilder private var suggestionArea: some View {
        if let error = copilot.suggestionError {
            IconLabel(icon: .alert, text: error)
                .textStyle(.callout)
                .foregroundStyle(Theme.secondaryText)
        } else if !copilot.suggestion.isEmpty {
            ScrollView(showsIndicators: false) {
                Text(copilot.suggestion)
                    .font(.text(fontSize, .medium))
                    .lineSpacing(fontSize * 0.2)
                    .foregroundStyle(.white.opacity(0.94))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 14)
                    .animation(.easeOut(duration: 0.15), value: copilot.suggestion)
            }
            // Si no cabe, se desvanece abajo en vez de cortarse a media línea.
            .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.82),
                                         .init(color: .clear, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
        } else if copilot.isThinking {
            ThinkingIndicator(since: copilot.thinkingSince, engine: copilot.settings.engine)
        } else {
            CopilotPlaceholder(status: copilot.status, engine: copilot.settings.engine)
        }
    }
}

/// Ícono de Hugeicons + texto, alineados a la primera línea.
struct IconLabel: View {
    let icon: HugeIcon.Name
    let text: String
    var iconSize: CGFloat = 14

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            HugeIcon(icon, size: iconSize)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
            Text(text)
        }
    }
}

/// Texto de ayuda según el estado.
private struct CopilotPlaceholder: View {
    let status: CopilotModel.Status
    let engine: LLMEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch status {
            case .downloading(let progress):
                Text("Downloading Whisper to transcribe on your Mac…")
                    .foregroundStyle(Theme.secondaryText)
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(.white)
                    .frame(maxWidth: 260)
            case .preparing:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Preparing Whisper… the first time takes a moment.")
                }
                .foregroundStyle(Theme.secondaryText)
            case .listening:
                Text("Listening. When the other person finishes talking, you'll see what to say here.")
                    .foregroundStyle(Theme.secondaryText)
                shortcutHint("to ask for a suggestion now")
            case .failed(let message):
                IconLabel(icon: .alert, text: message)
                    .foregroundStyle(Theme.secondaryText)
            case .idle:
                Text("Press the mic and Cue will tell you what to answer.")
                    .foregroundStyle(Theme.secondaryText)
                Text(engine.isLocal ? "Whisper and local AI · nothing leaves your Mac"
                                    : "Whisper on your Mac · answers by \(engine.label)")
                    .textStyle(.caption, weight: .medium)
                    .foregroundStyle(Theme.tertiaryText)
            }
        }
        .textStyle(.callout)
    }

    private func shortcutHint(_ text: LocalizedStringKey) -> some View {
        HStack(spacing: 7) {
            KeyCombo(keys: [.control, .option, .returnKey])
            Text(text)
                .textStyle(.caption, weight: .medium)
                .foregroundStyle(Theme.tertiaryText)
        }
    }
}

/// Las últimas frases de la conversación, en pequeño.
struct TranscriptStrip: View {
    let lines: [TranscriptLine]
    var notice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let notice {
                IconLabel(icon: .info, text: notice, iconSize: 13)
                    .textStyle(.caption, weight: .medium)
                    .foregroundStyle(Theme.tertiaryText)
                    .lineLimit(2)
            }
            ForEach(lines) { line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    SpeakerTag(speaker: line.speaker)
                    Text(line.text)
                        .textStyle(.footnote, weight: .regular)
                        .foregroundStyle(line.speaker == .them ? Theme.secondaryText : Theme.tertiaryText)
                        .lineLimit(2)
                        .truncationMode(.head)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SpeakerTag: View {
    let speaker: TranscriptLine.Speaker

    var body: some View {
        Text(speaker.label.uppercased())
            .font(.mono(9.5, .semibold))
            .tracking(0.4)
            .foregroundStyle(speaker == .them ? .white.opacity(0.85) : Theme.tertiaryText)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Pill().fill(.white.opacity(speaker == .them ? 0.12 : 0.06)))
            .fixedSize()
    }
}

/// Tres puntos que respiran mientras la IA piensa. Si tarda, explica por qué.
struct ThinkingIndicator: View {
    var since: Date?
    var engine: LLMEngine = .apple

    private var slowHint: String {
        switch engine {
        case .ollama: String(localized: "The local AI is reading your context. The first time is slow; after that it's almost instant.")
        case .apple: String(localized: "Apple Intelligence is processing your context.")
        default: String(localized: "Waiting for \(engine.label)…")
        }
    }

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let waited = since.map { timeline.date.timeIntervalSince($0) } ?? 0
            VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                HStack(spacing: 5) {
                    ForEach(0..<3) { index in
                        Circle()
                            .fill(Theme.accent)
                            .frame(width: 6, height: 6)
                            .opacity(0.25 + 0.75 * (0.5 + 0.5 * sin(t * 5 - Double(index) * 0.7)))
                    }
                }
                Text(waited >= 1 ? "Thinking… \(Int(waited)) s" : "Thinking…")
                    .textStyle(.callout)
                    .foregroundStyle(Theme.secondaryText)
            }
            if waited >= 4 {
                Text(slowHint)
                    .textStyle(.caption, weight: .medium)
                    .foregroundStyle(Theme.tertiaryText)
                    .transition(.opacity)
            }
            }
        }
    }
}

/// Punto verde que late mientras se escucha.
struct LiveDot: View {
    var active: Bool
    var size: CGFloat = 7

    var body: some View {
        TimelineView(.animation(paused: !active)) { timeline in
            let phase = active ? timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6 : 0
            ZStack {
                if active {
                    Circle()
                        .stroke(Theme.accent.opacity(0.8 * (1 - phase)), lineWidth: 1.5)
                        .frame(width: size * (1 + phase * 1.6), height: size * (1 + phase * 1.6))
                }
                Circle()
                    .fill(active ? Theme.accent : Color.white.opacity(0.3))
                    .frame(width: size, height: size)
                    .shadow(color: active ? Theme.accent.opacity(0.9) : .clear, radius: 4)
            }
            .frame(width: size * 2.6, height: size * 2.6)
        }
    }
}

// MARK: Ventana principal

/// Configuración del Copiloto: contexto, IA y escucha. Tarjetas grises sin borde sobre el panel.
struct CopilotSetupView: View {
    @ObservedObject var model: MacAppModel
    @ObservedObject var copilot: CopilotModel
    @ObservedObject var settings: CopilotSettings

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                header
                    .padding(.bottom, 14)
                contextCard
                HStack(alignment: .top, spacing: 12) {
                    aiCard
                    listenCard
                }
                if !copilot.lines.isEmpty { transcriptCard }
            }
            .padding(.horizontal, 40)
            .padding(.top, 52)
            .padding(.bottom, 32)
            .frame(maxWidth: 880, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .task { await copilot.refreshOllamaModels() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Copilot")
                    .font(.display(30, .bold))
                    .tracking(-0.6)
                Text(settings.engine.isLocal
                     ? "Listens to the conversation with Whisper and suggests what to say with local AI. Nothing leaves your Mac."
                     : "Listens to the conversation with Whisper (on your Mac) and suggests what to say with \(settings.engine.label). The transcript and context are sent to \(settings.engine.company).")
                    .font(.text(14))
                    .lineSpacing(2)
                    .foregroundStyle(Theme.Window.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button {
                model.showCopilot()
                if !copilot.isBusy { copilot.start() }
            } label: {
                HStack(spacing: 7) {
                    HugeIcon(copilot.isBusy ? .layoutTop : .mic, size: 14, filled: !copilot.isBusy)
                    Text(copilot.isBusy ? "Open panel" : "Start listening")
                }
            }
            .buttonStyle(WindowButtonStyle(kind: .accent))
            .fixedSize()
        }
    }

    private var contextCard: some View {
        SetupCard(title: "Context", icon: .quote,
                  footer: "Who you are, what the conversation is about, your goals and the facts the AI should know.") {
            TextEditor(text: $settings.context)
                .font(.text(14))
                .lineSpacing(4)
                .foregroundStyle(Theme.Window.text.opacity(0.92))
                .scrollContentBackground(.hidden)
                // Altura fija: un contexto largo se desplaza dentro y no empuja las tarjetas de abajo.
                .frame(height: 190)
                .overlay(alignment: .topLeading) {
                    if settings.context.isEmpty {
                        Text("E.g.: Interview for Senior iOS Developer at Acme. 6 years with Swift and SwiftUI; I led the payments app at Bank X (2M users). Salary expectation: 85k USD. Goal: get to the technical round.")
                            .font(.text(14))
                            .lineSpacing(4)
                            .foregroundStyle(Theme.Window.tertiaryText)
                            .padding(.horizontal, 5)
                            .allowsHitTesting(false)
                    }
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 10)
                .surface(Theme.Window.control, radius: 10)
        }
    }

    private var aiCard: some View {
        SetupCard(title: "AI", icon: .aiMagic) {
            VStack(alignment: .leading, spacing: 14) {
                FieldRow("Engine") {
                    MenuField(title: settings.engine.label) {
                        Picker("Engine", selection: $settings.engine) {
                            Section("On your Mac") {
                                ForEach(LLMEngine.allCases.filter(\.isLocal)) { Text($0.label).tag($0) }
                            }
                            Section("In the cloud (with your API key)") {
                                ForEach(LLMEngine.allCases.filter { !$0.isLocal }) { Text($0.label).tag($0) }
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    }
                }

                switch settings.engine {
                case .apple:
                    if let reason = LocalLLM.appleAvailability {
                        IconLabel(icon: .alert, text: reason)
                            .foregroundStyle(Theme.Window.secondaryText)
                    } else {
                        IconLabel(icon: .checkCircle, text: String(localized: "Apple model on your Mac. Ready."))
                            .foregroundStyle(Theme.Window.secondaryText)
                    }
                case .ollama:
                    if copilot.ollamaModels.isEmpty {
                        IconLabel(icon: .alert, text: String(localized: "Open Ollama and download a model (e.g. ollama pull qwen2.5:7b)."))
                            .foregroundStyle(Theme.Window.secondaryText)
                    } else {
                        FieldRow("Model") {
                            MenuField(title: settings.ollamaModel.isEmpty ? String(localized: "Choose model") : settings.ollamaModel) {
                                Picker("Model", selection: $settings.ollamaModel) {
                                    ForEach(copilot.ollamaModels, id: \.self) { Text($0).tag($0) }
                                }
                                .pickerStyle(.inline)
                                .labelsHidden()
                            }
                        }
                    }
                    Text("Local models are slow with a long context. For instant answers, use a cloud one.")
                        .foregroundStyle(Theme.Window.tertiaryText)
                    Button("Refresh models") { Task { await copilot.refreshOllamaModels() } }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.Window.accentText)
                default:
                    CloudProviderSettings(engine: settings.engine, settings: settings, copilot: copilot)
                        .id(settings.engine)
                }

                Toggle("Suggest only when the other person finishes", isOn: $settings.autoSuggest)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .font(.text(13))
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var listenCard: some View {
        SetupCard(title: "Listening", icon: .audioWave) {
            VStack(alignment: .leading, spacing: 14) {
                FieldRow("Whisper") {
                    MenuField(title: settings.whisperModel.label) {
                        Picker("Whisper", selection: $settings.whisperModel) {
                            ForEach(CopilotSettings.WhisperModel.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    }
                }
                .disabled(copilot.isBusy)
                FieldRow("Language") {
                    MenuField(title: settings.language.label) {
                        Picker("Language", selection: $settings.language) {
                            ForEach(CopilotSettings.Language.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    }
                }
                .disabled(copilot.isBusy)
                Toggle("Also hear the other person (Mac audio)", isOn: $settings.captureSystemAudio)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(copilot.isBusy)
                HStack(spacing: 6) {
                    LiveDot(active: copilot.isListening, size: 6)
                        .frame(width: 14, height: 14)
                    Text(copilot.status.text)
                        .foregroundStyle(Theme.Window.secondaryText)
                        .lineLimit(3)
                }
                if let notice = copilot.notice {
                    Text(notice)
                        .foregroundStyle(Theme.Window.tertiaryText)
                }
                IconLabel(icon: .info, text: String(localized: "Use headphones so your mic doesn't pick up the other person."), iconSize: 13)
                    .foregroundStyle(Theme.Window.tertiaryText)
            }
            .font(.text(13))
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var transcriptCard: some View {
        SetupCard(title: "Conversation", icon: .chat) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(copilot.lines.suffix(12)) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        SpeakerTag(speaker: line.speaker)
                        Text(line.text)
                            .font(.text(13))
                            .foregroundStyle(line.speaker == .them ? Theme.Window.text.opacity(0.88) : Theme.Window.secondaryText)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }
}

/// Etiqueta pequeña encima de un control.
private struct FieldRow<Content: View>: View {
    let label: LocalizedStringKey
    @ViewBuilder let content: Content

    init(_ label: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.display(11.5, .medium))
                .foregroundStyle(Theme.Window.tertiaryText)
            content
        }
    }
}

/// API key y modelo de un proveedor en la nube.
private struct CloudProviderSettings: View {
    let engine: LLMEngine
    @ObservedObject var settings: CopilotSettings
    @ObservedObject var copilot: CopilotModel
    @State private var key = ""
    @State private var loaded = false
    @State private var loadingModels = false

    private var models: [String] {
        let fetched = copilot.cloudModels[engine] ?? []
        return fetched.isEmpty ? engine.suggestedModels : fetched
    }

    private var modelBinding: Binding<String> {
        Binding(get: { settings.model(for: engine) }, set: { settings.setModel($0, for: engine) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            FieldRow("API key") {
                HStack(spacing: 8) {
                    SecureField("Paste your \(engine.label) API key", text: $key)
                        .font(.mono(12))
                        .fieldBackground()
                        .onSubmit { Task { await loadModels() } }
                    if let url = engine.keyURL {
                        Link("Get key", destination: url)
                            .font(.display(12, .medium))
                            .foregroundStyle(Theme.Window.accentText)
                    }
                }
            }

            FieldRow("Model") {
                HStack(spacing: 8) {
                    TextField("Model", text: modelBinding)
                        .font(.mono(12))
                        .fieldBackground()
                    Menu {
                        ForEach(models, id: \.self) { model in
                            Button(model) { settings.setModel(model, for: engine) }
                        }
                        Divider()
                        Button("Load from my account") { Task { await loadModels() } }
                            .disabled(key.isEmpty)
                    } label: {
                        Group {
                            if loadingModels {
                                ProgressView().controlSize(.small)
                            } else {
                                HugeIcon(.unfold, size: 13)
                            }
                        }
                        .foregroundStyle(Theme.Window.secondaryText)
                        .frame(width: 30, height: 30)
                        .surface(Theme.Window.control, radius: 8)
                        .contentShape(Rectangle())
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Models")
                }
            }

            Text(key.isEmpty
                 ? "Stored in the macOS Keychain, not in files."
                 : "The key is in the macOS Keychain. The transcript and your context are sent to \(engine.company) to generate each answer.")
                .foregroundStyle(Theme.Window.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task {
            key = KeychainStore.apiKey(for: engine)
            loaded = true
            if !key.isEmpty, copilot.cloudModels[engine] == nil { await loadModels() }
        }
        .onChange(of: key) { _, newValue in
            guard loaded else { return }
            KeychainStore.setAPIKey(newValue, for: engine)
        }
    }

    private func loadModels() async {
        guard !key.isEmpty else { return }
        loadingModels = true
        await copilot.refreshCloudModels(for: engine)
        loadingModels = false
    }
}

/// Tarjeta gris sin borde, con título e ícono.
private struct SetupCard<Content: View>: View {
    let title: LocalizedStringKey
    let icon: HugeIcon.Name
    var footer: LocalizedStringKey?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                HugeIcon(icon, size: 15)
                    .foregroundStyle(Theme.Window.accentText)
                Text(title)
                    .font(.display(13.5, .semibold))
            }
            content
            if let footer {
                Text(footer)
                    .font(.text(12))
                    .foregroundStyle(Theme.Window.tertiaryText)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(Theme.Window.raised, radius: 14)
    }
}
