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
                    StartView(state: worktreeStart, session: session)
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
        .alert("End the current session?", isPresented: switchAlert, presenting: worktreeStart.pendingTarget) { target in
            Button("End Session", role: .destructive) {
                // 先に作業先を切り替える。close() を先に待つと、その間に古い作業先の開始画面が出る。
                worktreeStart.confirmSwitch(to: target)
                Task { await session.close() }
            }
            Button("Cancel", role: .cancel) { worktreeStart.cancelSwitch() }
        } message: { target in
            Text(switchMessage(target))
        }
        .onDisappear {
            sidebar.cancel()
            Task { await session.close() }
        }
    }

    private func switchMessage(_ target: WorkTarget) -> String {
        switch target {
        case .existing(let selection):
            "Switch to \(selection.worktree.directory.path). The current conversation will close and can't be restored."
        case .newWorktree:
            "Switch to a new worktree. The current conversation will close and can't be restored."
        }
    }

    private var switchAlert: Binding<Bool> {
        Binding(
            get: { worktreeStart.pendingTarget != nil },
            set: { if !$0 { worktreeStart.cancelSwitch() } }
        )
    }
}

struct StartView: View {
    let state: WorktreeSessionStart
    let session: ChatSession
    @State private var provider = Provider.codex
    @State private var codexDraft = SessionSettingsDraft()
    @State private var claudeDraft = SessionSettingsDraft()

    var body: some View {
        VStack(spacing: 0) {
            Form {
                worktree
                if let error = state.error { Text(error).foregroundStyle(.red) }
                Button("Start Session") { startSession() }
                    .disabled(!state.canStart)
                    .keyboardShortcut(.defaultAction)
            }
            .formStyle(.grouped)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                MessageInput(session: session, provider: provider)
                SessionStatusLine(
                    provider: provider, providerSelection: $provider, settings: statusSettings,
                    saved: ModelSettings(model: defaultModel, effort: defaultEffort)
                )
                .id(provider)
                .disabled(state.isStarting)
            }
            .padding()
        }
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
        case .newWorktree:
            LabeledContent("Worktree") { Text("New Worktree") }
            Text("Quetzal can't create worktrees. Select an existing worktree to start a session.")
                .foregroundStyle(.secondary)
        }
    }

    @AppStorage(Provider.codex.key("model")) private var codexModel = ""
    @AppStorage(Provider.codex.key("effort")) private var codexEffort = ""
    @AppStorage(Provider.claudeCode.key("model")) private var claudeModel = ""
    @AppStorage(Provider.claudeCode.key("effort")) private var claudeEffort = ""

    private var draft: SessionSettingsDraft { provider == .codex ? codexDraft : claudeDraft }
    private var defaultModel: String { provider == .codex ? codexModel : claudeModel }
    private var defaultEffort: String { provider == .codex ? codexEffort : claudeEffort }

    private var statusSettings: Binding<ModelSettings> {
        let selectedDraft = provider == .codex ? $codexDraft : $claudeDraft
        return Binding(
            get: { selectedDraft.wrappedValue.settings(defaultModel: defaultModel, defaultEffort: defaultEffort) },
            set: { updated in
                var draft = selectedDraft.wrappedValue
                let current = draft.settings(defaultModel: defaultModel, defaultEffort: defaultEffort)
                if current.model != updated.model { draft.model = updated.model ?? "" }
                if current.effort != updated.effort { draft.effort = updated.effort ?? "" }
                selectedDraft.wrappedValue = draft
            }
        )
    }

    private func startSession() {
        guard let id = state.begin() else { return }
        let provider = self.provider
        let settings = draft.settings(defaultModel: defaultModel, defaultEffort: defaultEffort)
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
            await session.start(worktree: directory, settings: settings, executable: executable, provider: provider)
        })
    }
}
