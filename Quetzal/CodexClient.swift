import Foundation

actor CodexClient {
    nonisolated let events: AsyncThrowingStream<CodexEvent, Error>
    private let stream: AsyncThrowingStream<CodexEvent, Error>.Continuation
    private let executable: URL
    private let environment: [String: String]
    private let writer = DispatchQueue(label: "Quetzal.Codex.stdin")
    private var input: FileHandle?
    private var process: (child: Process, exit: AsyncStream<Void>)?
    private var reader: Task<Void, Never>?
    private var shutdown: Task<Void, Never>?
    private var finished = false
    private var nextID: Int64 = 0
    private var pending: [RequestID: CheckedContinuation<JSON, Error>] = [:]
    private var approvals: [RequestID: ApprovalRequest] = [:]
    private var fileChanges: [ItemKey: [FileChange]] = [:]
    private var turns: [String: String] = [:]
    private var terminalTurns: Set<String> = []

    init(executable: URL, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.executable = executable
        self.environment = environment
        (events, stream) = AsyncThrowingStream.makeStream()
    }

    nonisolated static func findExecutable() -> URL? {
        let manager = FileManager.default
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let dirs = path.split(separator: ":").map(String.init) + [
            manager.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path,
            "/opt/homebrew/bin", "/usr/local/bin"
        ]
        return dirs.lazy.filter { $0.hasPrefix("/") }.map {
            URL(fileURLWithPath: $0).appendingPathComponent("codex")
        }.first(where: { isExecutable($0) })
    }

    nonisolated static func isExecutable(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory)
            && !directory.boolValue && FileManager.default.isExecutableFile(atPath: url.path)
    }

    func start(worktree: URL, settings: ModelSettings) async throws -> String {
        guard process == nil, !finished else { throw CodexFailure.disconnected }
        let timeout = Task {
            try await Task.sleep(for: .seconds(20))
            finish(CodexFailure("Codex did not finish starting. Check the executable and try again."))
        }
        defer { timeout.cancel() }
        do {
            try launch(at: worktree)
            _ = try await request("initialize", ["clientInfo": .object([
                "name": .string("quetzal"), "version": .string("1.0")
            ])])
            try await write(.object(["method": .string("initialized")]))
            var params = ["cwd": JSON.string(worktree.path)]
            params["model"] = settings.model.map(JSON.string)
            let result = try await request("thread/start", params)
            guard let path = result["cwd"].text, let thread = result["thread"]["id"].text,
                  URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
                    == worktree.resolvingSymlinksInPath().standardizedFileURL.path else {
                throw CodexFailure("Codex did not open the selected worktree.")
            }
            return thread
        } catch {
            finish(error)
            throw error
        }
    }

    private func launch(at folder: URL) throws {
        let child = Process()
        child.executableURL = executable
        child.arguments = ["app-server", "--stdio"]
        child.currentDirectoryURL = folder
        var env = environment
        env["PATH"] = ([executable.deletingLastPathComponent().path] + (env["PATH"] ?? "").split(separator: ":").map(String.init)).joined(separator: ":")
        child.environment = env
        let stdin = Pipe(), stdout = Pipe()
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = FileHandle.nullDevice
        let handle = stdin.fileHandleForWriting
        guard fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else { throw CodexFailure("Cannot open Codex input.") }
        let (exit, termination) = AsyncStream<Void>.makeStream()
        child.terminationHandler = { _ in termination.finish() }
        try child.run()
        process = (child, exit)
        input = handle
        let output = stdout.fileHandleForReading
        let readQueue = DispatchQueue(label: "Quetzal.Codex.stdout", qos: .userInitiated)
        reader = Task.detached { [weak self] in
            defer { try? output.close() }
            var buffer = Data()
            while !Task.isCancelled, let chunk = await Self.readChunk(output, child: child, queue: readQueue) {
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 10) {
                    let line = Data(buffer[..<newline])
                    buffer.removeSubrange(...newline)
                    guard let self, await self.receive(line) else { return }
                }
            }
            await self?.finish(buffer.isEmpty ? CodexFailure.disconnected : CodexFailure.malformed)
        }
    }

    private nonisolated static func readChunk(_ output: FileHandle, child: Process, queue: DispatchQueue) async -> Data? {
        await withCheckedContinuation { continuation in
            queue.async {
                var descriptor = pollfd(fd: output.fileDescriptor, events: Int16(POLLIN), revents: 0)
                let ready = poll(&descriptor, 1, 200)
                if ready == 0 {
                    // 子孫が stdout を継承していても、直接の子が終了したら読み取りを終える。
                    return continuation.resume(returning: child.isRunning ? Data() : nil)
                }
                if ready < 0 { return continuation.resume(returning: errno == EINTR ? Data() : nil) }
                var bytes = [UInt8](repeating: 0, count: 16384)
                let count = Darwin.read(output.fileDescriptor, &bytes, bytes.count)
                if count < 0 && errno == EINTR { return continuation.resume(returning: Data()) }
                continuation.resume(returning: count > 0 ? Data(bytes.prefix(count)) : nil)
            }
        }
    }

    func startTurn(threadID: String, text: String, effort: String?) async throws -> String {
        var params: [String: JSON] = ["threadId": .string(threadID), "input": .array([
            .object(["type": .string("text"), "text": .string(text)])
        ])]
        params["effort"] = effort.map(JSON.string)
        let result = try await request("turn/start", params)
        guard let turn = result["turn"]["id"].text else {
            finish(CodexFailure.malformed)
            throw CodexFailure.malformed
        }
        if !terminalTurns.contains(turn) { turns[threadID] = turn }
        return turn
    }

    func interrupt(threadID: String, turnID: String) async throws {
        _ = try await request("turn/interrupt", ["threadId": .string(threadID), "turnId": .string(turnID)])
    }

    func answer(_ request: ApprovalRequest, allow: Bool) async throws {
        guard let current = approvals[request.id], current.key == request.key else { throw CodexFailure("The request has ended.") }
        guard !allow || current == request else { throw CodexFailure("Approval details changed. Review the updated request.") }
        let result = try current.result(allow: allow)
        approvals.removeValue(forKey: current.id)
        try await write(.object(["id": current.id.json, "result": result]))
    }

    private func request(_ method: String, _ params: [String: JSON]) async throws -> JSON {
        guard !finished else { throw CodexFailure.disconnected }
        nextID += 1
        let id = RequestID.integer(nextID)
        let message: JSON = .object(["id": id.json, "method": .string(method), "params": .object(params)])
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            enqueue(message) { _ in }
        }
    }

    private func write(_ message: JSON) async throws {
        try await withCheckedThrowingContinuation { continuation in
            enqueue(message) { continuation.resume(with: $0) }
        }
    }

    private func enqueue(_ message: JSON, completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        guard let input, !finished else {
            completion(.failure(CodexFailure.disconnected))
            return
        }
        writer.async {
            do {
                var data = try JSONEncoder().encode(message)
                data.append(10)
                try input.write(contentsOf: data)
                completion(.success(()))
            } catch {
                Task { await self.finish(CodexFailure.disconnected) }
                completion(.failure(CodexFailure.disconnected))
            }
        }
    }

    private func receive(_ data: Data) async -> Bool {
        guard !finished else { return false }
        do {
            let message = try JSONDecoder().decode(JSON.self, from: data)
            let id = RequestID(message["id"])
            if let method = message["method"].text {
                if message.fields?["id"] != nil {
                    guard let id else { throw CodexFailure.malformed }
                    try await serverRequest(method, id: id, params: message["params"])
                } else if let event = try CodexEvent.notification(method, message["params"]) {
                    publish(event)
                }
            } else {
                guard let id, let response = pending[id] else { throw CodexFailure.malformed }
                if let error = message["error"]["message"].text {
                    pending.removeValue(forKey: id)
                    response.resume(throwing: CodexFailure(error))
                } else if let result = message.fields?["result"] {
                    pending.removeValue(forKey: id)
                    response.resume(returning: result)
                } else { throw CodexFailure.malformed }
            }
            return true
        } catch {
            finish(CodexFailure.malformed)
            return false
        }
    }

    private func serverRequest(_ method: String, id: RequestID, params: JSON) async throws {
        guard let kind = ApprovalRequest.Kind(rawValue: method) else {
            if method == "mcpServer/elicitation/request" {
                try await write(.object(["id": id.json, "result": .object(["action": .string("cancel")])]))
            } else {
                try await write(.object(["id": id.json, "error": .object([
                    "code": .integer(-32601), "message": .string("Method not found")
                ])]))
            }
            return
        }
        guard let thread = params["threadId"].text ?? params["conversationId"].text,
              let item = params["itemId"].text ?? params["callId"].text else { throw CodexFailure.malformed }
        let key = ItemKey(thread: thread, turn: params["turnId"].text ?? turns[thread] ?? "", item: item)
        guard !terminalTurns.contains(key.turn) else { return }
        var approval = ApprovalRequest(id: id, kind: kind, key: key, params: params)
        if kind == .legacyFile, let files = params["fileChanges"].fields {
            let changes = files.keys.sorted().compactMap { FileChange(path: $0, kind: files[$0] ?? .null) }
            approval.changes = changes.count == files.count ? changes : []
        } else { approval.changes = fileChanges[key] ?? [] }
        approvals[id] = approval
        stream.yield(.approval(approval))
    }

    private func publish(_ event: CodexEvent) {
        switch event {
        case let .started(thread, turn):
            if !terminalTurns.contains(turn) { turns[thread] = turn }
        case let .completed(thread, turn, _, _):
            terminalTurns.insert(turn)
            if turns[thread] == turn { turns.removeValue(forKey: thread) }
            approvals = approvals.filter { $0.value.key.thread != thread || $0.value.key.turn != turn && $0.value.key.turn != "" }
            fileChanges = fileChanges.filter { $0.key.thread != thread || $0.key.turn != turn }
        case let .resolved(thread, id):
            if approvals[id]?.key.thread == thread { approvals.removeValue(forKey: id) }
        case let .changes(key, changes):
            guard !terminalTurns.contains(key.turn) else { return }
            fileChanges[key] = changes
            for id in approvals.keys where approvals[id]?.key == key && approvals[id]?.kind == .file {
                approvals[id]?.changes = changes
                if let updated = approvals[id] { stream.yield(.approval(updated)) }
            }
        default: break
        }
        stream.yield(event)
    }

    private func finish(_ error: Error?) {
        guard !finished else { return }
        finished = true
        reader?.cancel()
        reader = nil
        let reason = error ?? CodexFailure.disconnected
        for waiter in pending.values { waiter.resume(throwing: reason) }
        pending.removeAll()
        approvals.removeAll()
        fileChanges.removeAll()
        if let error { stream.finish(throwing: error) } else { stream.finish() }
        if let input {
            writer.async { try? input.close() }
            self.input = nil
        }
        guard let (child, exit) = process else { return }
        process = nil
        shutdown = Task.detached {
            if child.isRunning { child.terminate() }
            let escalation = Task {
                try await Task.sleep(for: .milliseconds(500))
                if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            }
            for await _ in exit {}
            escalation.cancel()
        }
    }

    func close() async {
        finish(nil)
        await shutdown?.value
    }
}
