import XCTest
@testable import Quetzal

struct ClaudeMockServer {
    let folder: URL
    let executable: URL

    init(_ program: String) throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        executable = folder.appendingPathComponent("claude")
        let source = """
        #!/usr/bin/python3
        import json, os, signal, sys, time
        signal.alarm(15)
        sid = None
        def read(): return json.loads(sys.stdin.readline())
        def wait(): sys.stdin.read()
        def line(message): return (json.dumps(message, ensure_ascii=False) + "\\n").encode()
        def send(message): os.write(1, line(message))
        def burst(*messages): os.write(1, b"".join(line(m) for m in messages))
        def respond(request, response=None, error=None, code=None):
            body = {"subtype":"success","request_id":request["request_id"],"response":response or {}}
            if error is not None: body = {"subtype":"error","request_id":request["request_id"],"error":error}
            if code is not None: body["error_code"] = code
            send({"type":"control_response","response":body})
        def control(subtype, **fields):
            req = read()
            assert req["type"] == "control_request" and req["request"] == dict(fields, subtype=subtype), req
            return req
        def confirmed(model=None, effort=None, **extra):
            respond(control("get_settings"), {"applied": dict(extra, model=model, effort=effort)})
        def hook(hook_id, started=True):
            return {"type":"system","subtype":"hook_started" if started else "hook_response","hook_id":hook_id,"hook_event":"SessionStart"}
        def start(model=None, effort=None, settings=None, instructions=None, hook_seconds=None, models=None, confirm=True):
            global sid
            args = sys.argv[1:]
            sid = args[args.index("--session-id") + 1]
            expected = ["--output-format","stream-json","--verbose","--input-format","stream-json"]
            if effort is not None: expected += ["--effort", effort]
            if model is not None: expected += ["--model", model]
            expected += ["--permission-prompt-tool","stdio","--include-partial-messages","--session-id",sid,
                         "--disallowedTools","AskUserQuestion","--setting-sources","user"]
            if settings is None: assert args == expected, args
            else: assert args[:-1] == expected + ["--settings"] and json.loads(args[-1]) == settings, args
            assert os.path.samefile(os.getcwd(), os.path.dirname(os.path.abspath(sys.argv[0])))
            with open("sid", "w") as marker: marker.write(sid)
            req = read()
            assert req["type"] == "control_request" and req["request"]["subtype"] == "initialize", req
            if instructions is None: assert "appendSystemPrompt" not in req["request"], req
            else: assert req["request"]["appendSystemPrompt"] == instructions, req
            if hook_seconds is not None:
                send(hook("h1"))
                time.sleep(hook_seconds)
                send(hook("h1", started=False))
            respond(req, {"commands":[],"pid":os.getpid(),"models":models or []})
            if confirm and (model is not None or effort is not None): confirmed(model, effort)
        def init(cwd=None): return {"type":"system","subtype":"init","cwd":cwd or os.getcwd(),"session_id":sid,"tools":[]}
        def user(n):
            req = read()
            assert req["type"] == "user" and req["message"]["content"][0]["text"] == str(n) and req["parent_tool_use_id"] is None, req
            send(init())
            return req
        def stream(event, parent=None): return {"type":"stream_event","event":event,"parent_tool_use_id":parent,"session_id":sid}
        def begin(msg): return stream({"type":"message_start","message":{"id":msg}})
        def block(index): return stream({"type":"content_block_start","index":index,"content_block":{"type":"text","text":""}})
        def delta(index, text, parent=None):
            return stream({"type":"content_block_delta","index":index,"delta":{"type":"text_delta","text":text}}, parent)
        def assistant(msg, text, model="claude-test", parent=None):
            content = [{"type":"text","text":text}]
            return {"type":"assistant","message":{"id":msg,"model":model,"role":"assistant","content":content},"parent_tool_use_id":parent,"session_id":sid}
        def result(subtype="success", is_error=False, **extra):
            return dict({"type":"result","subtype":subtype,"is_error":is_error,"session_id":sid}, **extra)
        def ask(request_id, tool, input, **extra):
            request = dict({"subtype":"can_use_tool","tool_name":tool,"input":input,"tool_use_id":"use-" + request_id}, **extra)
            return {"type":"control_request","request_id":request_id,"request":request}
        def cancel(request_id): return {"type":"control_cancel_request","request_id":request_id}
        """ + "\n" + program
        try Data(source.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }

    func remove() throws { try FileManager.default.removeItem(at: folder) }

    func client(startupTimeout: Duration = .seconds(20), project: ClaudeCodeProject = ClaudeCodeProject()) -> ClaudeCodeClient {
        ClaudeCodeClient(executable: executable, startupTimeout: startupTimeout, project: project)
    }
}

/// Python の式として埋め込む。
func python(_ value: some Encodable) throws -> String {
    "json.loads(r'''\(String(decoding: try JSONEncoder().encode(value), as: UTF8.self))''')"
}

func describe(_ event: AgentEvent) -> String {
    func name(_ id: RequestID) -> String {
        switch id {
        case .integer(let id): String(id)
        case .string(let id): id
        }
    }
    switch event {
    case let .message(key, text, final): return "message \(key.turn) \(key.item) \(text)\(final ? " final" : "")"
    case let .completed(_, turn, status, error): return "completed \(turn) \(status)" + (error.map { " \($0)" } ?? "")
    case let .approval(request): return "approval \(request.key.turn) \(name(request.id))"
    case let .resolved(_, id): return "resolved \(name(id))"
    default: return "other"
    }
}

final class ClaudeCodeClientTests: XCTestCase {
    let settings = ModelSettings(model: nil, effort: nil)

    private func next(_ events: inout AsyncThrowingStream<AgentEvent, Error>.AsyncIterator) async throws -> AgentEvent {
        guard let event = try await events.next() else { throw ClaudeCodeFailure("The event stream ended.") }
        return event
    }

    private func expect(_ events: inout AsyncThrowingStream<AgentEvent, Error>.AsyncIterator, _ expected: String,
                        line: UInt = #line) async throws {
        let event = try await next(&events)
        XCTAssertEqual(describe(event), expected, line: line)
    }

    private func failure(_ operation: () async throws -> Void) async -> String? {
        do {
            try await operation()
            return nil
        } catch { return error.localizedDescription }
    }

    func testArgumentsHandshakeAndWorkingDirectory() async throws {
        var both = ClaudeCodeProject(instructions: "Contents of CLAUDE.md:\n\nBe brief.")
        both.deny = ["Read(./.env)", "WebSearch"]
        both.ask = ["Bash(git push:*)"]
        var denyOnly = ClaudeCodeProject()
        denyOnly.deny = ["WebSearch"]
        let cases: [(String?, String?, ClaudeCodeProject, [String: [String: [String]]]?)] = [
            (nil, nil, ClaudeCodeProject(), nil),
            ("opus", nil, both, ["permissions": ["deny": both.deny, "ask": both.ask]]),
            (nil, "max", denyOnly, ["permissions": ["deny": ["WebSearch"]]]),
            ("sonnet", "low", ClaudeCodeProject(), nil)
        ]
        for (model, effort, project, expected) in cases {
            let arguments = [
                "model=\(try model.map(python) ?? "None")", "effort=\(try effort.map(python) ?? "None")",
                "settings=\(try expected.map(python) ?? "None")",
                "instructions=\(try project.instructions.map(python) ?? "None")"
            ].joined(separator: ",")
            let server = try ClaudeMockServer("start(\(arguments))\nwait()")
            defer { try? server.remove() }
            let client = server.client(project: project)
            let session = try await client.start(worktree: server.folder, settings: ModelSettings(model: model, effort: effort))
            let marker = server.folder.appendingPathComponent("sid")
            XCTAssertEqual(session, try String(contentsOf: marker, encoding: .utf8))
            XCTAssertNotNil(UUID(uuidString: session))
            await withinDeadline("Close session") { await client.close() }
        }
    }

    func testStartupChecksResolvedModelAndEffort() async throws {
        let server = try ClaudeMockServer(#"""
        start(model="sonnet", effort="ultracode", models=[{"value":"sonnet","resolvedModel":"claude-sonnet"}], confirm=False)
        confirmed(model="claude-sonnet", effort="xhigh", ultracode=True)
        user(1)
        send(result())
        wait()
        """#)
        defer { try? server.remove() }
        let settings = ModelSettings(model: "sonnet", effort: "ultracode")
        let client = server.client()
        let thread = try await client.start(worktree: server.folder, settings: settings)
        var events = client.events.makeAsyncIterator()
        _ = try await client.startTurn(threadID: thread, text: "1", settings: settings)
        try await expect(&events, "completed 1 completed")
        await client.close()
    }

    func testStartupRejectsModelFallbackAndMismatchedEffort() async throws {
        let cases: [(ModelSettings, String, String)] = [
            (ModelSettings(model: "haiku", effort: nil), #"""
            start(model="haiku", confirm=False)
            confirmed(model="sonnet")
            respond(control("set_model", model="haiku"), error="Restricted model", code="restricted_by_org")
            wait()
            """#, "Restricted model"),
            (ModelSettings(model: nil, effort: "low"), #"""
            start(effort="low", confirm=False)
            confirmed(effort="medium")
            wait()
            """#, "Claude Code reported effort medium")
        ]
        for (requested, program, expected) in cases {
            let server = try ClaudeMockServer(program)
            defer { try? server.remove() }
            let client = server.client()
            let error = await failure { _ = try await client.start(worktree: server.folder, settings: requested) }
            XCTAssertTrue(error?.contains(expected) == true, error ?? "Started with different settings")
            await client.close()
        }
    }

    func testStartupCanUseFlagsWhenOlderCLIDoesNotReportSettings() async throws {
        let server = try ClaudeMockServer(#"""
        start(model="sonnet", confirm=False)
        respond(control("get_settings"), error="Unsupported control request subtype: get_settings")
        user(1)
        send(result())
        wait()
        """#)
        defer { try? server.remove() }
        let settings = ModelSettings(model: "sonnet", effort: nil)
        let client = server.client()
        let thread = try await client.start(worktree: server.folder, settings: settings)
        var events = client.events.makeAsyncIterator()
        _ = try await client.startTurn(threadID: thread, text: "1", settings: settings)
        try await expect(&events, "completed 1 completed")
        await client.close()
    }

    func testSettingsChangeIsAcknowledgedBeforeUserMessageAndKeepsSession() async throws {
        let server = try ClaudeMockServer(#"""
        start(model="sonnet", effort="low")
        user(1)
        send(result())
        respond(control("set_model", model="haiku"))
        respond(control("apply_flag_settings", settings={"effortLevel":"high"}))
        confirmed(model="claude-haiku", effort="high")
        user(2)
        send(result())
        user(3)
        send(result())
        respond(control("apply_flag_settings", settings={"effortLevel":"ultracode"}))
        confirmed(model="claude-haiku", effort="xhigh", ultracode=True)
        user(4)
        send(result())
        wait()
        """#)
        defer { try? server.remove() }
        let initial = ModelSettings(model: "sonnet", effort: "low")
        let updated = ModelSettings(model: "haiku", effort: "high")
        let ultracode = ModelSettings(model: "haiku", effort: "ultracode")
        let client = server.client()
        let thread = try await client.start(worktree: server.folder, settings: initial)
        var events = client.events.makeAsyncIterator()
        for (turn, settings) in [initial, updated, updated, ultracode].enumerated() {
            let number = String(turn + 1)
            _ = try await client.startTurn(threadID: thread, text: number, settings: settings)
            let event = try await next(&events)
            guard case let .completed(sessionID, turnID, status, _) = event else { return XCTFail("Expected completion") }
            XCTAssertEqual(sessionID, thread)
            XCTAssertEqual(turnID, number)
            XCTAssertEqual(status, "completed")
        }
        await client.close()
    }

    func testRejectedModelCanBeCorrectedWithoutSubmittingTheDraft() async throws {
        let server = try ClaudeMockServer(#"""
        start()
        respond(control("set_model", model="restricted"), error="Restricted model", code="restricted_by_org")
        respond(control("set_model", model="sonnet"))
        user(1)
        send(result())
        wait()
        """#)
        defer { try? server.remove() }
        let client = server.client()
        let thread = try await client.start(worktree: server.folder, settings: settings)
        let unavailable = ModelSettings(model: "restricted", effort: nil)
        let error = await failure { _ = try await client.startTurn(threadID: thread, text: "not submitted", settings: unavailable) }
        XCTAssertEqual(error, "Restricted model")
        let available = ModelSettings(model: "sonnet", effort: nil)
        var events = client.events.makeAsyncIterator()
        _ = try await client.startTurn(threadID: thread, text: "1", settings: available)
        try await expect(&events, "completed 1 completed")
        await client.close()
    }

    func testRejectedEffortAfterModelChangeClosesWithoutSubmittingTheDraft() async throws {
        let server = try ClaudeMockServer(#"""
        start()
        respond(control("set_model", model="sonnet"))
        respond(control("apply_flag_settings", settings={"effortLevel":"high"}), error="Rejected effort")
        assert sys.stdin.readline() == ""
        """#)
        defer { try? server.remove() }
        let client = server.client()
        let thread = try await client.start(worktree: server.folder, settings: settings)
        let proposed = ModelSettings(model: "sonnet", effort: "high")
        let rejection = await failure { _ = try await client.startTurn(threadID: thread, text: "not submitted", settings: proposed) }
        XCTAssertEqual(rejection, "Rejected effort")
        let retry = await failure { _ = try await client.startTurn(threadID: thread, text: "retry", settings: proposed) }
        XCTAssertEqual(retry, ClaudeCodeFailure.disconnected.localizedDescription)
        await client.close()
    }

    func testPendingSettingsRequestRejectsConcurrentSendAndTimesOut() async throws {
        let server = try ClaudeMockServer(#"""
        start()
        control("set_model", model="sonnet")
        with open("pending", "w"): pass
        assert sys.stdin.readline() == ""
        """#)
        defer { try? server.remove() }
        let client = server.client(startupTimeout: .seconds(2))
        let thread = try await client.start(worktree: server.folder, settings: settings)
        let selected = ModelSettings(model: "sonnet", effort: nil)
        let first = Task { try await client.startTurn(threadID: thread, text: "first", settings: selected) }
        let marker = server.folder.appendingPathComponent("pending").path
        let deadline = ContinuousClock.now + .seconds(1)
        while !FileManager.default.fileExists(atPath: marker), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker))
        let busy = await failure { _ = try await client.startTurn(threadID: thread, text: "second", settings: selected) }
        XCTAssertEqual(busy, "A request is already running.")
        let timeout = await failure { _ = try await first.value }
        XCTAssertTrue(timeout?.contains("did not confirm the session settings") == true, timeout ?? "Submitted the request")
        await client.close()
    }

    func testStreamedTextFinalBlocksAndTwoTurns() async throws {
        let server = try ClaudeMockServer(#"""
        start()
        user(1)
        packets = [begin("m1"), block(0), delta(0,"犬"), {"type":"rate_limit_event","rate_limit_info":{}},
            {"type":"prompt_suggestion","suggestion":"x"}, {"type":"tool_use_summary","summary":"x"}, {"type":"brand_new"},
            {"type":"system","subtype":"brand_new"}, stream({"type":"brand_new"}), delta(0,"!"),
            {"type":"user","message":{"role":"user","content":[]},"parent_tool_use_id":None},
            block(1), delta(1,"second"), delta(0,"sub",parent="tool"), assistant("m1","犬!"), assistant("m1","second!"),
            assistant("m2","final only"), assistant("m3","API Error",model="<synthetic>"), assistant("m4","sub",parent="tool"),
            result()]
        data = b"".join(line(p) for p in packets)
        cut = data.index("犬".encode()) + 1
        os.write(1,data[:cut])
        time.sleep(.02)
        os.write(1,data[cut:])
        user(2)
        send(begin("m5"))
        send(block(0))
        send(delta(0,"two"))
        time.sleep(.3)
        send(assistant("m5","two!"))
        send(result())
        wait()
        """#)
        defer { try? server.remove() }
        let client = server.client()
        var events = client.events.makeAsyncIterator()
        let session = try await client.start(worktree: server.folder, settings: settings)
        let first = try await client.startTurn(threadID: session, text: "1", settings: settings)
        XCTAssertEqual(first, "1")
        var seen: [String] = []
        while true {
            let event = try await next(&events)
            if case let .message(key, _, _) = event { XCTAssertEqual(key.thread, session) }
            seen.append(describe(event))
            if case .completed = event { break }
        }
        XCTAssertEqual(seen, [
            "message 1 m1:0 犬", "message 1 m1:0 !", "message 1 m1:1 second", "message 1 m1:0 犬! final",
            "message 1 m1:1 second! final", "message 1 m2:final-1 final only final", "completed 1 completed"
        ])
        let second = try await client.startTurn(threadID: session, text: "2", settings: settings)
        XCTAssertEqual(second, "2")
        let busy = await failure { _ = try await client.startTurn(threadID: session, text: "3", settings: settings) }
        XCTAssertEqual(busy, "A request is already running.")
        seen = []
        while true {
            let event = try await next(&events)
            seen.append(describe(event))
            if case .completed = event { break }
        }
        XCTAssertEqual(seen, ["message 2 m5:0 two", "message 2 m5:0 two! final", "completed 2 completed"])
        await withinDeadline("Close session") { await client.close() }
    }

    func testResultRightAfterRequestBelongsToTurn() async throws {
        let server = try ClaudeMockServer(#"""
        start()
        time.sleep(.5)
        burst(init(), begin("m"), block(0), delta(0,"fast"), result())
        req = read()
        assert req["type"] == "user" and len(req["message"]["content"][0]["text"]) == 1 << 20
        wait()
        """#)
        defer { try? server.remove() }
        let client = server.client()
        var events = client.events.makeAsyncIterator()
        _ = try await client.start(worktree: server.folder, settings: settings)
        // パイプの容量を超える依頼にして、モックが読み終えるまで書き込みが終わらないようにする。
        let turn = try await client.startTurn(threadID: "", text: String(repeating: "a", count: 1 << 20), settings: settings)
        XCTAssertEqual(turn, "1")
        try await expect(&events, "message 1 m:0 fast")
        try await expect(&events, "completed 1 completed")
        await withinDeadline("Close session") { await client.close() }
    }

    func testToolApprovalAllowDenyCancelAndUnsupportedRequests() async throws {
        let server = try ClaudeMockServer(#"""
        start()
        send(ask("early","Bash",{"command":"ls"}))
        user(1)
        send(ask("a","Bash",{"command":"ls","description":"List files"}))
        r = read()
        assert r == {"type":"control_response","response":{"subtype":"success","request_id":"a","response":
            {"behavior":"allow","updatedInput":{"command":"ls","description":"List files"},"toolUseID":"use-a"}}}, r
        send(ask("b","Write",{"file_path":"/x"}))
        r = read()
        assert r == {"type":"control_response","response":{"subtype":"success","request_id":"b","response":
            {"behavior":"deny","message":"The user declined this tool use.","toolUseID":"use-b"}}}, r
        send(ask("c","Read",{"file_path":"/y"}))
        send(cancel("c"))
        send({"type":"control_request","request_id":"u","request":{"subtype":"hook_callback"}})
        r = read()
        assert r == {"type":"control_response","response":{"subtype":"error","request_id":"u",
            "error":"Unsupported control request subtype: hook_callback"}}, r
        send(result())
        wait()
        """#)
        defer { try? server.remove() }
        let client = server.client()
        var events = client.events.makeAsyncIterator()
        _ = try await client.start(worktree: server.folder, settings: settings)
        var early: ApprovalRequest?
        var cancelled: ApprovalRequest?
        var seen: [String] = []
        while true {
            let event = try await next(&events)
            seen.append(describe(event))
            switch event {
            case .approval(let request) where request.id == .string("early"):
                XCTAssertEqual(request.key.turn, "")
                early = request
                _ = try await client.startTurn(threadID: "", text: "1", settings: settings)
            case .approval(let request) where request.id == .string("a"):
                XCTAssertEqual(request.key.item, "use-a")
                try await client.answer(request, allow: true)
                let twice = await failure { try await client.answer(request, allow: false) }
                XCTAssertEqual(twice, "The request has ended.")
            case .approval(let request) where request.id == .string("b"):
                try await client.answer(request, allow: false)
            case .approval(let request):
                cancelled = request
            case .resolved:
                let late = await failure { try await client.answer(XCTUnwrap(cancelled), allow: true) }
                XCTAssertEqual(late, "The request has ended.")
            case .completed:
                let stale = await failure { try await client.answer(XCTUnwrap(early), allow: false) }
                XCTAssertEqual(stale, "The request has ended.")
                XCTAssertEqual(seen, ["approval  early", "approval 1 a", "approval 1 b", "approval 1 c", "resolved c", "completed 1 completed"])
                await withinDeadline("Close session") { await client.close() }
                return
            default: break
            }
        }
    }

    func testInterruptAndFailedResults() async throws {
        let server = try ClaudeMockServer(#"""
        start()
        user(1)
        send(begin("m"))
        send(block(0))
        send(delta(0,"partial"))
        r = read()
        assert r["type"] == "control_request" and r["request"] == {"subtype":"interrupt"}, r
        interrupted = {"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]},"parent_tool_use_id":None}
        burst({"type":"control_response","response":{"subtype":"success","request_id":r["request_id"],"response":{}}},
            interrupted, result("error_during_execution"))
        user(2)
        r = read()
        assert r["request"] == {"subtype":"interrupt"}, r
        respond(r, error="Cannot interrupt now")
        time.sleep(.2)
        send(result("error_during_execution", errors=["Stopped"]))
        user(3)
        send(result("error_during_execution", errors=["Tool crashed"]))
        user(4)
        send(result("success", is_error=True, result="API Error: 500"))
        user(5)
        send(result("error_max_turns"))
        user(6)
        send(result("error_max_turns", errors=["one","two"]))
        user(7)
        send(result())
        user(8)
        r = read()
        assert r["request"] == {"subtype":"interrupt"}, r
        burst(result("error_during_execution"),
            {"type":"control_response","response":{"subtype":"success","request_id":r["request_id"],"response":{}}})
        wait()
        """#)
        defer { try? server.remove() }
        let client = server.client()
        var events = client.events.makeAsyncIterator()
        let session = try await client.start(worktree: server.folder, settings: settings)
        let first = try await client.startTurn(threadID: session, text: "1", settings: settings)
        try await expect(&events, "message 1 m:0 partial")
        try await client.interrupt(threadID: session, turnID: first)
        try await expect(&events, "completed 1 interrupted")
        let second = try await client.startTurn(threadID: session, text: "2", settings: settings)
        let rejected = await failure { try await client.interrupt(threadID: session, turnID: second) }
        XCTAssertEqual(rejected, "Cannot interrupt now")
        try await expect(&events, "completed 2 failed Stopped")
        for (number, expected) in [(3, "Tool crashed"), (4, "API Error: 500"), (5, "error_max_turns"), (6, "one\ntwo")] {
            _ = try await client.startTurn(threadID: session, text: String(number), settings: settings)
            try await expect(&events, "completed \(number) failed \(expected)")
        }
        // 送っていれば、モックは次の依頼の代わりに中断の制御要求を読んで失敗する。
        try await client.interrupt(threadID: session, turnID: "6")
        _ = try await client.startTurn(threadID: session, text: "7", settings: settings)
        try await expect(&events, "completed 7 completed")
        // result を中断の応答より先に処理しても、中断を求めた依頼として扱う。
        let eighth = try await client.startTurn(threadID: session, text: "8", settings: settings)
        try await client.interrupt(threadID: session, turnID: eighth)
        try await expect(&events, "completed 8 interrupted")
        await withinDeadline("Close session") { await client.close() }
    }

    func testStartupFailuresAndClose() async throws {
        for _ in 0..<20 {
            let server = try ClaudeMockServer("sys.stderr.write('starting\\nerror: invalid effort\\n')\nsys.exit(1)")
            defer { try? server.remove() }
            let client = server.client()
            let reason = await failure { _ = try await client.start(worktree: server.folder, settings: self.settings) }
            XCTAssertEqual(reason, "Claude Code exited: error: invalid effort")
            await withinDeadline("Close session") { await client.close() }
        }
        for (program, expected) in [
            ("read()\nprint('invalid', flush=True)\nwait()", ClaudeCodeFailure.malformed.message),
            ("respond(read(), error='Not logged in')\nwait()", "Not logged in")
        ] {
            let server = try ClaudeMockServer(program)
            defer { try? server.remove() }
            let client = server.client()
            let reason = await failure { _ = try await client.start(worktree: server.folder, settings: self.settings) }
            XCTAssertEqual(reason, expected)
            await withinDeadline("Close session") { await client.close() }
        }
        let server = try ClaudeMockServer("read()\ntime.sleep(60)")
        defer { try? server.remove() }
        let client = server.client()
        let starting = Task { try await client.start(worktree: server.folder, settings: settings) }
        try await Task.sleep(for: .milliseconds(100))
        await withinDeadline("Close session") { await client.close() }
        do { _ = try await starting.value; XCTFail("Unexpected success") } catch {}
    }

    func testStartupTimeoutExcludesRunningHooks() async throws {
        let timeout = "Claude Code did not finish starting. Check the executable and try again."
        for (program, expected) in [
            ("read()\nwait()", timeout),
            ("start(hook_seconds=2.5)\nwait()", nil),
            ("read()\nsend(hook('h1'))\ntime.sleep(.1)\nsend(hook('h1', started=False))\nwait()", timeout)
        ] {
            let server = try ClaudeMockServer(program)
            defer { try? server.remove() }
            let client = server.client(startupTimeout: .milliseconds(1500))
            let began = ContinuousClock.now
            let reason = await failure { _ = try await client.start(worktree: server.folder, settings: self.settings) }
            XCTAssertEqual(reason, expected)
            if expected != nil {
                XCTAssertGreaterThan(ContinuousClock.now - began, .milliseconds(1400))
                XCTAssertLessThan(ContinuousClock.now - began, .seconds(5))
            }
            await withinDeadline("Close session") { await client.close() }
        }
    }

    func testLargeStderrDoesNotBlock() async throws {
        let server = try ClaudeMockServer(#"""
        sys.stderr.write("x" * 131072 + "\n")
        sys.stderr.flush()
        start()
        user(1)
        sys.stderr.write("y" * 131072 + "\n")
        sys.stderr.flush()
        send(result())
        read()
        sys.stderr.write("final reason\n")
        sys.exit(1)
        """#)
        defer { try? server.remove() }
        await withinDeadline("Start and send with large stderr") {
            let client = server.client()
            var events = client.events.makeAsyncIterator()
            _ = try await client.start(worktree: server.folder, settings: self.settings)
            _ = try await client.startTurn(threadID: "", text: "1", settings: self.settings)
            try await self.expect(&events, "completed 1 completed")
            _ = try await client.startTurn(threadID: "", text: "2", settings: self.settings)
            let reason = await self.failure { _ = try await events.next() }
            XCTAssertEqual(reason, "Claude Code exited: final reason")
            await client.close()
        }
    }

    func testStdoutClosedWhileChildKeepsWritingStderr() async throws {
        let ticks = #"""
        os.close(1)
        for i in range(60):
            sys.stderr.write("tick %d\n" % i)
            sys.stderr.flush()
            time.sleep(.05)
        """#
        for starting in [true, false] {
            let server = try ClaudeMockServer((starting ? "read()" : "start()") + "\n" + ticks)
            defer { try? server.remove() }
            let client = server.client()
            var events = client.events.makeAsyncIterator()
            let began = ContinuousClock.now
            let reason: String?
            if starting {
                reason = await failure { _ = try await client.start(worktree: server.folder, settings: self.settings) }
            } else {
                _ = try await client.start(worktree: server.folder, settings: settings)
                reason = await failure { _ = try await events.next() }
            }
            XCTAssertTrue(reason?.hasPrefix("Claude Code exited: tick ") == true, reason ?? "")
            XCTAssertLessThan(ContinuousClock.now - began, .milliseconds(2500))
            await withinDeadline("Close session") { await client.close() }
        }
    }

    func testWorkingDirectoryMismatchDisconnects() async throws {
        let server = try ClaudeMockServer(#"""
        start()
        read()
        send(init(cwd="/"))
        wait()
        """#)
        defer { try? server.remove() }
        let client = server.client()
        var events = client.events.makeAsyncIterator()
        _ = try await client.start(worktree: server.folder, settings: settings)
        _ = try await client.startTurn(threadID: "", text: "1", settings: settings)
        let reason = await failure { _ = try await events.next() }
        XCTAssertEqual(reason, "Claude Code did not open the selected worktree.")
        await withinDeadline("Close session") { await client.close() }
    }

    func testToolApprovalDescriptions() throws {
        let key = ItemKey(thread: "s", turn: "1", item: "use")
        func tool(_ name: String, _ input: JSON, _ extra: [String: JSON] = [:]) -> ApprovalRequest {
            let params = ["tool_name": .string(name), "input": input, "tool_use_id": .string("use")].merging(extra) { $1 }
            return ApprovalRequest(id: .string("r"), kind: .tool, key: key, params: .object(params))
        }
        let bash = tool("Bash", .object(["command": .string("ls -a"), "description": .string("List files")]),
                        ["decision_reason": .string("Not in the allow list"), "blocked_path": .string("/etc")])
        XCTAssertEqual(bash.title, "Run command")
        XCTAssertEqual(bash.details, ["ls -a", "List files", "Not in the allow list", "Blocked path: /etc"])
        for name in ["Write", "Edit", "MultiEdit"] {
            let change = tool(name, .object(["file_path": .string("/w/a.swift"), "content": .string("x")]))
            XCTAssertEqual(change.title, "Change files")
            XCTAssertEqual(change.details, ["/w/a.swift"])
        }
        let notebook = tool("NotebookEdit", .object(["notebook_path": .string("/w/n.ipynb")]))
        XCTAssertEqual(notebook.title, "Change files")
        XCTAssertEqual(notebook.details, ["/w/n.ipynb"])
        let input: JSON = .object(["url": .string("https://example.test/a")])
        let other = tool("WebFetch", input)
        XCTAssertEqual(other.title, "Use WebFetch")
        XCTAssertEqual(other.details, [input.formatted])
        let warning = "Skills can let Claude use other tools without asking for the rest of this session. Allow only skills you installed yourself."
        XCTAssertEqual(tool("Skill", .object(["skill": .string("deploy"), "args": .string("--prod")])).details,
                       ["Skill: deploy", "Arguments: --prod", warning])
        XCTAssertEqual(tool("Skill", .object(["skill": .string("deploy")])).details, ["Skill: deploy", warning])
        XCTAssertTrue(bash.canAllow)
        XCTAssertEqual(try bash.result(allow: true), .object([
            "behavior": .string("allow"), "updatedInput": bash.params["input"], "toolUseID": .string("use")
        ]))
        XCTAssertEqual(try bash.result(allow: false), .object([
            "behavior": .string("deny"), "message": .string("The user declined this tool use."), "toolUseID": .string("use")
        ]))
        for request in [tool("Bash", .string("ls")), tool("", .object([:]))] {
            XCTAssertFalse(request.canAllow)
            XCTAssertThrowsError(try request.result(allow: true))
            XCTAssertEqual(try request.result(allow: false)["behavior"], .string("deny"))
        }
    }

    func testProjectLoad() throws {
        let manager = FileManager.default
        func folder() throws -> URL {
            let url = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try manager.createDirectory(at: url.appendingPathComponent(".claude"), withIntermediateDirectories: true)
            return url
        }
        func write(_ text: String, _ name: String, in root: URL) throws {
            try Data(text.utf8).write(to: root.appendingPathComponent(name))
        }
        func heading(_ root: URL, _ name: String) -> String {
            "Contents of \(root.appendingPathComponent(name).path) (project instructions, checked into the codebase):\n\n"
        }
        let root = try folder()
        let outside = try folder()
        defer { try? manager.removeItem(at: root); try? manager.removeItem(at: outside) }

        XCTAssertEqual(ClaudeCodeProject.load(in: root), ClaudeCodeProject())
        try write("top", "CLAUDE.md", in: root)
        XCTAssertEqual(ClaudeCodeProject.load(in: root).instructions, heading(root, "CLAUDE.md") + "top")
        try write("nested", ".claude/CLAUDE.md", in: root)
        XCTAssertEqual(ClaudeCodeProject.load(in: root).instructions,
                       heading(root, "CLAUDE.md") + "top\n\n" + heading(root, ".claude/CLAUDE.md") + "nested")
        try manager.removeItem(at: root.appendingPathComponent("CLAUDE.md"))
        XCTAssertEqual(ClaudeCodeProject.load(in: root).instructions, heading(root, ".claude/CLAUDE.md") + "nested")

        try write("agents", "AGENTS.md", in: root)
        try manager.createSymbolicLink(at: root.appendingPathComponent("CLAUDE.md"), withDestinationURL: root.appendingPathComponent("AGENTS.md"))
        try write("secret", "secret.md", in: outside)
        try manager.removeItem(at: root.appendingPathComponent(".claude/CLAUDE.md"))
        try manager.createSymbolicLink(at: root.appendingPathComponent(".claude/CLAUDE.md"), withDestinationURL: outside.appendingPathComponent("secret.md"))
        XCTAssertEqual(ClaudeCodeProject.load(in: root).instructions, heading(root, "CLAUDE.md") + "agents")

        try manager.removeItem(at: root.appendingPathComponent(".claude/CLAUDE.md"))
        try Data([0xff, 0xfe, 0x00]).write(to: root.appendingPathComponent(".claude/CLAUDE.md"))
        try manager.removeItem(at: root.appendingPathComponent("CLAUDE.md"))
        try write(String(repeating: "a", count: (1 << 20) + 1), "CLAUDE.md", in: root)
        XCTAssertNil(ClaudeCodeProject.load(in: root).instructions)

        let settings = try folder()
        defer { try? manager.removeItem(at: settings) }
        let real = settings.resolvingSymlinksInPath().standardizedFileURL.path
        try write(#"""
        {"permissions":{"deny":["Read(/secrets/**)","Read(./.env)",3,"WebSearch"],"ask":["Bash(git push:*)"],"allow":["Bash"]},
         "hooks":{}}
        """#, ".claude/settings.json", in: settings)
        try write(#"""
        {"permissions":{"deny":["WebSearch","Read(//etc/x)","Bash(/usr/bin/x:*)",{"x":1}],"ask":"Bash"}}
        """#, ".claude/settings.local.json", in: settings)
        try write("{}", ".mcp.json", in: settings)
        var expected = ClaudeCodeProject()
        expected.deny = ["Read(/\(real)/secrets/**)", "Read(./.env)", "WebSearch", "Read(//etc/x)", "Bash(/usr/bin/x:*)"]
        expected.ask = ["Bash(git push:*)"]
        expected.ignoredFiles = [".claude/settings.json", ".claude/settings.local.json", ".mcp.json"]
        XCTAssertEqual(ClaudeCodeProject.load(in: settings), expected)

        try write("{not json", ".claude/settings.json", in: settings)
        try manager.removeItem(at: settings.appendingPathComponent(".mcp.json"))
        expected.deny = ["WebSearch", "Read(//etc/x)", "Bash(/usr/bin/x:*)"]
        expected.ask = []
        expected.ignoredFiles = [".claude/settings.json", ".claude/settings.local.json"]
        expected.unreadableFiles = [".claude/settings.json"]
        XCTAssertEqual(ClaudeCodeProject.load(in: settings), expected)
    }
}
