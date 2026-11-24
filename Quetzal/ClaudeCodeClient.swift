import Foundation

actor ClaudeCodeClient: AgentClient {
    nonisolated let events: AsyncThrowingStream<AgentEvent, Error>
    private let stream: AsyncThrowingStream<AgentEvent, Error>.Continuation
    private let executable: URL
    private let environment: [String: String]
    private let startupTimeout: Duration
    private let project: ClaudeCodeProject
    private let sessionID = UUID().uuidString.lowercased()
    private let writer = DispatchQueue(label: "Quetzal.ClaudeCode.stdin")
    private var input: FileHandle?
    private var process: (child: Process, exit: AsyncStream<Void>)?
    private var worktree: URL?
    private var reader: Task<Void, Never>?
    private var stderrReader: Task<Void, Never>?
    private var stderrClosed = false
    private var stderrWaiter: CheckedContinuation<Void, Never>?
    private var stderrTimer: Task<Void, Never>?
    private var stderrTail = Data()
    private var shutdown: Task<Void, Never>?
    private var finished = false
    private var nextRequest = 0
    private var nextTurn = 0
    private var pending: [String: CheckedContinuation<JSON, Error>] = [:]
    private var initializeID: String?
    private var runningHooks: Set<String> = []
    private var startupWatchdog: Task<Void, Never>?
    private var currentTurn: String?
    private var interrupted: Set<String> = []
    private var approvals: [RequestID: ApprovalRequest] = [:]
    private var textBlocks = ClaudeTextBlocks()
    private var verifiedInit = false

    init(executable: URL, environment: [String: String] = ProcessInfo.processInfo.environment,
         startupTimeout: Duration = .seconds(20), project: ClaudeCodeProject = ClaudeCodeProject()) {
        self.executable = executable
        self.environment = environment
        self.startupTimeout = startupTimeout
        self.project = project
        (events, stream) = AsyncThrowingStream.makeStream()
    }

    nonisolated static func findExecutable() -> URL? { ChildProcess.find("claude") }

    nonisolated static func isExecutable(_ url: URL) -> Bool { ChildProcess.isExecutable(url) }

    func start(worktree: URL, settings: ModelSettings) async throws -> String {
        guard process == nil, !finished else { throw ClaudeCodeFailure.disconnected }
        do {
            try launch(at: worktree, settings: settings)
            self.worktree = worktree
            let id = nextRequestID()
            initializeID = id
            armStartupWatchdog()
            var request: [String: JSON] = ["subtype": .string("initialize")]
            request["appendSystemPrompt"] = project.instructions.map(JSON.string)
            _ = try await control(id: id, request)
            return sessionID
        } catch {
            finish(error)
            throw error
        }
    }

    private func launch(at folder: URL, settings: ModelSettings) throws {
        let child = Process()
        child.executableURL = executable
        child.arguments = ClaudeCodeArguments.make(settings: settings, sessionID: sessionID, project: project)
        child.currentDirectoryURL = folder
        var env = environment
        env["PATH"] = ([executable.deletingLastPathComponent().path] + (env["PATH"] ?? "").split(separator: ":").map(String.init)).joined(separator: ":")
        child.environment = env
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = stderr
        let handle = stdin.fileHandleForWriting
        guard fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else { throw ClaudeCodeFailure("Cannot open Claude Code input.") }
        let (exit, termination) = AsyncStream<Void>.makeStream()
        child.terminationHandler = { _ in termination.finish() }
        try child.run()
        process = (child, exit)
        input = handle
        let output = stdout.fileHandleForReading
        let readQueue = DispatchQueue(label: "Quetzal.ClaudeCode.stdout", qos: .userInitiated)
        reader = Task.detached { [weak self] in
            defer { try? output.close() }
            var buffer = Data()
            while !Task.isCancelled, let chunk = await ChildProcess.readChunk(output, child: child, queue: readQueue) {
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 10) {
                    let line = Data(buffer[..<newline])
                    buffer.removeSubrange(...newline)
                    guard let self, await self.receive(line) else { return }
                }
            }
            await self?.outputEnded()
        }
        // stderr を読まずにおくと、CLI がパイプの容量を超えて書いたときに止まる。
        let errors = stderr.fileHandleForReading
        let errorQueue = DispatchQueue(label: "Quetzal.ClaudeCode.stderr", qos: .userInitiated)
        stderrReader = Task.detached { [weak self] in
            defer { try? errors.close() }
            while !Task.isCancelled, let chunk = await ChildProcess.readChunk(errors, child: child, queue: errorQueue) {
                if !chunk.isEmpty { await self?.appendStderr(chunk) }
            }
            await self?.stderrEnded()
        }
    }

    func startTurn(threadID: String, text: String, effort: String?) async throws -> String {
        guard !finished else { throw ClaudeCodeFailure.disconnected }
        guard currentTurn == nil else { throw ClaudeCodeFailure("A request is already running.") }
        nextTurn += 1
        let turn = String(nextTurn)
        // 書き込みの完了より前に届いた出力も、この依頼のものとして扱う。
        currentTurn = turn
        do {
            try await write(.object([
                "type": .string("user"), "session_id": .string(""),
                "message": .object(["role": .string("user"), "content": .array([
                    .object(["type": .string("text"), "text": .string(text)])
                ])]),
                "parent_tool_use_id": .null
            ]))
        } catch {
            if currentTurn == turn { currentTurn = nil }
            throw error
        }
        return turn
    }

    func interrupt(threadID: String, turnID: String) async throws {
        guard !finished else { throw ClaudeCodeFailure.disconnected }
        guard currentTurn == turnID else { return }
        // CLI は中断の応答の直後に result を書くので、応答を待つ前に入れる。
        interrupted.insert(turnID)
        do {
            _ = try await control(id: nextRequestID(), ["subtype": .string("interrupt")])
        } catch {
            interrupted.remove(turnID)
            throw error
        }
    }

    func answer(_ request: ApprovalRequest, allow: Bool) async throws {
        guard let current = approvals[request.id], current.key == request.key,
              case .string(let id) = current.id else { throw ClaudeCodeFailure("The request has ended.") }
        guard !allow || current == request else { throw ClaudeCodeFailure("Approval details changed. Review the updated request.") }
        let result = try current.result(allow: allow)
        approvals.removeValue(forKey: current.id)
        try await write(.object(["type": .string("control_response"), "response": .object([
            "subtype": .string("success"), "request_id": .string(id), "response": result
        ])]))
    }

    private func nextRequestID() -> String {
        nextRequest += 1
        return "quetzal-\(nextRequest)"
    }

    private func control(id: String, _ request: [String: JSON]) async throws -> JSON {
        guard !finished else { throw ClaudeCodeFailure.disconnected }
        let message: JSON = .object(["type": .string("control_request"), "request_id": .string(id), "request": .object(request)])
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
            completion(.failure(ClaudeCodeFailure.disconnected))
            return
        }
        writer.async {
            do {
                var data = try JSONEncoder().encode(message)
                data.append(10)
                try input.write(contentsOf: data)
                completion(.success(()))
            } catch {
                Task { await self.finish(ClaudeCodeFailure.disconnected) }
                completion(.failure(ClaudeCodeFailure.disconnected))
            }
        }
    }

    private func armStartupWatchdog() {
        startupWatchdog?.cancel()
        let timeout = startupTimeout
        startupWatchdog = Task {
            do { try await Task.sleep(for: timeout) } catch { return }
            guard !Task.isCancelled else { return }
            finish(ClaudeCodeFailure("Claude Code did not finish starting. Check the executable and try again."))
        }
    }

    private func receive(_ data: Data) async -> Bool {
        guard !finished else { return false }
        guard data.contains(where: { ![9, 10, 13, 32].contains($0) }) else { return true }
        do {
            try await handle(ClaudeCodeMessage(data))
            return true
        } catch {
            finish(error as? ClaudeCodeFailure ?? ClaudeCodeFailure.malformed)
            return false
        }
    }

    private func handle(_ message: ClaudeCodeMessage) async throws {
        switch message {
        case let .response(id, result):
            guard let waiter = pending.removeValue(forKey: id) else { return }
            if id == initializeID {
                initializeID = nil
                startupWatchdog?.cancel()
                startupWatchdog = nil
                runningHooks.removeAll()
            }
            waiter.resume(with: result.mapError { $0 as Error })
        case let .request(id, request):
            guard request["subtype"].text == "can_use_tool" else {
                try await write(.object(["type": .string("control_response"), "response": .object([
                    "subtype": .string("error"), "request_id": .string(id),
                    "error": .string("Unsupported control request subtype: \(request["subtype"].text ?? "")")
                ])]))
                return
            }
            guard let toolUse = request["tool_use_id"].text else { throw ClaudeCodeFailure.malformed }
            let key = ItemKey(thread: sessionID, turn: currentTurn ?? "", item: toolUse)
            let approval = ApprovalRequest(id: .string(id), kind: .tool, key: key, params: request)
            approvals[approval.id] = approval
            stream.yield(.approval(approval))
        case let .cancel(id):
            guard approvals.removeValue(forKey: .string(id)) != nil else { return }
            stream.yield(.resolved(thread: sessionID, id: .string(id)))
        case let .initialized(cwd, session):
            guard !verifiedInit else { return }
            guard let cwd, let worktree, session == sessionID,
                  URL(fileURLWithPath: cwd).resolvingSymlinksInPath().standardizedFileURL.path
                    == worktree.resolvingSymlinksInPath().standardizedFileURL.path else {
                throw ClaudeCodeFailure("Claude Code did not open the selected worktree.")
            }
            verifiedInit = true
        case let .hook(id, started):
            // initialize の応答は SessionStart フックの完了を待つので、フックの実行中は起動の待ち時間を数えない。
            guard initializeID != nil else { return }
            if started {
                runningHooks.insert(id)
                startupWatchdog?.cancel()
                startupWatchdog = nil
            } else if runningHooks.remove(id) != nil, runningHooks.isEmpty {
                armStartupWatchdog()
            }
        case let .stream(event):
            guard let turn = currentTurn, let block = textBlocks.stream(event) else { return }
            stream.yield(.message(ItemKey(thread: sessionID, turn: turn, item: block.item), text: block.text, final: false))
        case let .assistant(content):
            guard let turn = currentTurn else { return }
            for (item, text) in textBlocks.assistant(content) {
                stream.yield(.message(ItemKey(thread: sessionID, turn: turn, item: item), text: text, final: true))
            }
        case let .result(result):
            guard let turn = currentTurn else { return }
            let (status, error) = ClaudeCodeMessage.completion(result, interrupted: interrupted.contains(turn))
            currentTurn = nil
            interrupted.remove(turn)
            textBlocks.reset()
            approvals = approvals.filter { $0.value.key.turn != turn && !$0.value.key.turn.isEmpty }
            stream.yield(.completed(thread: sessionID, turn: turn, status: status, error: error))
        case .ignored: break
        }
    }

    private func appendStderr(_ chunk: Data) {
        stderrTail.append(chunk)
        if stderrTail.count > 4096 { stderrTail.removeFirst(stderrTail.count - 4096) }
    }

    private func stderrEnded() {
        stderrClosed = true
        resumeStderrWaiter()
    }

    private func stderrWaitTimedOut() { resumeStderrWaiter() }

    private func resumeStderrWaiter() {
        guard let waiter = stderrWaiter else { return }
        stderrWaiter = nil
        waiter.resume()
    }

    /// CLI は stderr に理由を書いてすぐ終わるので、stderr の残りを最大 1 秒待ってから終える。
    private func outputEnded() async {
        guard !finished else { return }
        if !stderrClosed {
            await withCheckedContinuation { continuation in
                stderrWaiter = continuation
                stderrTimer = Task {
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    stderrWaitTimedOut()
                }
            }
        }
        stderrTimer?.cancel()
        stderrTimer = nil
        stderrReader?.cancel()
        let line = String(decoding: stderrTail, as: UTF8.self).split(whereSeparator: \.isNewline)
            .last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        finish(line.map { ClaudeCodeFailure("Claude Code exited: \($0.trimmingCharacters(in: .whitespaces))") } ?? ClaudeCodeFailure.disconnected)
    }

    private func finish(_ error: Error?) {
        guard !finished else { return }
        finished = true
        startupWatchdog?.cancel()
        startupWatchdog = nil
        initializeID = nil
        runningHooks.removeAll()
        resumeStderrWaiter()
        stderrTimer?.cancel()
        stderrTimer = nil
        reader?.cancel()
        reader = nil
        stderrReader?.cancel()
        stderrReader = nil
        let reason = error ?? ClaudeCodeFailure.disconnected
        for waiter in pending.values { waiter.resume(throwing: reason) }
        pending.removeAll()
        approvals.removeAll()
        currentTurn = nil
        interrupted.removeAll()
        textBlocks.reset()
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
