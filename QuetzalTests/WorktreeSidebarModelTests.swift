import XCTest
@testable import Quetzal

@MainActor
final class WorktreeSidebarModelTests: XCTestCase {
    private final class PendingLists {
        var continuations: [CheckedContinuation<RepositoryWorktrees, Error>] = []
        var started: [XCTestExpectation] = []
    }

    func testOpenLoadsWorktrees() async throws {
        let pending = PendingLists()
        let model = makeModel(pending)
        let folder = URL(fileURLWithPath: "/temporary/repository", isDirectory: true)
        let task = open(model, folder, pending)
        XCTAssertEqual(model.openedFolder, folder)
        XCTAssertTrue(isLoading(model))
        await fulfillment(of: pending.started, timeout: 2)

        pending.continuations[0].resume(returning: repository(folder))
        await task.value
        XCTAssertEqual(loadedFolder(model), folder)
    }

    func testOpenShowsFailure() async throws {
        let pending = PendingLists()
        let model = makeModel(pending)
        let task = open(model, URL(fileURLWithPath: "/temporary/repository", isDirectory: true), pending)
        await fulfillment(of: pending.started, timeout: 2)

        let error = CocoaError(.fileReadNoPermission)
        pending.continuations[0].resume(throwing: error)
        await task.value
        guard case .failed(let message) = model.contents else { return XCTFail("The failure must be shown.") }
        XCTAssertEqual(message, error.localizedDescription)
    }

    func testOpeningAgainDiscardsEarlierResult() async throws {
        let first = URL(fileURLWithPath: "/temporary/first", isDirectory: true)
        let second = URL(fileURLWithPath: "/temporary/second", isDirectory: true)
        for outcome in [Result<RepositoryWorktrees, Error>.success(repository(first)), .failure(CocoaError(.fileNoSuchFile))] {
            let pending = PendingLists()
            let model = makeModel(pending)
            let firstTask = open(model, first, pending)
            let secondTask = open(model, second, pending)
            await fulfillment(of: pending.started, timeout: 2)

            pending.continuations[0].resume(with: outcome)
            await firstTask.value
            XCTAssertTrue(isLoading(model))
            XCTAssertEqual(model.openedFolder, second)

            pending.continuations[1].resume(returning: repository(second))
            await secondTask.value
            XCTAssertEqual(loadedFolder(model), second)
            XCTAssertEqual(model.openedFolder, second)
        }
    }

    func testCancelDiscardsResultThatIgnoresCancellation() async throws {
        let pending = PendingLists()
        let model = makeModel(pending)
        let folder = URL(fileURLWithPath: "/temporary/repository", isDirectory: true)
        let task = open(model, folder, pending)
        await fulfillment(of: pending.started, timeout: 2)

        model.cancel()
        pending.continuations[0].resume(returning: repository(folder))
        await task.value
        XCTAssertTrue(isLoading(model))
    }

    private func makeModel(_ pending: PendingLists) -> WorktreeSidebarModel {
        WorktreeSidebarModel(list: { @MainActor _ in
            try await withCheckedThrowingContinuation { continuation in
                pending.continuations.append(continuation)
                pending.started[pending.continuations.count - 1].fulfill()
            }
        })
    }

    private func open(_ model: WorktreeSidebarModel, _ folder: URL, _ pending: PendingLists) -> Task<Void, Never> {
        pending.started.append(expectation(description: "Listing \(folder.path) has started"))
        return model.open(folder)
    }

    private func isLoading(_ model: WorktreeSidebarModel) -> Bool {
        if case .loading = model.contents { return true }
        return false
    }

    private func loadedFolder(_ model: WorktreeSidebarModel) -> URL? {
        guard case .loaded(let repository) = model.contents else { return nil }
        return repository.openedFolder
    }

    private func repository(_ folder: URL) -> RepositoryWorktrees {
        let identity = GitRepositoryIdentity(commonDirectory: folder.appendingPathComponent(".git"), device: 1, inode: 1)
        return RepositoryWorktrees(openedFolder: folder, identity: identity,
                                   entries: [GitWorktree(directory: folder, isPrunable: false)], mainLocation: .confirmed)
    }
}
