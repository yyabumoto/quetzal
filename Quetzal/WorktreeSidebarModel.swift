import Foundation
import Observation

@MainActor @Observable
final class WorktreeSidebarModel {
    enum Contents {
        case empty
        case loading
        case loaded(RepositoryWorktrees)
        case failed(String)
    }

    private(set) var openedFolder: URL?
    private(set) var contents: Contents = .empty
    @ObservationIgnored private let list: @Sendable (URL) async throws -> RepositoryWorktrees
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation: UUID?

    init(list: @escaping @Sendable (URL) async throws -> RepositoryWorktrees = { try await GitWorktreeCatalog().list(in: $0) }) {
        self.list = list
    }

    @discardableResult
    func open(_ folder: URL) -> Task<Void, Never> {
        task?.cancel()
        let current = UUID()
        generation = current
        openedFolder = folder
        contents = .loading
        let list = self.list
        let loading = Task {
            let result: Contents
            do {
                result = .loaded(try await list(folder))
            } catch {
                result = .failed(error.localizedDescription)
            }
            // 取り消しに応じずに値を返した読み込みも、世代で見分けて捨てる。
            guard !Task.isCancelled, generation == current else { return }
            contents = result
            task = nil
        }
        task = loading
        return loading
    }

    func cancel() {
        task?.cancel()
        task = nil
        generation = nil
    }
}
