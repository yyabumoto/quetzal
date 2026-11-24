import Foundation

nonisolated struct GitRepositoryIdentity: Equatable, Sendable {
    let commonDirectory: URL
    let device: UInt64
    let inode: UInt64
}

nonisolated struct RepositoryWorktrees: Sendable {
    let openedFolder: URL
    let identity: GitRepositoryIdentity
    let entries: [GitWorktree]
    let mainLocation: MainWorktreeLocation
}

nonisolated enum MainWorktreeLocation: Equatable, Sendable {
    case bare, confirmed, gitCandidate, unavailable
}

nonisolated struct GitWorktree: Identifiable, Sendable {
    let directory: URL
    let resolvedDirectory: URL
    let isPrunable: Bool
    var id: URL { directory }

    init(directory: URL, isPrunable: Bool) {
        self.directory = directory
        resolvedDirectory = directory.resolvingSymlinksInPath().standardizedFileURL
        self.isPrunable = isPrunable
    }
}

nonisolated struct GitWorktreeCatalog: Sendable {
    func list(in folder: URL) async throws -> RepositoryWorktrees {
        try await runInBackground { try listWorktrees(in: folder) }
    }

    func validate(_ worktree: GitWorktree, in repository: RepositoryWorktrees) async throws -> URL {
        try await runInBackground {
            let directory = worktree.resolvedDirectory
            guard !worktree.isPrunable, canonical(worktree.directory) == directory,
                  (try? gitPath(["--show-toplevel"], in: directory)) == directory else {
                throw CatalogError.worktreeUnavailable
            }
            let current: RepositoryWorktrees
            do {
                current = try listWorktrees(in: directory)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw CatalogError.worktreeUnavailable
            }
            guard current.identity == repository.identity, canonical(worktree.directory) == directory,
                  current.entries.contains(where: { !$0.isPrunable && $0.resolvedDirectory == directory }) else {
                throw CatalogError.worktreeUnavailable
            }
            return directory
        }
    }

    private func runInBackground<Value: Sendable>(
        _ operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        let worker = Task.detached(priority: .userInitiated, operation: operation)
        return try await withTaskCancellationHandler {
            let value = try await worker.value
            try Task.checkCancellation()
            return value
        } onCancel: {
            worker.cancel()
        }
    }

    private func listWorktrees(in folder: URL) throws -> RepositoryWorktrees {
        let identity = try repositoryIdentity(in: folder)
        let records = try Self.parse(try git(["worktree", "list", "--porcelain", "-z"], in: folder))
        let first = records[0]
        var entries = records.dropFirst().map(\.worktree)
        var location = MainWorktreeLocation.bare

        if !first.isBare {
            let main: GitWorktree?
            (main, location) = findMain(first.worktree, in: folder, identity: identity)
            if let main { entries.insert(main, at: 0) }
        }

        try Task.checkCancellation()
        guard (try? repositoryIdentity(in: folder)) == identity else {
            throw CatalogError.repositoryChanged
        }
        return RepositoryWorktrees(openedFolder: folder, identity: identity, entries: entries, mainLocation: location)
    }

    private func findMain(
        _ candidate: GitWorktree, in folder: URL, identity: GitRepositoryIdentity
    ) -> (GitWorktree?, MainWorktreeLocation) {
        if (try? gitPath(["--git-dir"], in: folder)) == identity.commonDirectory,
           let root = try? gitPath(["--show-toplevel"], in: folder) {
            return (GitWorktree(directory: root, isPrunable: false), .confirmed)
        }
        if let configured = try? configuredMain(in: folder, identity: identity),
           isMain(configured, identity: identity) {
            return (GitWorktree(directory: configured, isPrunable: false), .confirmed)
        }
        if !candidate.isPrunable, isMain(candidate.resolvedDirectory, identity: identity) {
            return (candidate, .gitCandidate)
        }
        return (nil, .unavailable)
    }

    private func configuredMain(in folder: URL, identity: GitRepositoryIdentity) throws -> URL? {
        let data = try git([
            "--git-dir=\(identity.commonDirectory.path)", "config", "--includes", "--null", "--show-scope",
            "--get", "core.worktree"
        ], in: folder)
        let fields = data.split(separator: 0, omittingEmptySubsequences: false)
        guard fields.count == 3, fields[2].isEmpty,
              let scope = String(bytes: fields[0], encoding: .utf8),
              scope == "local" || scope == "worktree",
              let path = String(bytes: fields[1], encoding: .utf8), !path.isEmpty else { return nil }
        return canonical(URL(fileURLWithPath: path, isDirectory: true, relativeTo: identity.commonDirectory))
    }

    private func isMain(_ directory: URL, identity: GitRepositoryIdentity) -> Bool {
        (try? gitPath(["--show-toplevel"], in: directory)) == directory
            && (try? gitPath(["--git-dir"], in: directory)) == identity.commonDirectory
            && (try? repositoryIdentity(in: directory)) == identity
    }

    private func repositoryIdentity(in folder: URL) throws -> GitRepositoryIdentity {
        let directory = try gitPath(["--git-common-dir"], in: folder)
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber else {
            throw CatalogError.repositoryChanged
        }
        return GitRepositoryIdentity(commonDirectory: directory, device: device.uint64Value, inode: inode.uint64Value)
    }

    private func gitPath(_ arguments: [String], in folder: URL) throws -> URL {
        let data = try git(["rev-parse", "--path-format=absolute"] + arguments, in: folder)
        guard data.last == 10, let path = String(bytes: data.dropLast(), encoding: .utf8), path.hasPrefix("/") else {
            throw CatalogError.unexpectedOutput
        }
        return canonical(URL(fileURLWithPath: path, isDirectory: true))
    }

    private func canonical(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }

    private func git(_ arguments: [String], in folder: URL) throws -> Data {
        try Task.checkCancellation()
        let manager = FileManager.default
        let temporary = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: temporary) }

        let outputURL = temporary.appendingPathComponent("stdout")
        try Data().write(to: outputURL)
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", folder.path] + arguments
        process.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw CatalogError.gitUnavailable
        }
        process.waitUntilExit()
        try Task.checkCancellation()
        guard process.terminationStatus == 0 else { throw CatalogError.gitFailed }
        return try Data(contentsOf: outputURL)
    }

    struct Record {
        let worktree: GitWorktree
        let isBare: Bool
    }

    static func parse(_ output: Data) throws -> [Record] {
        let fields = output.split(separator: 0, omittingEmptySubsequences: false)
        guard fields.count >= 3, fields[fields.count - 2].isEmpty, fields[fields.count - 1].isEmpty else {
            throw CatalogError.unexpectedOutput
        }
        var records: [Record] = []
        var directory: URL?
        var isBare = false
        var isPrunable = false
        for field in fields.dropLast() {
            if field.isEmpty {
                guard let root = directory else { throw CatalogError.unexpectedOutput }
                records.append(Record(worktree: GitWorktree(directory: root, isPrunable: isPrunable), isBare: isBare))
                directory = nil
                isBare = false
                isPrunable = false
            } else if directory == nil {
                let prefix = "worktree ".utf8
                guard field.starts(with: prefix),
                      let path = String(bytes: field.dropFirst(prefix.count), encoding: .utf8),
                      path.hasPrefix("/") else { throw CatalogError.unexpectedOutput }
                directory = URL(fileURLWithPath: path, isDirectory: true)
            } else {
                let name = field.prefix(while: { $0 != 32 })
                if name.elementsEqual("worktree".utf8) { throw CatalogError.unexpectedOutput }
                if name.elementsEqual("bare".utf8) { isBare = true }
                if name.elementsEqual("prunable".utf8) { isPrunable = true }
            }
        }
        return records
    }

    private enum CatalogError: LocalizedError {
        case gitUnavailable, gitFailed, unexpectedOutput, repositoryChanged, worktreeUnavailable

        var errorDescription: String? {
            switch self {
            case .gitUnavailable:
                "Could not run Git. Check that Command Line Tools are installed."
            case .gitFailed:
                "Could not read this Git repository. Choose an accessible local Git folder."
            case .unexpectedOutput:
                "Git returned an unexpected worktree list."
            case .repositoryChanged:
                "The repository changed while it was open. Open it again to refresh the list."
            case .worktreeUnavailable:
                "This worktree is no longer available. Open the repository and select a worktree again."
            }
        }
    }
}
