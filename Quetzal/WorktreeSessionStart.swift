import Foundation
import Observation

nonisolated struct WorktreeSelection: Identifiable, Sendable {
    let id = UUID()
    let worktree: GitWorktree
    let repository: RepositoryWorktrees
}

nonisolated enum WorkTarget: Sendable {
    case existing(WorktreeSelection)
    case newWorktree(RepositoryWorktrees)

    var item: WorktreeListItem {
        switch self {
        case .existing(let selection): .worktree(selection.worktree.id)
        case .newWorktree: .newWorktree
        }
    }

    var repository: RepositoryWorktrees {
        switch self {
        case .existing(let selection): selection.repository
        case .newWorktree(let repository): repository
        }
    }

    fileprivate var selection: WorktreeSelection? {
        switch self {
        case .existing(let selection): selection
        case .newWorktree: nil
        }
    }

    // WorktreeSelection.id は選ぶたびに変わるので、項目とリポジトリで比べる。
    fileprivate func isSame(as other: WorkTarget) -> Bool {
        item == other.item && repository.identity == other.repository.identity
    }
}

nonisolated extension RepositoryWorktrees {
    func target(for item: WorktreeListItem) -> WorkTarget? {
        switch item {
        case .worktree(let id):
            entries.first { $0.id == id && !$0.isPrunable }
                .map { .existing(WorktreeSelection(worktree: $0, repository: self)) }
        case .newWorktree:
            .newWorktree(self)
        }
    }
}

@MainActor @Observable
final class WorktreeSessionStart {
    private struct Attempt {
        let id = UUID()
        let selection: WorktreeSelection
    }

    private(set) var target: WorkTarget?
    private(set) var pendingTarget: WorkTarget?
    private(set) var error: String?
    private var attempt: Attempt?
    @ObservationIgnored private var task: Task<Void, Never>?

    var isStarting: Bool { attempt != nil }
    var selectedItem: WorktreeListItem? { (pendingTarget ?? target)?.item }
    var canStart: Bool { target?.selection != nil && !isStarting }

    func request(_ next: WorkTarget, sessionActive: Bool) {
        if let target, target.isSame(as: next) { return }
        if sessionActive {
            pendingTarget = next
        } else {
            select(next)
        }
    }

    // アラートのボタンの処理と isPresented の setter（cancelSwitch）はどちらが先に
    // 走るか決まっていないので、pendingTarget を読まずに渡された作業先へ切り替える。
    func confirmSwitch(to next: WorkTarget) {
        pendingTarget = nil
        select(next)
    }

    func cancelSwitch() {
        pendingTarget = nil
    }

    func begin() -> UUID? {
        guard attempt == nil, let selection = target?.selection else { return nil }
        let next = Attempt(selection: selection)
        attempt = next
        error = nil
        return next.id
    }

    func finish(_ id: UUID, error: String? = nil) {
        guard isCurrent(id) else { return }
        invalidate()
        self.error = error
    }

    func repositoryOpened() {
        invalidate()
        target = nil
        pendingTarget = nil
        error = nil
    }

    func invalidate() {
        task?.cancel()
        task = nil
        attempt = nil
    }

    @discardableResult
    func validateAndStart(
        _ id: UUID,
        validate: @escaping (WorktreeSelection) async throws -> URL,
        launch: @escaping (URL) async -> Void
    ) -> Task<Void, Never>? {
        guard isCurrent(id), let selection = attempt?.selection, task == nil else { return nil }
        let verification = Task {
            do {
                let directory = try await validate(selection)
                guard !Task.isCancelled, isCurrent(id) else { return }
                task = nil
                attempt = nil
                await launch(directory)
            } catch {
                guard !Task.isCancelled, isCurrent(id) else { return }
                task = nil
                attempt = nil
                target = nil
                self.error = error.localizedDescription
            }
        }
        task = verification
        return verification
    }

    private func select(_ next: WorkTarget) {
        if let target, target.isSame(as: next) { return }
        invalidate()
        target = next
        error = nil
    }

    private func isCurrent(_ id: UUID) -> Bool {
        guard let attempt else { return false }
        return attempt.id == id && attempt.selection.id == target?.selection?.id
    }
}
