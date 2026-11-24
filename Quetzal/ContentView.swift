import SwiftUI

struct ContentView: View {
    @State private var session = ChatSession()
    @State private var worktreeStart = WorktreeSessionStart()
    @State private var sidebar = WorktreeSidebarModel()

    var body: some View {
        NavigationSplitView {
            WorktreeSidebar(model: sidebar, selectedItem: worktreeStart.selectedItem,
                            canOpenRepository: session.phase == .setup,
                            onSelect: { worktreeStart.request($0, sessionActive: session.phase != .setup) },
                            onRepositoryOpened: worktreeStart.repositoryOpened)
                .navigationSplitViewColumnWidth(min: 200, ideal: 260)
        } detail: {
            Group {
                switch session.phase {
                case .setup:
                    StartView(state: worktreeStart, start: session.start)
                case .connecting:
                    VStack(spacing: 12) {
                        ProgressView("Starting \(session.provider.rawValue)…")
                        Button("Cancel") { Task { await session.close() } }
                    }
                default:
                    ChatView(session: session)
                }
            }
            .frame(minWidth: 520, minHeight: 380)
        }
        .onDisappear {
            sidebar.cancel()
            Task { await session.close() }
        }
    }
}

struct StartView: View {
    let state: WorktreeSessionStart
    let start: (URL, ModelSettings, URL, Provider) async -> Void
    @State private var provider = Provider.codex
    @State private var codexDraft = SessionSettingsDraft()
    @State private var claudeDraft = SessionSettingsDraft()

    var body: some View {
        Form {
            worktree
            Picker("Provider", selection: $provider) {
                ForEach(Provider.allCases) { Text($0.rawValue).tag($0) }
            }
            .disabled(state.isStarting)
            if let error = state.error { Text(error).foregroundStyle(.red) }
            SessionOptions(provider: provider, canStart: state.canStart,
                           draft: provider == .codex ? $codexDraft : $claudeDraft, start: startSession)
                .id(provider)
        }
        .formStyle(.grouped)
        .onDisappear(perform: state.invalidate)
    }

    @ViewBuilder
    private var worktree: some View {
        switch state.target {
        case nil:
            Text("Select a worktree in the sidebar.").foregroundStyle(.secondary)
        case .existing(let selection):
            LabeledContent("Worktree") {
                Text(verbatim: selection.worktree.directory.path).textSelection(.enabled)
            }
        }
    }

    private func startSession(_ settings: ModelSettings) {
        guard let id = state.begin() else { return }
        let provider = self.provider
        var executable = provider == .codex ? CodexClient.findExecutable() : ClaudeCodeClient.findExecutable()
        if executable == nil {
            let panel = NSOpenPanel()
            panel.message = "Choose the \(provider.rawValue) CLI executable to start this session."
            panel.prompt = "Use \(provider.rawValue)"
            panel.canChooseDirectories = false
            guard panel.runModal() == .OK, let chosen = panel.url else {
                state.finish(id)
                return
            }
            guard ChildProcess.isExecutable(chosen) else {
                state.finish(id, error: "Choose a file with execute permission.")
                return
            }
            executable = chosen
        }
        guard let executable else {
            state.finish(id)
            return
        }
        state.validateAndStart(id, validate: { selected in
            try await GitWorktreeCatalog().validate(selected.worktree, in: selected.repository)
        }, launch: { directory in
            await start(directory, settings, executable, provider)
        })
    }
}

private struct SessionOptions: View {
    let provider: Provider
    let canStart: Bool
    @Binding var draft: SessionSettingsDraft
    let start: (ModelSettings) -> Void
    @AppStorage private var defaultModel: String
    @AppStorage private var defaultEffort: String

    init(provider: Provider, canStart: Bool, draft: Binding<SessionSettingsDraft>, start: @escaping (ModelSettings) -> Void) {
        self.provider = provider
        self.canStart = canStart
        _draft = draft
        self.start = start
        _defaultModel = AppStorage(wrappedValue: "", provider.key("model"))
        _defaultEffort = AppStorage(wrappedValue: "", provider.key("effort"))
    }

    var body: some View {
        let model = Binding(get: { draft.model ?? defaultModel }, set: { draft.model = $0 })
        let effort = Binding(get: { draft.effort ?? defaultEffort }, set: { draft.effort = $0 })
        TextField("Model", text: model, prompt: Text("CLI default"))
        TextField("Effort", text: effort, prompt: Text("CLI default"))
        Button("Start Session") {
            start(draft.settings(defaultModel: defaultModel, defaultEffort: defaultEffort))
        }
        .disabled(!canStart)
        .keyboardShortcut(.defaultAction)
    }
}
