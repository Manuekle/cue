import AppKit
import Carbon.HIToolbox
import Combine

/// Estado de la app de Mac: guiones, prompter flotante y auto-inicio por cámara/micrófono.
final class MacAppModel: ObservableObject {
    static let shared = MacAppModel()

    let store = ScriptStore()
    let settings = PrompterSettings()
    let engine = PrompterEngine()
    let monitor = RecordingMonitor()
    /// Escucha la conversación y sugiere qué decir (Whisper + IA local).
    let copilot: CopilotModel = MainActor.assumeIsolated { CopilotModel() }
    private(set) lazy var panel = PrompterPanelController(model: self)

    @Published var selectedID: Script.ID? {
        didSet { syncEngineText() }
    }
    @Published fileprivate(set) var isPanelVisible = false
    /// `true` = prompter completo; `false` = solo la pestaña (píldora) arriba.
    @Published fileprivate(set) var isPanelExpanded = true

    enum PanelMode: String, CaseIterable, Identifiable {
        case script, copilot
        var id: String { rawValue }
        var label: String {
            switch self {
            case .script: String(localized: "Script")
            case .copilot: String(localized: "Copilot")
            }
        }
    }

    /// Qué muestra el panel flotante: el guion o el Copiloto.
    @Published var panelMode: PanelMode = .script {
        // Al pasar al Copiloto, Whisper empieza a cargar para estar listo cuando pulses el micrófono.
        didSet { if panelMode == .copilot { MainActor.assumeIsolated { copilot.prewarm() } } }
    }
    /// La ventana principal muestra la configuración del Copiloto en vez del editor.
    @Published var showsCopilotSetup = false

    private var loadedScriptID: Script.ID?
    private var cancellables = Set<AnyCancellable>()

    private init() {
        selectedID = store.visibleScripts.first?.id
        syncEngineText()

        settings.$wordsPerMinute.sink { [weak self] in self?.engine.wordsPerMinute = $0 }.store(in: &cancellables)
        settings.$countdown.sink { [weak self] in self?.engine.countdownSeconds = $0 }.store(in: &cancellables)
        store.$scripts
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.syncEngineText() }
            .store(in: &cancellables)

        Publishers.CombineLatest3(monitor.$cameraInUse, monitor.$microphoneInUse, settings.$autoStart)
            .map { camera, microphone, mode -> Bool in
                switch mode {
                case .off: false
                case .camera: camera
                case .cameraOrMicrophone: camera || microphone
                }
            }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] recording in self?.recordingChanged(recording) }
            .store(in: &cancellables)

        // Mostrar / ocultar la pestaña del notch desde la configuración.
        settings.$showsNotchTab
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] shows in self?.notchTabSettingChanged(shows) }
            .store(in: &cancellables)

        monitor.start()
        registerHotKeys()
    }

    var selectedScript: Script? { store.script(id: selectedID) }

    // MARK: Acciones

    func newScript() {
        selectedID = store.create().id
    }

    func delete(_ id: Script.ID) {
        let index = store.visibleScripts.firstIndex { $0.id == id }
        store.delete(id: id)
        if selectedID == id {
            let visible = store.visibleScripts
            let next = index.map { min($0, visible.count - 1) } ?? 0
            selectedID = visible.indices.contains(next) ? visible[next].id : nil
        }
    }

    /// Tras cambiar de sesión o mover un guion: si el guion elegido ya no se ve, elige el primero visible.
    func ensureValidSelection() {
        let visible = store.visibleScripts
        if let selectedID, visible.contains(where: { $0.id == selectedID }) { return }
        selectedID = visible.first?.id
    }

    func selectSession(_ id: Session.ID?) {
        store.selectSession(id)
        ensureValidSelection()
    }

    /// Atajo ⌥⌘N: elige el N-ésimo guion de la lista (índice desde 0). Ignora si no existe.
    func selectScript(at index: Int) {
        let visible = store.visibleScripts
        guard visible.indices.contains(index) else { return }
        chooseScript(visible[index].id)
    }

    /// Atajos ⌃⌥← / ⌃⌥→: guion anterior / siguiente (da la vuelta al llegar al final).
    func selectAdjacentScript(_ offset: Int) {
        let visible = store.visibleScripts
        guard !visible.isEmpty else { return }
        let current = visible.firstIndex { $0.id == selectedID } ?? 0
        let next = ((current + offset) % visible.count + visible.count) % visible.count
        chooseScript(visible[next].id)
    }

    /// Cambia de guion y deja el panel mostrando el guion (no el Copiloto).
    func chooseScript(_ id: Script.ID) {
        engine.pause()
        selectedID = id
        showsCopilotSetup = false
        panelMode = .script
    }

    /// Atajo ⌃⌥⌘N: cambia a la N-ésima sesión (índice desde 0). Ignora si no existe.
    func selectSession(at index: Int) {
        guard store.sessions.indices.contains(index) else { return }
        selectSession(store.sessions[index].id)
    }

    func moveScript(_ scriptID: Script.ID, to sessionID: Session.ID?) {
        store.move(scriptID: scriptID, to: sessionID)
        ensureValidSelection()
    }

    /// Muestra el prompter completo.
    func showPrompter() {
        syncEngineText()
        isPanelVisible = true
        isPanelExpanded = true
        panel.show(expanded: true)
    }

    /// Muestra solo la pestaña contraída (al abrir la app). Nada si el usuario la ocultó en la configuración.
    func showPill() {
        guard settings.showsNotchTab else { return }
        syncEngineText()
        isPanelVisible = true
        isPanelExpanded = false
        panel.show(expanded: false)
    }

    func expandPrompter() {
        guard isPanelVisible else { return showPrompter() }
        isPanelExpanded = true
        panel.setExpanded(true)
    }

    func collapsePrompter() {
        guard isPanelVisible else { return }
        // Sin pestaña en el notch, cerrar = ocultar del todo.
        guard settings.showsNotchTab else {
            engine.pause()
            isPanelVisible = false
            panel.hide(animated: true)
            return
        }
        isPanelExpanded = false
        panel.setExpanded(false)
    }

    /// "Ocultar pestaña" de los menús: la apaga en la configuración (y así sigue oculta al reabrir la app).
    func hideTab() {
        settings.showsNotchTab = false
        hidePrompter()
    }

    private func notchTabSettingChanged(_ shows: Bool) {
        if shows {
            if !isPanelVisible { showPill() }
        } else if isPanelVisible && !isPanelExpanded {
            // Abierto se queda abierto; al cerrarlo se ocultará.
            hidePrompter()
        }
    }

    /// Oculta todo, también la pestaña.
    func hidePrompter() {
        engine.pause()
        panel.hide()
        isPanelVisible = false
    }

    /// Atajo ⌃⌥P y clic en el notch: abre / contrae. Si estaba oculto, lo muestra.
    func togglePrompter() {
        if !isPanelVisible { showPrompter() }
        else if isPanelExpanded { collapsePrompter() }
        else { expandPrompter() }
    }

    func togglePlay() {
        if !isPanelVisible { showPrompter() }
        engine.togglePlay()
    }

    /// Abre el panel en modo Copiloto.
    func showCopilot() {
        panelMode = .copilot
        showPrompter()
    }

    /// ⌃⌥↩: pide una sugerencia y muestra el Copiloto.
    func suggestReply() {
        if panelMode != .copilot || !isPanelVisible || !isPanelExpanded { showCopilot() }
        MainActor.assumeIsolated { copilot.suggest() }
    }

    /// ⌃⌥L: empieza / deja de escuchar.
    func toggleListening() {
        MainActor.assumeIsolated {
            if !copilot.isBusy { showCopilot() }
            copilot.toggleListening()
        }
    }

    func restart() {
        engine.stop()
    }

    /// Llamado por el panel cuando el usuario lo cierra.
    func panelDidClose() {
        engine.pause()
        isPanelVisible = false
    }

    // MARK: Interno

    private func recordingChanged(_ recording: Bool) {
        if recording {
            guard selectedScript?.wordCount ?? 0 > 0, panelMode == .script else { return }
            showPrompter()
            engine.start()
        } else {
            engine.pause()
        }
    }

    private func syncEngineText() {
        guard let script = selectedScript else {
            engine.load(text: "", reset: true)
            loadedScriptID = nil
            return
        }
        engine.load(text: script.body, reset: script.id != loadedScriptID)
        loadedScriptID = script.id
    }

    private func registerHotKeys() {
        let hotKeys = HotKeys.shared
        hotKeys.register(kVK_Space) { [weak self] in self?.togglePlay() }
        hotKeys.register(kVK_ANSI_P) { [weak self] in self?.togglePrompter() }
        hotKeys.register(kVK_ANSI_R) { [weak self] in self?.restart() }
        hotKeys.register(kVK_UpArrow) { [weak self] in self?.settings.adjustSpeed(by: 10) }
        hotKeys.register(kVK_DownArrow) { [weak self] in self?.settings.adjustSpeed(by: -10) }
        hotKeys.register(kVK_Return) { [weak self] in self?.suggestReply() }
        hotKeys.register(kVK_ANSI_L) { [weak self] in self?.toggleListening() }

        hotKeys.register(kVK_LeftArrow) { [weak self] in self?.selectAdjacentScript(-1) }
        hotKeys.register(kVK_RightArrow) { [weak self] in self?.selectAdjacentScript(1) }

        // ⌥⌘1…9 = guion 1…9 de la lista. ⌃⌥⌘1…9 = sesión 1…9, ⌃⌥⌘0 = Todos.
        let digitKeys = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
                         kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        for (index, key) in digitKeys.enumerated() {
            hotKeys.register(key, modifiers: optionKey | cmdKey) { [weak self] in
                self?.selectScript(at: index)
            }
            hotKeys.register(key, modifiers: controlKey | optionKey | cmdKey) { [weak self] in
                self?.selectSession(at: index)
            }
        }
        hotKeys.register(kVK_ANSI_0, modifiers: controlKey | optionKey | cmdKey) { [weak self] in
            self?.selectSession(nil)
        }
    }
}
