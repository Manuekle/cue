import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var store: ScriptStore
    @EnvironmentObject private var settings: PrompterSettings
    @State private var path: [Script.ID] = []
    @State private var showsSettings = false

    var body: some View {
        NavigationStack(path: $path) {
            List {
                header
                    .listRowInsets(EdgeInsets(top: 4, leading: 22, bottom: 14, trailing: 22))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)

                SessionChipsBar(store: store)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 10, trailing: 0))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)

                ForEach(store.visibleScripts) { script in
                    ScriptCard(script: script, wordsPerMinute: settings.wordsPerMinute)
                        .background(NavigationLink(value: script.id) { EmptyView() }.opacity(0))
                        .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 20))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .contextMenu {
                            MoveToSessionMenu(store: store, script: script)
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                store.delete(id: script.id)
                            }
                        }
                }
                .onDelete(perform: store.delete(atOffsets:))

                if store.visibleScripts.isEmpty {
                    emptyState
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Theme.background.ignoresSafeArea())
            .navigationDestination(for: Script.ID.self) { id in
                ScriptEditorView(scriptID: id)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    SessionMenu(store: store) {
                        Image(systemName: "folder")
                    }
                    .accessibilityLabel("Sessions")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showsSettings = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    path.append(store.create().id)
                } label: {
                    Label("New script", systemImage: "plus")
                }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.horizontal, 22)
                .padding(.bottom, 6)
            }
            .sheet(isPresented: $showsSettings) {
                NavigationStack {
                    PrompterSettingsForm(settings: settings)
                        .scrollContentBackground(.hidden)
                        .background(Theme.background.ignoresSafeArea())
                        .navigationTitle("Settings")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            Button("Done") { showsSettings = false }
                                .textStyle(.headline)
                        }
                }
                .presentationDetents([.medium, .large])
                .presentationBackground(Theme.background)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            LogoMark(size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text("Cue")
                    .textStyle(.display)
                    .foregroundStyle(LinearGradient(colors: [.white, .white.opacity(0.75)], startPoint: .top, endPoint: .bottom))
                Text(subtitle)
                    .textStyle(.callout)
                    .foregroundStyle(Theme.secondaryText)
            }
        }
    }

    private var subtitle: String {
        let count = store.visibleScripts.count
        let scripts = switch count {
        case 0: store.currentSession == nil ? String(localized: "Your teleprompter, ready to record") : String(localized: "No scripts")
        case 1: String(localized: "1 script")
        default: String(localized: "\(count) scripts")
        }
        guard let session = store.currentSession else { return scripts }
        return "\(session.name) · \(scripts)"
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "text.badge.plus")
                .font(.system(size: 40, weight: .semibold, design: .default))
                .foregroundStyle(Theme.accent)
            Text("No scripts")
                .textStyle(.title)
            Text(store.currentSession == nil
                 ? "Create your first script to start recording."
                 : "This session is empty. Create a script or move one here from “All”.")
                .textStyle(.callout)
                .foregroundStyle(Theme.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}

private struct ScriptCard: View {
    let script: Script
    let wordsPerMinute: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(script.displayTitle)
                    .textStyle(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .bold, design: .default))
                    .foregroundStyle(Theme.tertiaryText)
            }
            if !script.preview.isEmpty {
                Text(script.preview)
                    .textStyle(.callout, weight: .regular)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(2)
            }
            HStack(spacing: 8) {
                Chip(systemImage: "text.word.spacing", text: String(localized: "\(script.wordCount) words"))
                Chip(systemImage: "clock", text: "≈ \(TimeFormat.estimate(words: script.wordCount, wpm: wordsPerMinute)) min")
            }
        }
        .padding(18)
        .card()
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}
