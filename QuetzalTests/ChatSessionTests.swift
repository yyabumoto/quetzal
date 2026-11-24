import XCTest
@testable import Quetzal

@MainActor
final class ChatSessionTests: XCTestCase {
    private let settings = ModelSettings(model: nil, effort: "high")

    private func waitFor(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw CodexFailure("Timed out waiting for session state.") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func testStreamCompletionBeforeStartReplyAndFollowUp() async throws {
        let server = try MockServer(#"""
        start()
        req = turn(1)
        p = {"threadId":"t","turnId":"1"}
        notify("item/agentMessage/delta",dict(p,itemId="a",delta="first"))
        notify("item/agentMessage/delta",dict(p,itemId="b",delta="second"))
        notify("item/agentMessage/delta",dict(p,itemId="a",delta=" part"))
        notify("item/completed",dict(p,item={"type":"agentMessage","id":"b","text":"second!"}))
        notify("item/completed",dict(p,item={"type":"agentMessage","id":"c","text":"final only"}))
        completed(1)
        time.sleep(.15)
        response(req,{"turn":{"id":"1"}})
        req = turn(2)
        send({"id":req["id"],"error":{"code":-1,"message":"Invalid effort"}})
        req = turn(2)
        response(req,{"turn":{"id":"2"}})
        notify("error",{"threadId":"t","turnId":"2","error":{"message":"Retrying"},"willRetry":True})
        notify("turn/completed",{"threadId":"t","turn":{"id":"2","status":"failed","error":{"message":"Sign in again"}}})
        time.sleep(60)
        """#)
        defer { try? server.remove() }
        let session = ChatSession()
        await session.start(worktree: server.folder, settings: settings, executable: server.executable)
        XCTAssertEqual(session.phase, .ready)
        await session.send(" \n")
        XCTAssertTrue(session.messages.isEmpty)
        await session.send("1")
        XCTAssertEqual(session.phase, .ready)
        XCTAssertEqual(session.messages.map(\.text), ["1", "first part", "second!", "final only"])
        await session.send("2")
        XCTAssertEqual(session.draft, "2")
        XCTAssertEqual(session.notice, "Invalid effort")
        XCTAssertTrue(session.canSend)
        await session.send("2")
        try await waitFor { session.phase == .ready }
        XCTAssertEqual(session.messages.last?.text, "Sign in again")
        await withinDeadline("Close session") { await session.close() }
    }

    func testSelectingCodexModelDuringTurnAppliesItsCompatibleEffortToTheNextRequest() async throws {
        let server = try MockServer(#"""
        start({"model":"gpt-6.2-sol","config":{"model_reasoning_effort":"max"}})
        req = turn(1, model="gpt-6.2-sol", effort="max")
        response(req,{"turn":{"id":"1"}})
        for _ in range(100):
            if os.path.exists("complete"): break
            time.sleep(.03)
        assert os.path.exists("complete")
        completed(1)
        req = turn(2, model="gpt-5.5", effort="medium")
        response(req,{"turn":{"id":"2"}})
        completed(2)
        time.sleep(60)
        """#)
        defer { try? server.remove() }
        let session = ChatSession()
        let first = ModelSettings(model: "gpt-6.2-sol", effort: "max")
        await session.start(worktree: server.folder, settings: first, executable: server.executable)
        XCTAssertEqual(session.settings, first)
        await session.send("1")
        XCTAssertEqual(session.phase, .running)
        session.updateSettings(session.provider.selectingModel("gpt-5.5", in: session.settings))
        await session.start(worktree: server.folder, settings: first, executable: server.executable, provider: .claudeCode)
        XCTAssertEqual(session.provider, .codex)
        XCTAssertEqual(session.settings, ModelSettings(model: "gpt-5.5", effort: "medium"))
        try Data().write(to: server.folder.appendingPathComponent("complete"))
        try await waitFor { session.phase == .ready }
        await session.send("2")
        try await waitFor { session.phase == .ready }
        XCTAssertEqual(session.messages.map(\.text), ["1", "2"])
        await session.close()
    }

    func testClaudeLeavesUnsentDraftWhenSettingsVerificationDisconnects() async throws {
        let server = try ClaudeMockServer(#"""
        start(effort="high")
        respond(control("apply_flag_settings", settings={"effortLevel":"low"}))
        confirmed(effort="medium")
        assert sys.stdin.readline() == ""
        """#)
        defer { try? server.remove() }
        let session = ChatSession()
        await session.start(worktree: server.folder, settings: settings, executable: server.executable, provider: .claudeCode)
        XCTAssertEqual(session.phase, .ready)
        session.updateSettings(ModelSettings(model: nil, effort: "low"))
        await session.send("not submitted")
        try await waitFor { session.phase == .disconnected }
        XCTAssertEqual(session.draft, "not submitted")
        XCTAssertTrue(session.messages.isEmpty)
        XCTAssertFalse(session.canEditSettings)
        XCTAssertTrue(session.notice?.contains("reported effort medium") == true)
        await session.close()
    }

    func testInterruptBeforeStartReplyAndFailedInterruptAfterCompletion() async throws {
        let server = try MockServer(#"""
        start()
        req = turn(1)
        p = {"threadId":"t","turnId":"1","itemId":"file"}
        send({"id":1,"method":"item/fileChange/requestApproval","params":p})
        interrupt = read()
        assert interrupt["method"] == "turn/interrupt"
        completed(1,"interrupted")
        response(req,{"turn":{"id":"1"}})
        send({"id":interrupt["id"],"error":{"code":-1,"message":"Already completed"}})
        req = turn(2)
        response(req,{"turn":{"id":"2"}})
        completed(2)
        time.sleep(60)
        """#)
        defer { try? server.remove() }
        let session = ChatSession()
        await session.start(worktree: server.folder, settings: settings, executable: server.executable)
        let send = Task { await session.send("1") }
        try await waitFor { session.approvals.count == 1 }
        XCTAssertFalse(session.approvals[0].canAllow)
        XCTAssertTrue(session.canInterrupt)
        await session.send("spurious")
        await session.interrupt()
        await send.value
        XCTAssertEqual(session.phase, .ready)
        XCTAssertNil(session.notice)
        XCTAssertTrue(session.approvals.isEmpty)
        XCTAssertEqual(session.messages.map(\.text), ["1", "Turn interrupted."])
        await session.send("2")
        try await waitFor { session.phase == .ready }
        await withinDeadline("Close session") { await session.close() }
    }

    func testDisconnectPreservesHistoryAndOtherWindow() async throws {
        let firstServer = try MockServer(#"""
        start()
        req = turn(1)
        response(req,{"turn":{"id":"1"}})
        notify("item/completed",{"threadId":"t","turnId":"1","item":{"id":"a","type":"agentMessage","text":"answer"}})
        send({"id":1,"method":"item/commandExecution/requestApproval","params":{"threadId":"t","turnId":"1","itemId":"cmd","command":"true"}})
        print("bad json", flush=True)
        """#)
        let secondServer = try MockServer("start()\ntime.sleep(60)")
        defer {
            try? firstServer.remove()
            try? secondServer.remove()
        }
        let first = ChatSession(), second = ChatSession()
        await first.start(worktree: firstServer.folder, settings: settings, executable: firstServer.executable)
        await second.start(worktree: secondServer.folder, settings: settings, executable: secondServer.executable)
        await first.send("1")
        try await waitFor { first.phase == .disconnected }
        XCTAssertEqual(first.messages.map(\.text), ["1", "answer"])
        XCTAssertTrue(first.approvals.isEmpty)
        await withinDeadline("Close session") { await first.close() }
        XCTAssertEqual(first.phase, .setup)
        XCTAssertEqual(second.phase, .ready)
        await withinDeadline("Close session") { await second.close() }
    }

    func testClosingDuringStartupReapsChildAndAllowsFreshSession() async throws {
        let server = try MockServer("""
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        with open("pid.tmp", "w") as marker:
            marker.write(str(os.getpid()))
        os.rename("pid.tmp", "pid")
        read()
        time.sleep(60)
        """)
        let next = try MockServer("start()\ntime.sleep(60)")
        defer { try? server.remove(); try? next.remove() }
        let session = ChatSession()
        let starting = Task { await session.start(worktree: server.folder, settings: settings, executable: server.executable) }
        let pidFile = server.folder.appendingPathComponent("pid")
        try await waitFor { FileManager.default.fileExists(atPath: pidFile.path) }
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8)))
        await withinDeadline("Close session") { await session.close() }
        await session.start(worktree: next.folder, settings: settings, executable: next.executable)
        await starting.value
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
        XCTAssertEqual(session.phase, .ready)
        XCTAssertEqual(session.worktree, next.folder)
        await withinDeadline("Close session") { await session.close() }
    }

    func testClaudeSessionStreamsApprovesInterruptsAndFollowsUp() async throws {
        let server = try ClaudeMockServer(#"""
        start(effort="high")
        user(1)
        send(begin("m"))
        send(block(0))
        send(delta(0,"Hel"))
        time.sleep(.1)
        send(delta(0,"lo"))
        send(ask("a","Bash",{"command":"ls"}))
        r = read()
        assert r["response"]["response"]["behavior"] == "allow", r
        send(assistant("m","Hello!"))
        send(result())
        user(2)
        send(ask("b","Write",{"file_path":"/x"}))
        r = read()
        assert r["type"] == "control_request" and r["request"] == {"subtype":"interrupt"}, r
        burst({"type":"control_response","response":{"subtype":"success","request_id":r["request_id"],"response":{}}},
            cancel("b"), result("error_during_execution"))
        user(3)
        send(assistant("m3","Again"))
        send(result())
        wait()
        """#)
        defer { try? server.remove() }
        let session = ChatSession()
        await session.start(worktree: server.folder, settings: settings, executable: server.executable, provider: .claudeCode)
        XCTAssertEqual(session.phase, .ready)
        XCTAssertEqual(session.provider, .claudeCode)
        await session.send("1")
        try await waitFor { session.messages.last?.text == "Hel" }
        try await waitFor { session.approvals.count == 1 }
        XCTAssertEqual(session.messages.map(\.text), ["1", "Hello"])
        XCTAssertEqual(session.messages.map(\.author), [.user, .claude])
        let request = session.approvals[0]
        XCTAssertEqual(request.title, "Run command")
        await session.answer(request.id, allow: true, reviewed: request)
        XCTAssertTrue(session.approvals.isEmpty)
        try await waitFor { session.phase == .ready }
        XCTAssertEqual(session.messages.map(\.text), ["1", "Hello!"])
        await session.send("2")
        try await waitFor { session.approvals.count == 1 }
        XCTAssertTrue(session.canInterrupt)
        await session.interrupt()
        try await waitFor { session.phase == .ready }
        XCTAssertTrue(session.approvals.isEmpty)
        XCTAssertNil(session.notice)
        XCTAssertEqual(session.messages.map(\.text), ["1", "Hello!", "2", "Turn interrupted."])
        await session.send("3")
        try await waitFor { session.phase == .ready && session.messages.last?.text == "Again" }
        await withinDeadline("Close session") { await session.close() }
        XCTAssertEqual(session.phase, .setup)
    }

    func testClaudeOutOfTurnApprovalClearsOnCompletion() async throws {
        let server = try ClaudeMockServer(#"""
        start(effort="high")
        time.sleep(.3)
        send(ask("early","Bash",{"command":"ls"}))
        user(1)
        send(result())
        wait()
        """#)
        defer { try? server.remove() }
        let session = ChatSession()
        await session.start(worktree: server.folder, settings: settings, executable: server.executable, provider: .claudeCode)
        try await waitFor { session.approvals.count == 1 }
        XCTAssertEqual(session.approvals[0].key.turn, "")
        await session.send("1")
        try await waitFor { session.phase == .ready && session.approvals.isEmpty }
        await withinDeadline("Close session") { await session.close() }
    }

    func testClaudeStartupFailureShowsReason() async throws {
        let server = try ClaudeMockServer(#"""
        sys.stderr.write("error: option '--effort <level>' argument 'xhigh' is invalid.\n")
        sys.exit(1)
        """#)
        defer { try? server.remove() }
        let session = ChatSession()
        await session.start(worktree: server.folder, settings: settings, executable: server.executable, provider: .claudeCode)
        XCTAssertEqual(session.phase, .disconnected)
        XCTAssertEqual(session.notice, "Claude Code exited: error: option '--effort <level>' argument 'xhigh' is invalid.")
        await withinDeadline("Close session") { await session.close() }
    }

    func testClaudeExitMidSessionKeepsHistory() async throws {
        let server = try ClaudeMockServer(#"""
        start(effort="high")
        user(1)
        send(assistant("m","answer"))
        send(result())
        user(2)
        send(ask("a","Bash",{"command":"ls"}))
        time.sleep(.3)
        sys.stderr.write("API connection lost\n")
        sys.exit(1)
        """#)
        defer { try? server.remove() }
        let session = ChatSession()
        await session.start(worktree: server.folder, settings: settings, executable: server.executable, provider: .claudeCode)
        await session.send("1")
        try await waitFor { session.phase == .ready }
        await session.send("2")
        try await waitFor { session.phase == .disconnected }
        XCTAssertEqual(session.messages.map(\.text), ["1", "answer", "2"])
        XCTAssertEqual(session.notice, "Claude Code exited: API connection lost")
        XCTAssertTrue(session.approvals.isEmpty)
        await withinDeadline("Close session") { await session.close() }
    }

    func testClaudeCloseWhileApprovalPendingReapsChild() async throws {
        let server = try ClaudeMockServer(#"""
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        start(effort="high")
        with open("pid.tmp", "w") as marker:
            marker.write(str(os.getpid()))
        os.rename("pid.tmp", "pid")
        user(1)
        send(ask("a","Bash",{"command":"ls"}))
        time.sleep(60)
        """#)
        defer { try? server.remove() }
        let session = ChatSession()
        await session.start(worktree: server.folder, settings: settings, executable: server.executable, provider: .claudeCode)
        await session.send("1")
        try await waitFor { session.approvals.count == 1 }
        let pidFile = server.folder.appendingPathComponent("pid")
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8)))
        await withinDeadline("Close session") { await session.close() }
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
        XCTAssertEqual(session.phase, .setup)
    }

    func testClaudeIgnoredProjectSettingsNotice() async throws {
        let notice = "Project settings in this worktree are not applied, except permission deny and ask rules: .claude/settings.json, .mcp.json."
        for (settingsFile, expected) in [(#"{"hooks":{}}"#, [notice]), ("{bad", [notice + " Could not read: .claude/settings.json."]), (nil, [])] {
            let server = try ClaudeMockServer("start(effort=\"high\")\nwait()")
            defer { try? server.remove() }
            if let settingsFile {
                try FileManager.default.createDirectory(at: server.folder.appendingPathComponent(".claude"), withIntermediateDirectories: true)
                try Data(settingsFile.utf8).write(to: server.folder.appendingPathComponent(".claude/settings.json"))
                try Data("{}".utf8).write(to: server.folder.appendingPathComponent(".mcp.json"))
            }
            let session = ChatSession()
            await session.start(worktree: server.folder, settings: settings, executable: server.executable, provider: .claudeCode)
            XCTAssertEqual(session.phase, .ready)
            XCTAssertEqual(session.messages.map(\.text), expected)
            XCTAssertTrue(session.messages.allSatisfy { $0.author == .status })
            await withinDeadline("Close session") { await session.close() }
        }
        let codex = try MockServer("start()\ntime.sleep(60)")
        defer { try? codex.remove() }
        try FileManager.default.createDirectory(at: codex.folder.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: codex.folder.appendingPathComponent(".claude/settings.json"))
        let session = ChatSession()
        await session.start(worktree: codex.folder, settings: settings, executable: codex.executable)
        XCTAssertEqual(session.phase, .ready)
        XCTAssertTrue(session.messages.isEmpty)
        await withinDeadline("Close session") { await session.close() }
    }
}
