import XCTest
@testable import Quetzal

@MainActor
final class WorktreeSessionStartTests: XCTestCase {
    func testChangingRepositoriesDiscardsStaleValidationSuccessAndFailure() async throws {
        let first = selection("/temporary/first")
        let second = selection("/temporary/second")
        for outcome in [Result<URL, Error>.success(first.worktree.directory), .failure(CocoaError(.fileNoSuchFile))] {
            let state = WorktreeSessionStart()
            state.request(.existing(first), sessionActive: false)
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
            state.request(.existing(second), sessionActive: false)
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
            XCTAssertEqual(selectionID(state.target), second.id)
            XCTAssertNil(state.error)
            XCTAssertTrue(started.isEmpty)

            secondValidation.resume(returning: second.worktree.directory)
            await secondTask.value
            XCTAssertFalse(state.isStarting)
            XCTAssertEqual(started, [second.worktree.directory])
        }
    }

    func testRequestInSetupSelectsTargetAndClearsError() throws {
        let repository = repository(["/temporary/main", "/temporary/feature"])
        let state = WorktreeSessionStart()
        state.request(try target("/temporary/main", in: repository), sessionActive: false)
        let id = try XCTUnwrap(state.begin())
        state.finish(id, error: "Choose a file with execute permission.")
        XCTAssertNotNil(state.error)

        state.request(try target("/temporary/feature", in: repository), sessionActive: false)
        XCTAssertEqual(state.target?.item, .worktree(URL(fileURLWithPath: "/temporary/feature", isDirectory: true)))
        XCTAssertEqual(state.selectedItem, state.target?.item)
        XCTAssertNil(state.error)
        XCTAssertTrue(state.canStart)
    }

    func testRequestingSameTargetInSetupKeepsAttempt() throws {
        let repository = repository(["/temporary/main"])
        let state = WorktreeSessionStart()
        let original = try target("/temporary/main", in: repository)
        state.request(original, sessionActive: false)
        XCTAssertNotNil(state.begin())

        state.request(try target("/temporary/main", in: repository), sessionActive: false)
        XCTAssertTrue(state.isStarting)
        XCTAssertEqual(selectionID(state.target), selectionID(original))
    }

    func testRequestingAnotherTargetDuringValidationDiscardsIt() async throws {
        let repository = repository(["/temporary/main", "/temporary/feature"])
        for outcome in [Result<URL, Error>.success(URL(fileURLWithPath: "/temporary/main")), .failure(CocoaError(.fileNoSuchFile))] {
            let state = WorktreeSessionStart()
            state.request(try target("/temporary/main", in: repository), sessionActive: false)
            let id = try XCTUnwrap(state.begin())
            let validationStarted = expectation(description: "Validation has started")
            var continuation: CheckedContinuation<URL, Error>?
            var started: [URL] = []
            let task = try XCTUnwrap(state.validateAndStart(id, validate: { _ in
                try await withCheckedThrowingContinuation {
                    continuation = $0
                    validationStarted.fulfill()
                }
            }, launch: { started.append($0) }))
            await fulfillment(of: [validationStarted], timeout: 2)

            let next = try target("/temporary/feature", in: repository)
            state.request(next, sessionActive: false)
            XCTAssertFalse(state.isStarting)

            try XCTUnwrap(continuation).resume(with: outcome)
            await task.value
            XCTAssertFalse(state.isStarting)
            XCTAssertTrue(started.isEmpty)
            XCTAssertNil(state.error)
            XCTAssertEqual(selectionID(state.target), selectionID(next))
        }
    }

    func testFailedValidationClearsTarget() async throws {
        let repository = repository(["/temporary/main"])
        let state = WorktreeSessionStart()
        state.request(try target("/temporary/main", in: repository), sessionActive: false)
        let id = try XCTUnwrap(state.begin())
        let task = try XCTUnwrap(state.validateAndStart(id, validate: { _ in
            throw CocoaError(.fileNoSuchFile)
        }, launch: { _ in XCTFail("A failed validation must not launch a session.") }))
        await task.value

        XCTAssertNil(state.target)
        XCTAssertNil(state.selectedItem)
        XCTAssertNotNil(state.error)
        XCTAssertFalse(state.isStarting)
    }

    func testOpeningRepositoryClearsTargetAttemptAndError() throws {
        let repository = repository(["/temporary/main"])
        let state = WorktreeSessionStart()
        state.request(try target("/temporary/main", in: repository), sessionActive: false)
        let failed = try XCTUnwrap(state.begin())
        state.finish(failed, error: "Choose a file with execute permission.")
        XCTAssertNotNil(state.begin())

        state.repositoryOpened()
        XCTAssertNil(state.target)
        XCTAssertNil(state.error)
        XCTAssertFalse(state.isStarting)
        XCTAssertFalse(state.canStart)

        state.request(try target("/temporary/main", in: repository), sessionActive: false)
        let id = try XCTUnwrap(state.begin())
        state.finish(id, error: "Choose a file with execute permission.")
        state.repositoryOpened()
        XCTAssertNil(state.error)
    }

    func testTargetForListItem() throws {
        let repository = repository(["/temporary/main", "/temporary/gone"], prunable: ["/temporary/gone"])
        let item = WorktreeListItem.worktree(URL(fileURLWithPath: "/temporary/main", isDirectory: true))
        guard case .existing(let selected) = repository.target(for: item) else {
            return XCTFail("An available worktree must become a target.")
        }
        XCTAssertEqual(selected.worktree.id, URL(fileURLWithPath: "/temporary/main", isDirectory: true))
        XCTAssertEqual(selected.repository.identity, repository.identity)

        XCTAssertNil(repository.target(for: .worktree(URL(fileURLWithPath: "/temporary/gone", isDirectory: true))))
        XCTAssertNil(repository.target(for: .worktree(URL(fileURLWithPath: "/temporary/other", isDirectory: true))))
    }

    private func selection(_ path: String) -> WorktreeSelection {
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        let worktree = GitWorktree(directory: folder, isPrunable: false)
        let identity = GitRepositoryIdentity(commonDirectory: folder.appendingPathComponent(".git"), device: 1, inode: 1)
        let repository = RepositoryWorktrees(openedFolder: folder, identity: identity, entries: [worktree], mainLocation: .confirmed)
        return WorktreeSelection(worktree: worktree, repository: repository)
    }

    private func repository(_ paths: [String], prunable: Set<String> = []) -> RepositoryWorktrees {
        let folders = paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
        let identity = GitRepositoryIdentity(commonDirectory: folders[0].appendingPathComponent(".git"), device: 1, inode: 1)
        let entries = zip(paths, folders).map { GitWorktree(directory: $1, isPrunable: prunable.contains($0)) }
        return RepositoryWorktrees(openedFolder: folders[0], identity: identity, entries: entries, mainLocation: .confirmed)
    }

    private func target(_ path: String, in repository: RepositoryWorktrees) throws -> WorkTarget {
        try XCTUnwrap(repository.target(for: .worktree(URL(fileURLWithPath: path, isDirectory: true))))
    }

    private func selectionID(_ target: WorkTarget?) -> UUID? {
        guard case .existing(let selection) = target else { return nil }
        return selection.id
    }
}
