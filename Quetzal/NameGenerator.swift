import Foundation
import Synchronization

nonisolated struct NameGenerator: Sendable {
    private let environment: [String: String]

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
    }

    /// CLI を 1 回呼び、名前の案を返す。タスクが取り消されたら子プロセスを止めて CancellationError を投げる。
    func propose(_ request: NamingRequest) async throws -> NameProposal {
        try Task.checkCancellation()
        let manager = FileManager.default
        let folder = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: folder) }
        // CLI がファイルを読まないよう、作業フォルダは指示文や出力と別の空のフォルダにする。
        let work = folder.appendingPathComponent("work", isDirectory: true)
        try manager.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let prompt = folder.appendingPathComponent("prompt")
        try Data(request.prompt.utf8).write(to: prompt)
        let schema = folder.appendingPathComponent("schema.json")
        try Data(NameFormat.schema.utf8).write(to: schema)
        let output = folder.appendingPathComponent("last-message.json")
        let environment = NamingCLI.environment(environment, executable: request.executable)

        var disabledServers: [String] = []
        if request.provider == .codex {
            do {
                let list = try await run(request.executable, NamingCLI.codexServerListArguments, input: nil,
                                         folder: folder, work: work, environment: environment)
                if list.status == 0 { disabledServers = NamingCLI.enabledServers(in: list.stdout) }
            } catch is NamingFailure {}
        }
        let arguments = NamingCLI.arguments(for: request, schema: schema, output: output, disabledServers: disabledServers)
        let result = try await run(request.executable, arguments, input: prompt,
                                   folder: folder, work: work, environment: environment)
        guard result.status == 0 else { throw NamingFailure.exit(result.status) }
        return try NamingCLI.proposal(provider: request.provider, stdout: result.stdout,
                                      output: try? Data(contentsOf: output))
    }

    private func run(
        _ executable: URL, _ arguments: [String], input: URL?, folder: URL, work: URL, environment: [String: String]
    ) async throws -> (status: Int32, stdout: Data) {
        let outputURL = folder.appendingPathComponent(UUID().uuidString)
        try Data().write(to: outputURL)
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }
        let stdin = try input.map { try FileHandle(forReadingFrom: $0) }
        defer { try? stdin?.close() }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = work
        process.environment = environment
        process.standardInput = stdin ?? FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let gate = ProcessGate()
        try await withTaskCancellationHandler {
            try gate.launch(process)
            await gate.waitForExit()
        } onCancel: {
            gate.cancel()
        }
        if gate.isCancelled { throw CancellationError() }
        return (process.terminationStatus, try Data(contentsOf: outputURL))
    }
}

/// 子プロセスの起動・取り消し・終了の待ち合わせの順序を決める。
/// 起動の前の取り消しでは起動せず、起動の後の取り消しでは必ず止め、終了を待つ側は子プロセスの回収まで戻らない。
nonisolated private final class ProcessGate: Sendable {
    private struct State {
        var cancelled = false
        var process: Process?
        var exited = false
        var waiter: CheckedContinuation<Void, Never>?
    }

    private let state = Mutex(State())

    var isCancelled: Bool { state.withLock { $0.cancelled } }

    func launch(_ process: Process) throws {
        process.terminationHandler = { [self] _ in
            let waiter = state.withLock { state in
                state.exited = true
                defer { state.waiter = nil }
                return state.waiter
            }
            waiter?.resume()
        }
        try state.withLock { state throws in
            if state.cancelled { throw CancellationError() }
            do {
                try process.run()
            } catch {
                throw NamingFailure.launch
            }
            state.process = process
        }
    }

    func cancel() {
        let pid: pid_t? = state.withLock { state in
            state.cancelled = true
            guard let process = state.process, !state.exited else { return nil }
            kill(process.processIdentifier, SIGTERM)
            return process.processIdentifier
        }
        guard let pid else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [self] in
            state.withLock { state in
                if !state.exited { kill(pid, SIGKILL) }
            }
        }
    }

    /// 取り消されたタスクの中でも、子プロセスが終わるまで戻らない。
    func waitForExit() async {
        await withCheckedContinuation { continuation in
            let exited = state.withLock { state in
                if !state.exited { state.waiter = continuation }
                return state.exited
            }
            if exited { continuation.resume() }
        }
    }
}

nonisolated enum NamingCLI {
    /// 子プロセスに渡す環境変数。environment の PATH の先頭に executable のフォルダを足す（既存のクライアントと同じ）。
    static func environment(_ environment: [String: String], executable: URL) -> [String: String] {
        var env = environment
        env["PATH"] = ([executable.deletingLastPathComponent().path]
            + (env["PATH"] ?? "").split(separator: ":").map(String.init)).joined(separator: ":")
        return env
    }

    /// Codex の名前付けの前に呼ぶ、MCP サーバーの一覧の引数。
    static let codexServerListArguments = ["--disable", "plugins", "--disable", "apps", "mcp", "list", "--json"]

    /// `codex mcp list --json` の出力から、有効な MCP サーバーのうち、名前が `[A-Za-z0-9_-]+` のものを返す。読めなければ空。
    static func enabledServers(in json: Data) -> [String] {
        guard let servers = try? JSONSerialization.jsonObject(with: json) as? [[String: Any]] else { return [] }
        return servers.compactMap { server in
            guard server["enabled"] as? Bool == true, let name = server["name"] as? String, !name.isEmpty,
                  name.unicodeScalars.allSatisfy({ ("A"..."Z").contains($0) || ("a"..."z").contains($0)
                      || ("0"..."9").contains($0) || $0 == "_" || $0 == "-" }) else { return nil }
            return name
        }
    }

    /// schema と output は一時フォルダの中のファイル。output は Codex の -o の書き出し先。
    /// disabledServers は Codex で `-c mcp_servers.<name>.enabled=false` を付けるサーバー。Claude Code では使わない。
    static func arguments(for request: NamingRequest, schema: URL, output: URL, disabledServers: [String]) -> [String] {
        var arguments: [String]
        switch request.provider {
        case .claudeCode:
            arguments = ["-p", "--output-format", "json", "--json-schema", NameFormat.schema,
                         "--tools", "", "--safe-mode", "--strict-mcp-config", "--no-session-persistence",
                         "--permission-prompts", "none"]
            if let model = request.model { arguments += ["--model", model] }
        case .codex:
            arguments = ["exec", "--ephemeral", "--skip-git-repo-check", "--sandbox", "read-only", "--color", "never",
                         "--ignore-rules", "--disable", "hooks", "--disable", "plugins", "--disable", "apps"]
            for server in disabledServers { arguments += ["-c", "mcp_servers.\(server).enabled=false"] }
            arguments += ["--output-schema", schema.path, "-o", output.path,
                          "-c", #"approval_policy="never""#, "-c", "features.shell_tool=false",
                          "-c", "project_doc_max_bytes=0", "-c", #"model_reasoning_effort="low""#]
            if let model = request.model { arguments += ["-m", model] }
            arguments.append("-")
        }
        return arguments
    }

    /// Claude Code は stdout の JSON の structured_output を、Codex は output のファイルを読む。
    static func proposal(provider: Provider, stdout: Data, output: Data?) throws -> NameProposal {
        struct ClaudeResult: Decodable { let structured_output: NameProposal }
        do {
            switch provider {
            case .claudeCode:
                return try JSONDecoder().decode(ClaudeResult.self, from: stdout).structured_output
            case .codex:
                guard let output else { throw NamingFailure.malformed }
                return try JSONDecoder().decode(NameProposal.self, from: output)
            }
        } catch {
            throw NamingFailure.malformed
        }
    }
}

nonisolated enum NamingFailure: Error, Equatable {
    case launch, exit(Int32), malformed, timedOut
}
