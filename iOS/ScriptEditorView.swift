import SwiftUI

enum PrompterMode: String, Identifiable {
    case camera, floating, reader
    var id: String { rawValue }
}

struct ScriptEditorView: View {
    let scriptID: Script.ID

    @EnvironmentObject private var store: ScriptStore
    @EnvironmentObject private var settings: PrompterSettings
    @State private var draft = Script(title: "", body: "")
    @State private var loaded = false
    @State private var mode: PrompterMode?
    @FocusState private var editing: Bool

    private var isEmpty: Bool {
        draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            editor
            // Queda fija abajo; el teclado la tapa al escribir.
            launchBar
                .ignoresSafeArea(.keyboard, edges: .bottom)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // En la barra superior: la barra del teclado de SwiftUI provocaba un ciclo de diseño.
            ToolbarItem(placement: .topBarTrailing) {
                if editing {
                    Button("Done") { editing = false }
                        .textStyle(.headline)
                }
            }
        }
        .onAppear(perform: load)
        .onChange(of: draft) { _, newValue in
            if loaded { store.update(newValue) }
        }
        .onDisappear {
            if draft.title.isEmpty && isEmpty { store.delete(id: draft.id) }
        }
        .fullScreenCover(item: $mode) { mode in
            switch mode {
            case .camera: CameraRecordView(text: draft.body, settings: settings)
            case .floating: FloatingPrompterView(text: draft.body, settings: settings)
            case .reader: ReaderView(text: draft.body, settings: settings)
            }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Title", text: $draft.title)
                .textStyle(.title)
                .foregroundStyle(.white)
                .padding(.horizontal, 22)
                .padding(.top, 6)
                .focused($editing)

            HStack(spacing: 8) {
                Chip(systemImage: "text.word.spacing", text: String(localized: "\(draft.wordCount) words"))
                Chip(systemImage: "clock", text: "≈ \(TimeFormat.estimate(words: draft.wordCount, wpm: settings.wordsPerMinute)) min")
            }
            .padding(.horizontal, 22)
            .padding(.top, 10)
            .padding(.bottom, 6)

            TextEditor(text: $draft.body)
                .font(.text(19))
                .lineSpacing(5)
                .foregroundStyle(.white.opacity(0.92))
                .scrollContentBackground(.hidden)
                .contentMargins(.bottom, 140, for: .scrollContent)
                .scrollDismissesKeyboard(.interactively)
                .padding(.horizontal, 17)
                .focused($editing)
                .overlay(alignment: .topLeading) {
                    if draft.body.isEmpty {
                        Text("Write or paste your script here…")
                            .roundedText(size: 19)
                            .foregroundStyle(Theme.tertiaryText)
                            .padding(.horizontal, 22)
                            .padding(.top, 8)
                            .allowsHitTesting(false)
                    }
                }
        }
    }

    private var launchBar: some View {
        HStack(spacing: 10) {
            LaunchTile(title: "Record", subtitle: "with Cue", systemImage: "record.circle", prominent: true) {
                mode = .camera
            }
            .accessibilityIdentifier("launch-camera")
            LaunchTile(title: "Floating", subtitle: "over another app", systemImage: "pip.enter") {
                mode = .floating
            }
            .accessibilityIdentifier("launch-floating")
            LaunchTile(title: "Read", subtitle: "full screen", systemImage: "text.viewfinder") {
                mode = .reader
            }
            .accessibilityIdentifier("launch-reader")
        }
        .disabled(isEmpty)
        .opacity(isEmpty ? 0.4 : 1)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 30, style: .continuous).fill(Color(white: 0.09)))
        .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
        .padding(.horizontal, 14)
        .padding(.bottom, 4)
    }

    private func load() {
        guard !loaded, let script = store.script(id: scriptID) else { return }
        draft = script
        loaded = true
        if isEmpty && script.title.isEmpty { editing = true }
    }
}

private struct LaunchTile: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let systemImage: String
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 24, weight: .semibold, design: .default))
                    .symbolRenderingMode(.hierarchical)
                Text(title)
                    .textStyle(.callout, weight: .bold)
                Text(subtitle)
                    .textStyle(.caption, weight: .medium)
                    .opacity(0.7)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .foregroundStyle(.white)
            .background {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(prominent ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.surfaceStrong))
            }
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(prominent ? 0.22 : 0.08), lineWidth: 1))
        }
        .buttonStyle(PressableStyle())
    }
}
