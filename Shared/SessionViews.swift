import SwiftUI

/// Menú para cambiar de sesión y administrarlas (crear, renombrar, eliminar).
/// `onSelect` deja que cada plataforma reaccione al cambio (p. ej. reseleccionar un guion).
struct SessionMenu<MenuLabel: View>: View {
    @ObservedObject var store: ScriptStore
    var onSelect: (Session.ID?) -> Void = { _ in }
    @ViewBuilder var label: () -> MenuLabel

    @State private var showsNew = false
    @State private var showsRename = false
    @State private var showsDelete = false
    @State private var draftName = ""

    var body: some View {
        Menu {
            Button {
                choose(nil)
            } label: {
                checkLabel("All (\(store.scripts.count))", selected: store.currentSessionID == nil)
            }

            if !store.sessions.isEmpty {
                Divider()
                ForEach(store.sessions) { session in
                    Button {
                        choose(session.id)
                    } label: {
                        checkLabel("\(session.name) (\(store.scriptCount(in: session.id)))",
                                   selected: store.currentSessionID == session.id)
                    }
                }
            }

            Divider()
            Button("New session…", image: .hiPlus) {
                draftName = ""
                showsNew = true
            }
            if let current = store.currentSession {
                Button("Rename “\(current.name)”…", image: .hiPencil) {
                    draftName = current.name
                    showsRename = true
                }
                Button("Delete “\(current.name)”…", image: .hiDelete, role: .destructive) {
                    showsDelete = true
                }
            }
        } label: {
            label()
        }
        .alert("New session", isPresented: $showsNew) {
            TextField("Name", text: $draftName)
            Button("Create") {
                let session = store.createSession(named: draftName)
                onSelect(session.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Group scripts by project, channel or topic.")
        }
        .alert("Rename session", isPresented: $showsRename) {
            TextField("Name", text: $draftName)
            Button("Save") {
                if let id = store.currentSessionID { store.renameSession(id: id, to: draftName) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Delete session?", isPresented: $showsDelete) {
            Button("Delete session", role: .destructive) {
                if let id = store.currentSessionID {
                    store.deleteSession(id: id)
                    onSelect(nil)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your scripts aren't deleted: they move to “All”, with no session.")
        }
    }

    private func choose(_ id: Session.ID?) {
        store.selectSession(id)
        onSelect(id)
    }

    @ViewBuilder
    private func checkLabel(_ text: LocalizedStringKey, selected: Bool) -> some View {
        if selected {
            Label(text, image: "hi-tick")
        } else {
            Text(text)
        }
    }
}

/// Submenú "Mover a…" para pasar un guion a otra sesión.
struct MoveToSessionMenu: View {
    @ObservedObject var store: ScriptStore
    let script: Script
    var onMoved: () -> Void = {}

    var body: some View {
        Menu("Move to session", image: .hiFolder) {
            ForEach(store.sessions) { session in
                Button {
                    move(to: session.id)
                } label: {
                    if script.sessionID == session.id {
                        Label(session.name, image: "hi-tick")
                    } else {
                        Text(session.name)
                    }
                }
            }
            if script.sessionID != nil {
                Divider()
                Button("Remove from session") { move(to: nil) }
            }
        }
        .disabled(store.sessions.isEmpty)
    }

    private func move(to sessionID: Session.ID?) {
        store.move(scriptID: script.id, to: sessionID)
        onMoved()
    }
}

/// Fila horizontal de sesiones, estilo "chips" (iPhone/iPad).
struct SessionChipsBar: View {
    @ObservedObject var store: ScriptStore
    var onSelect: (Session.ID?) -> Void = { _ in }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(String(localized: "All"), count: store.scripts.count, selected: store.currentSessionID == nil) {
                    choose(nil)
                }
                ForEach(store.sessions) { session in
                    chip(session.name, count: store.scriptCount(in: session.id),
                         selected: store.currentSessionID == session.id) {
                        choose(session.id)
                    }
                }
            }
            .padding(.horizontal, 22)
        }
        .scrollClipDisabled()
    }

    private func choose(_ id: Session.ID?) {
        store.selectSession(id)
        onSelect(id)
    }

    private func chip(_ title: String, count: Int, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title).lineLimit(1)
                Text("\(count)").foregroundStyle(selected ? Color.white.opacity(0.7) : Theme.tertiaryText)
            }
            .textStyle(.footnote, weight: .semibold)
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Pill().fill(selected ? Theme.accent : Theme.surface))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
