import AppKit
import SwiftUI

nonisolated enum WorktreeListItem: Hashable, Sendable {
    case worktree(URL)
    case newWorktree
}

struct WorktreeSidebar: View {
    let model: WorktreeSidebarModel
    let selectedItem: WorktreeListItem?
    let canOpenRepository: Bool
    let onSelect: (WorkTarget) -> Void
    let onRepositoryOpened: () -> Void

    var body: some View {
        if case .empty = model.contents {
            ContentUnavailableView {
                Label("No Repository", systemImage: "folder")
            } description: {
                Text("Open a Git repository to list its worktrees.")
            } actions: {
                openButton
            }
        } else {
            List(selection: selection) {
                switch model.contents {
                case .empty:
                    EmptyView()
                case .loading:
                    ProgressView("Loading worktrees…")
                case .failed(let message):
                    Section(folderName) {
                        Text(verbatim: message).foregroundStyle(.red)
                    }
                case .loaded(let repository):
                    worktreeSection(repository)
                }
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .bottom) {
                openButton.padding()
            }
        }
    }

    private var folderName: String {
        model.openedFolder?.lastPathComponent ?? ""
    }

    // List が選択を nil にする操作（⌘ クリックなど）は渡さず、作業先を残す。
    private var selection: Binding<WorktreeListItem?> {
        Binding(
            get: { selectedItem },
            set: { item in
                guard let item, case .loaded(let repository) = model.contents,
                      let target = repository.target(for: item) else { return }
                onSelect(target)
            }
        )
    }

    private var openButton: some View {
        Button("Open Repository…", action: chooseRepository)
            .disabled(!canOpenRepository)
            .help(canOpenRepository ? "" : "End the session to open another repository.")
    }

    private func worktreeSection(_ repository: RepositoryWorktrees) -> some View {
        Section(folderName) {
            Label("New Worktree", systemImage: "plus")
                .tag(WorktreeListItem.newWorktree)
            ForEach(repository.entries) { worktree in
                VStack(alignment: .leading) {
                    Text(verbatim: worktree.directory.lastPathComponent)
                    Text(verbatim: worktree.directory.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if worktree.isPrunable {
                        Text("Unavailable").font(.caption)
                    }
                }
                .foregroundStyle(worktree.isPrunable ? .secondary : .primary)
                .help(worktree.directory.path)
                .tag(WorktreeListItem.worktree(worktree.id))
                .selectionDisabled(worktree.isPrunable)
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
        model.open(folder)
    }
}
