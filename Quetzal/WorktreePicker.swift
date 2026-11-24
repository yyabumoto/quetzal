import AppKit
import SwiftUI

nonisolated struct WorktreeSelection: Identifiable, Sendable {
    let id = UUID()
    let worktree: GitWorktree
    let repository: RepositoryWorktrees
}

struct WorktreePicker: View {
    @Binding var selection: WorktreeSelection?
    var isSelectionLocked = false
    var onRepositoryOpened: () -> Void = {}
    @State private var openedFolder: URL?
    @State private var repository: RepositoryWorktrees?
    @State private var error: String?
    @State private var openTask: Task<Void, Never>?

    var body: some View {
        Group {
            LabeledContent("Repository") {
                if let openedFolder {
                    Text(verbatim: openedFolder.path).textSelection(.enabled)
                }
                Button("Open Repository…", action: chooseRepository)
            }

            if openTask != nil {
                ProgressView("Loading worktrees…")
            } else if let error {
                Text(verbatim: error).foregroundStyle(.red)
            } else if let repository {
                worktreeList(repository)
            }
        }
        .onDisappear {
            openTask?.cancel()
            openTask = nil
            selection = nil
        }
    }

    private func worktreeList(_ repository: RepositoryWorktrees) -> some View {
        let selectedRow = Binding<URL?>(
            get: { selection?.worktree.id },
            set: { id in
                guard !isSelectionLocked else { return }
                selection = repository.entries.first { $0.id == id && !$0.isPrunable }
                    .map { WorktreeSelection(worktree: $0, repository: repository) }
            }
        )
        return Section("Worktrees") {
            if !repository.entries.isEmpty {
                List(repository.entries, selection: selectedRow) { worktree in
                    VStack(alignment: .leading) {
                        Text(verbatim: worktree.directory.path)
                        if worktree.isPrunable {
                            Text("Unavailable").font(.caption)
                        }
                    }
                    .foregroundStyle(worktree.isPrunable ? .secondary : .primary)
                    .tag(worktree.id)
                    .selectionDisabled(isSelectionLocked || worktree.isPrunable)
                }
                .listStyle(.bordered)
                .frame(height: 144)
            }
            if !repository.entries.contains(where: { !$0.isPrunable }) {
                Text("This repository has no available worktrees.").foregroundStyle(.secondary)
            }
            switch repository.mainLocation {
            case .gitCandidate:
                Text("The list uses the main path reported by Git. If the main checkout is elsewhere, open that folder directly.")
                    .foregroundStyle(.secondary)
            case .unavailable:
                Text("Git could not locate the main worktree. To select it, open its folder directly.")
                    .foregroundStyle(.secondary)
            case .bare, .confirmed:
                EmptyView()
            }
        }
    }

    private func chooseRepository() {
        let panel = NSOpenPanel()
        panel.prompt = "Open Repository"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK, let folder = panel.url else { return }

        onRepositoryOpened()
        openTask?.cancel()
        openedFolder = folder
        repository = nil
        selection = nil
        error = nil
        openTask = Task {
            do {
                let result = try await GitWorktreeCatalog().list(in: folder)
                guard !Task.isCancelled else { return }
                repository = result
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
            openTask = nil
        }
    }
}
