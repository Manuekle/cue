import Foundation
import Combine

/// Guarda guiones y sesiones en JSON local (Application Support).
final class ScriptStore: ObservableObject {
    @Published private(set) var scripts: [Script] = []
    @Published private(set) var sessions: [Session] = []
    /// Sesión activa. `nil` = "Todos" (muestra todos los guiones).
    @Published private(set) var currentSessionID: Session.ID?

    private struct SessionsFile: Codable {
        var sessions: [Session]
        var currentSessionID: Session.ID?
    }

    private let fileURL: URL
    private let sessionsURL: URL
    private var saveWorkItem: DispatchWorkItem?

    init(fileName: String = "scripts.json", sessionsFileName: String = "sessions.json") {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pronter", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent(fileName)
        sessionsURL = base.appendingPathComponent(sessionsFileName)
        load()
    }

    // MARK: Consulta

    /// Guiones de la sesión activa (o todos si no hay sesión activa).
    var visibleScripts: [Script] {
        guard let currentSessionID else { return scripts }
        return scripts.filter { $0.sessionID == currentSessionID }
    }

    var currentSession: Session? {
        guard let currentSessionID else { return nil }
        return sessions.first { $0.id == currentSessionID }
    }

    func script(id: Script.ID?) -> Script? {
        guard let id else { return nil }
        return scripts.first { $0.id == id }
    }

    func session(id: Session.ID?) -> Session? {
        guard let id else { return nil }
        return sessions.first { $0.id == id }
    }

    func scriptCount(in sessionID: Session.ID?) -> Int {
        guard let sessionID else { return scripts.count }
        return scripts.filter { $0.sessionID == sessionID }.count
    }

    // MARK: Guiones

    /// Crea un guion dentro de la sesión activa.
    @discardableResult
    func create() -> Script {
        let script = Script(title: "", body: "", sessionID: currentSessionID)
        scripts.insert(script, at: 0)
        scheduleSave()
        return script
    }

    func update(_ script: Script) {
        guard let index = scripts.firstIndex(where: { $0.id == script.id }) else { return }
        guard scripts[index] != script else { return }
        var updated = script
        updated.updatedAt = Date()
        scripts[index] = updated
        scheduleSave()
    }

    func delete(id: Script.ID) {
        scripts.removeAll { $0.id == id }
        scheduleSave()
    }

    /// Borra por posición dentro de `visibleScripts` (lo que ve la lista).
    func delete(atOffsets offsets: IndexSet) {
        let visible = visibleScripts
        let ids = Set(offsets.compactMap { visible.indices.contains($0) ? visible[$0].id : nil })
        scripts.removeAll { ids.contains($0.id) }
        scheduleSave()
    }

    /// Mueve un guion a otra sesión (`nil` = sin sesión).
    func move(scriptID: Script.ID, to sessionID: Session.ID?) {
        guard let index = scripts.firstIndex(where: { $0.id == scriptID }) else { return }
        if let sessionID, !sessions.contains(where: { $0.id == sessionID }) { return }
        guard scripts[index].sessionID != sessionID else { return }
        scripts[index].sessionID = sessionID
        scheduleSave()
    }

    // MARK: Sesiones

    /// Crea una sesión y la deja activa.
    @discardableResult
    func createSession(named name: String) -> Session {
        let fallback = String(localized: "Session \(sessions.count + 1)")
        let session = Session(name: Session.cleanName(name, fallback: fallback))
        sessions.append(session)
        currentSessionID = session.id
        scheduleSave()
        return session
    }

    func renameSession(id: Session.ID, to name: String) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].name = Session.cleanName(name, fallback: sessions[index].name)
        scheduleSave()
    }

    /// Elimina la sesión. Sus guiones NO se borran: quedan sin sesión (visibles en "Todos").
    func deleteSession(id: Session.ID) {
        sessions.removeAll { $0.id == id }
        for index in scripts.indices where scripts[index].sessionID == id {
            scripts[index].sessionID = nil
        }
        if currentSessionID == id { currentSessionID = nil }
        scheduleSave()
    }

    /// Cambia la sesión activa (`nil` = Todos).
    func selectSession(_ id: Session.ID?) {
        let target = (id != nil && sessions.contains { $0.id == id }) ? id : nil
        guard currentSessionID != target else { return }
        currentSessionID = target
        scheduleSave()
    }

    // MARK: Persistencia

    func saveNow() {
        saveWorkItem?.cancel()
        write()
    }

    private func load() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([Script].self, from: data) {
            scripts = decoded
        } else {
            scripts = [Script.sample]
            writeScripts()
        }

        if let data = try? Data(contentsOf: sessionsURL),
           let file = try? JSONDecoder().decode(SessionsFile.self, from: data) {
            sessions = file.sessions
            if let saved = file.currentSessionID, sessions.contains(where: { $0.id == saved }) {
                currentSessionID = saved
            }
        }

        // Guiones apuntando a una sesión que ya no existe vuelven a "sin sesión".
        let validIDs = Set(sessions.map(\.id))
        for index in scripts.indices {
            if let sessionID = scripts[index].sessionID, !validIDs.contains(sessionID) {
                scripts[index].sessionID = nil
            }
        }
    }

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.write() }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: item)
    }

    private func write() {
        writeScripts()
        let file = SessionsFile(sessions: sessions, currentSessionID: currentSessionID)
        if let data = try? JSONEncoder().encode(file) {
            try? data.write(to: sessionsURL, options: .atomic)
        }
    }

    private func writeScripts() {
        guard let data = try? JSONEncoder().encode(scripts) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
