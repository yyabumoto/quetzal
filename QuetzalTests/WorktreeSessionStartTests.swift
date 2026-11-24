import XCTest
@testable import Quetzal

@MainActor
final class WorktreeSessionStartTests: XCTestCase {
    func testChangingRepositoriesDiscardsStaleValidationSuccessAndFailure() async throws {
        let first = selection("/temporary/first")
        let second = selection("/temporary/second")
        for outcome in [Result<URL, Error>.success(first.worktree.directory), .failure(CocoaError(.fileNoSuchFile))] {
            let state = WorktreeSessionStart()
            state.selection = first
            let oldID = try XCTUnwrap(state.begin())
            XCTAssertNil(state.begin())
            let firstStarted = expectation(description: "First validation has started")
            var firstContinuation: CheckedContinuation<URL, Error>?
            var started: [URL] = []
            let firstTask = try XCTUnwrap(state.validateAndStart(oldID, validate: { _ in
                try await withCheckedThrowingContinuation {
                    firstContinuation = $0
                    firstStarted.fulfill()
                }
            }, launch: { started.append($0) }))
            await fulfillment(of: [firstStarted], timeout: 2)

            state.repositoryOpened()
            state.selection = second
            let newID = try XCTUnwrap(state.begin())
            let secondStarted = expectation(description: "Second validation has started")
            var secondContinuation: CheckedContinuation<URL, Error>?
            let secondTask = try XCTUnwrap(state.validateAndStart(newID, validate: { _ in
                try await withCheckedThrowingContinuation {
                    secondContinuation = $0
                    secondStarted.fulfill()
                }
            }, launch: { started.append($0) }))
            await fulfillment(of: [secondStarted], timeout: 2)

            let firstValidation = try XCTUnwrap(firstContinuation)
            let secondValidation = try XCTUnwrap(secondContinuation)
            firstValidation.resume(with: outcome)
            await firstTask.value
            XCTAssertTrue(state.isStarting)
            XCTAssertEqual(state.selection?.id, second.id)
            XCTAssertNil(state.error)
            XCTAssertTrue(started.isEmpty)

            secondValidation.resume(returning: second.worktree.directory)
            await secondTask.value
            XCTAssertFalse(state.isStarting)
            XCTAssertEqual(started, [second.worktree.directory])
        }
    }

    private func selection(_ path: String) -> WorktreeSelection {
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        let worktree = GitWorktree(directory: folder, isPrunable: false)
        let identity = GitRepositoryIdentity(commonDirectory: folder.appendingPathComponent(".git"), device: 1, inode: 1)
        let repository = RepositoryWorktrees(openedFolder: folder, identity: identity, entries: [worktree], mainLocation: .confirmed)
        return WorktreeSelection(worktree: worktree, repository: repository)
    }
}
