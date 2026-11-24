import Foundation
import XCTest
@testable import Quetzal

final class GitWorktreeCatalogTests: XCTestCase {
    private let catalog = GitWorktreeCatalog()

    func testPorcelainPreservesPathsAndRequiresCompleteRecords() throws {
        let path = "/tmp/作業 space\n"
        let records = try GitWorktreeCatalog.parse(Data("worktree /tmp/bare\0bare\0\0worktree \(path)\0prunable missing\0\0".utf8))
        XCTAssertEqual(records.count, 2)
        XCTAssertTrue(records[0].isBare)
        XCTAssertEqual(records[1].worktree.directory.path, path)
        XCTAssertTrue(records[1].worktree.isPrunable)
        XCTAssertThrowsError(try GitWorktreeCatalog.parse(Data()))
        XCTAssertThrowsError(try GitWorktreeCatalog.parse(Data("worktree /tmp/truncated\0".utf8)))
        XCTAssertThrowsError(try GitWorktreeCatalog.parse(Data("worktree relative\0\0".utf8)))
        XCTAssertThrowsError(try GitWorktreeCatalog.parse(Data("worktree /tmp/".utf8) + Data([255, 0, 0])))
    }

    func testListsLinkedFromSubfolderAndRejectsRemovedWorktree() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let main = root.appendingPathComponent("main", isDirectory: true)
        let linked = root.appendingPathComponent("日本語 linked\n", isDirectory: true)
        try initialize(main, under: root)
        try git(["worktree", "add", "--detach", linked.path], in: main)
        let child = linked.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)

        let repository = try await catalog.list(in: child)
        XCTAssertEqual(repository.entries.map { canonical($0.directory) }, [canonical(main), canonical(linked)])
        XCTAssertEqual(repository.mainLocation, .gitCandidate)
        let row = try XCTUnwrap(repository.entries.last)
        let destination = try await catalog.validate(row, in: repository)
        XCTAssertEqual(destination, canonical(linked))

        try FileManager.default.removeItem(at: linked)
        do {
            _ = try await catalog.validate(row, in: repository)
            XCTFail("A removed worktree must be rejected.")
        } catch {}
        let updated = try await catalog.list(in: main)
        XCTAssertEqual(updated.entries.last?.isPrunable, true)
    }

    func testSelectedWorktreeCannotBeReplacedByLinkToAnotherWorktree() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let main = root.appendingPathComponent("main", isDirectory: true)
        let former = root.appendingPathComponent("former", isDirectory: true)
        let replacement = root.appendingPathComponent("replacement", isDirectory: true)
        try initialize(main, under: root)
        try git(["worktree", "add", "--detach", former.path], in: main)
        try git(["worktree", "add", "--detach", replacement.path], in: main)

        let repository = try await catalog.list(in: main)
        let selected = try XCTUnwrap(repository.entries.first { canonical($0.directory) == canonical(former) })
        try git(["worktree", "remove", former.path], in: main)
        try FileManager.default.createSymbolicLink(at: former, withDestinationURL: replacement)
        XCTAssertEqual(canonical(former), canonical(replacement))

        do {
            _ = try await catalog.validate(selected, in: repository)
            XCTFail("A link to another worktree must not change the selected destination.")
        } catch {}
    }

    func testSeparateGitDirectoryPrefersOpenedRootAndEffectiveSetting() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let admin = root.appendingPathComponent("admin", isDirectory: true)
        let metadata = admin.appendingPathComponent(".git", isDirectory: true)
        let checkout = root.appendingPathComponent("checkout", isDirectory: true)
        let linked = root.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createDirectory(at: admin, withIntermediateDirectories: false)
        try initialize(checkout, under: root, arguments: ["--separate-git-dir", metadata.path])
        try git(["worktree", "add", "--detach", linked.path], in: checkout)

        let direct = try await catalog.list(in: checkout)
        XCTAssertEqual(direct.entries.first?.directory, canonical(checkout))
        XCTAssertEqual(direct.mainLocation, .confirmed)

        let candidate = try await catalog.list(in: linked)
        XCTAssertEqual(candidate.entries.first.map { canonical($0.directory) }, canonical(admin))
        XCTAssertEqual(candidate.mainLocation, .gitCandidate)

        try git(["config", "--local", "core.worktree", ".."], in: checkout)
        try git(["config", "--local", "extensions.worktreeConfig", "true"], in: checkout)
        try git(["--git-dir=\(metadata.path)", "config", "--worktree", "core.worktree", "../../checkout"], in: checkout)
        let configured = try await catalog.list(in: linked)
        XCTAssertEqual(configured.entries.first?.directory, canonical(checkout))
        XCTAssertEqual(configured.mainLocation, .confirmed)
        let row = try XCTUnwrap(configured.entries.first)
        let valid = try await catalog.validate(row, in: configured)
        XCTAssertEqual(valid, canonical(checkout))

        try git(["--git-dir=\(metadata.path)", "config", "--local", "extensions.worktreeConfig", "false"], in: checkout)
        let shared = try await catalog.list(in: linked)
        XCTAssertEqual(shared.entries.first?.directory, canonical(admin))
        XCTAssertEqual(shared.mainLocation, .confirmed)
    }

    func testReplacedRepositoryAtSamePathCannotStart() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let main = root.appendingPathComponent("main", isDirectory: true)
        try initialize(main, under: root)
        let repository = try await catalog.list(in: main)
        let selected = try XCTUnwrap(repository.entries.first)
        try FileManager.default.moveItem(at: main, to: root.appendingPathComponent("old-main"))
        try initialize(main, under: root)

        do {
            _ = try await catalog.validate(selected, in: repository)
            XCTFail("A different repository at the same path must be rejected.")
        } catch {}
    }

    func testBareRepositoryListsOnlyItsLinkedWorktree() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let main = root.appendingPathComponent("main", isDirectory: true)
        let bare = root.appendingPathComponent("bare", isDirectory: true)
        let linked = root.appendingPathComponent("linked", isDirectory: true)
        try initialize(main, under: root)
        try git(["clone", "--quiet", "--bare", main.path, bare.path], in: root)
        let empty = try await catalog.list(in: bare)
        XCTAssertTrue(empty.entries.isEmpty)
        XCTAssertEqual(empty.mainLocation, .bare)
        try git(["worktree", "add", "--detach", linked.path], in: bare)
        let repository = try await catalog.list(in: bare)
        XCTAssertEqual(repository.entries.map { canonical($0.directory) }, [canonical(linked)])
        let selected = try XCTUnwrap(repository.entries.first)
        let destination = try await catalog.validate(selected, in: repository)
        XCTAssertEqual(destination, canonical(linked))
    }

    private func canonical(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        return canonical(folder)
    }

    private func initialize(_ repository: URL, under root: URL, arguments: [String] = []) throws {
        try git(["init", "--quiet"] + arguments + [repository.path], in: root)
        try git([
            "-c", "user.name=Quetzal", "-c", "user.email=quetzal@example.invalid", "-c", "commit.gpgSign=false",
            "commit", "--quiet", "--allow-empty", "-m", "Initial"
        ], in: repository)
    }

    private func git(_ arguments: [String], in folder: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", folder.path] + arguments
        process.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "Git fixture failed: \(arguments)"])
        }
    }
}
