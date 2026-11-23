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
}
