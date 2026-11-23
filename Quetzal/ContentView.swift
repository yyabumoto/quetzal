import SwiftUI

struct ContentView: View {
    @State private var session = ChatSession()
    @State private var executableError: String?

    var body: some View {
        Group {
            switch session.phase {
            case .setup:
                VStack {
                    StartView(start: start)
                    if let executableError {
                        Text(executableError).foregroundStyle(.red).padding(.horizontal)
                    }
                }
            case .connecting:
                VStack(spacing: 12) {
                    ProgressView("Starting Codex…")
                    Button("Cancel") { Task { await session.close() } }
                }
            default:
                ChatView(session: session)
            }
        }
        .frame(minWidth: 520, minHeight: 380)
        .onDisappear { Task { await session.close() } }
    }

    private func start(_ worktree: URL, _ settings: ModelSettings) {
        executableError = nil
        var executable = CodexClient.findExecutable()
        if executable == nil {
            let panel = NSOpenPanel()
            panel.message = "Choose the Codex CLI executable to start this session."
            panel.prompt = "Use Codex"
            panel.canChooseDirectories = false
            guard panel.runModal() == .OK, let chosen = panel.url else { return }
            guard CodexClient.isExecutable(chosen) else {
                executableError = "Choose a file with execute permission."
                return
            }
            executable = chosen
        }
        if let executable {
            Task { await session.start(worktree: worktree, settings: settings, executable: executable) }
        }
    }
}

struct StartView: View {
    let start: (URL, ModelSettings) -> Void
    @State private var provider = Provider.codex
    @State private var root: URL?
    @State private var error: String?
    @State private var model = ModelSettings.defaults(for: .codex).model ?? ""
    @State private var effort = ModelSettings.defaults(for: .codex).effort ?? ""

    var body: some View {
        Form {
            Picker("Provider", selection: $provider) {
                ForEach(Provider.allCases) { Text($0.rawValue).tag($0) }
            }
            .onChange(of: provider) {
                let settings = ModelSettings.defaults(for: provider)
                model = settings.model ?? ""
                effort = settings.effort ?? ""
            }
            LabeledContent("Worktree") {
                if let root { Text(root.path).textSelection(.enabled) }
                Button("Choose Folder…", action: chooseFolder)
            }
            TextField("Model", text: $model, prompt: Text("CLI default"))
            TextField("Effort", text: $effort, prompt: Text("CLI default"))
            if let error { Text(error).foregroundStyle(.red) }
            if provider == .claudeCode { Text("Claude Code sessions are unavailable.") }
            Button("Start Session") {
                if let root { start(root, ModelSettings(model: model, effort: effort)) }
            }
            .disabled(root == nil || provider != .codex)
            .keyboardShortcut(.defaultAction)
        }
        .formStyle(.grouped)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        do {
            root = try Worktree.root(at: folder)
            error = nil
        } catch {
            root = nil
            self.error = error.localizedDescription
        }
    }
}
