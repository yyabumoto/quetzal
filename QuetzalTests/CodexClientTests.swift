import XCTest
@testable import Quetzal

struct MockServer {
    let folder: URL
    let executable: URL

    init(_ program: String) throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        executable = folder.appendingPathComponent("codex")
        let source = """
        #!/usr/bin/python3
        import json, os, signal, sys, time
        signal.alarm(15)
        def read(): return json.loads(sys.stdin.readline())
        def send(message):
            print(json.dumps(message, ensure_ascii=False), flush=True)
        def response(request, result): send({"id":request["id"], "result":result})
        def notify(method, params): send({"method":method, "params":params})
        def start(expected=None):
            assert sys.argv[1:] == ["app-server", "--stdio"]
            req = read()
            assert req["method"] == "initialize" and req["params"]["clientInfo"]["name"]
            response(req, {})
            assert read()["method"] == "initialized"
            req = read()
            assert req["method"] == "thread/start" and os.path.samefile(req["params"]["cwd"], os.getcwd())
            assert set(req["params"]) <= {"cwd","model","config"}
            if expected is not None: assert req["params"] == dict(expected, cwd=req["params"]["cwd"])
            response(req, {"thread":{"id":"t"},"cwd":os.getcwd()})
        def turn(number, model=None, effort="high"):
            req = read()
            assert req["method"] == "turn/start"
            expected = {"threadId":"t","input":[{"type":"text","text":str(number)}]}
            if model is not None: expected["model"] = model
            if effort is not None: expected["effort"] = effort
            assert req["params"] == expected, req
            return req
        def completed(number, status="completed"):
            notify("turn/completed", {"threadId":"t","turn":{"id":str(number),"status":status}})
        """ + "\n" + program
        try Data(source.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }

    func remove() throws { try FileManager.default.removeItem(at: folder) }
    func client() -> CodexClient { CodexClient(executable: executable) }
}

final class CodexClientTests: XCTestCase {
    let settings = ModelSettings(model: "test", effort: "high")

    func testOrderedStreamAndTwoTurns() async throws {
        let server = try MockServer(#"""
        start()
        req = turn(1, model="test")
        ctx = {"threadId":"t", "turnId":"1"}
        notify("turn/started", {"threadId":"t","turn":{"id":"1"}})
        packets = [
            {"method":"item/agentMessage/delta","params":dict(ctx,itemId="a",delta="犬")},
            {"method":"item/agentMessage/delta","params":dict(ctx,itemId="b",delta="B")},
            {"method":"item/completed","params":dict(ctx,item={"type":"agentMessage","id":"a","text":"犬!"})}]
        data = ("\n".join(json.dumps(p,ensure_ascii=False) for p in packets)+"\n").encode()
        cut = data.index("犬".encode()) + 1
        os.write(1,data[:cut])
        time.sleep(.02)
        os.write(1,data[cut:])
        completed(1)
        response(req,{"turn":{"id":"1"}})
        req = turn(2, model="test")
        response(req,{"turn":{"id":"2"}})
        interrupt = read()
        assert interrupt["method"] == "turn/interrupt" and interrupt["params"] == {"threadId":"t","turnId":"2"}
        completed(2,"interrupted")
        response(interrupt,{})
        """#)
        defer { try? server.remove() }
        let client = server.client()
        var events = client.events.makeAsyncIterator()
        let thread = try await client.start(worktree: server.folder, settings: settings)
        let first = try await client.startTurn(threadID: thread, text: "1", settings: settings)
        XCTAssertEqual(first, "1")
        guard case .started = try await events.next() else { return XCTFail() }
        for (id, expected, isFinal) in [("a","犬",false), ("b","B",false), ("a","犬!",true)] {
            guard case let .message(key, text, final) = try await events.next() else { return XCTFail() }
            XCTAssertEqual(key, ItemKey(thread: "t", turn: "1", item: id))
            XCTAssertEqual(text, expected)
            XCTAssertEqual(final, isFinal)
        }
        guard case .completed = try await events.next() else { return XCTFail() }
        let second = try await client.startTurn(threadID: thread, text: "2", settings: settings)
        try await client.interrupt(threadID: thread, turnID: second)
        guard case let .completed(_, _, status, _) = try await events.next() else { return XCTFail() }
        XCTAssertEqual(status, "interrupted")
        await withinDeadline("Close session") { await client.close() }
    }

    func testFileUpdatesAndIndependentApprovals() async throws {
        let server = try MockServer(#"""
        start()
        req = turn(1, model="test")
        response(req,{"turn":{"id":"1"}})
        p = {"threadId":"t","turnId":"1","itemId":"file"}
        send({"id":"file","method":"item/fileChange/requestApproval","params":dict(p,grantRoot="/workspace")})
        change = {"kind":{"type":"add"},"path":"first","diff":""}
        notify("item/started", dict(p,item={"type":"fileChange","id":"other","changes":[change]},itemId="other"))
        notify("item/fileChange/patchUpdated", dict(p,changes=[change]))
        change = {"kind":{"type":"update","move_path":"new"},"path":"old","diff":""}
        notify("item/fileChange/patchUpdated", dict(p,changes=[change]))
        assert read() == {"id":"file","result":{"decision":"accept"}}
        for i in [1,"1"]:
            send({"id":i,"method":"item/commandExecution/requestApproval","params":dict(p,kind="writeStdin",command=str(i),cwd="/tmp")})
        assert read() == {"id":1,"result":{"decision":"decline"}}
        notify("serverRequest/resolved", dict(threadId="t",requestId="1"))
        send({"id":"perm","method":"item/permissions/requestApproval","params":dict(p,permissions={"network":{"enabled":True}})})
        assert read() == {"id":"perm","result":{"permissions":{"network":{"enabled":True}},"scope":"turn"}}
        send({"id":44,"method":"other","params":{}})
        assert read()["error"]["code"] == -32601
        send({"id":45,"method":"mcpServer/elicitation/request","params":{}})
        assert read() == {"id":45,"result":{"action":"cancel"}}
        completed(1)
        """#)
        defer { try? server.remove() }
        let client = server.client()
        var events = client.events.makeAsyncIterator()
        _ = try await client.start(worktree: server.folder, settings: settings)
        _ = try await client.startTurn(threadID: "t", text: "1", settings: settings)
        var revisions: [ApprovalRequest] = []
        var commands: [ApprovalRequest] = []
        while let event = try await events.next() {
            switch event {
            case .approval(let request) where request.kind == .file:
                revisions.append(request)
                XCTAssertTrue(request.details.contains("Write access for this session: /workspace"))
                if revisions.count == 1 { XCTAssertFalse(request.canAllow) }
                if revisions.count == 3 {
                    XCTAssertEqual(revisions[1].changes.map(\.path), ["first"])
                    XCTAssertEqual(request.changes.map(\.summary), ["Update: old → new"])
                    do {
                        try await client.answer(revisions[1], allow: true)
                        XCTFail("Accepted an outdated target")
                    } catch {}
                    try await client.answer(request, allow: true)
                    do {
                        try await client.answer(request, allow: true)
                        XCTFail("Answered twice")
                    } catch {}
                }
            case .approval(let request) where request.kind == .command:
                commands.append(request)
                if commands.count == 2 {
                    XCTAssertNotEqual(request.id, commands[0].id)
                    XCTAssertEqual(request.key, commands[0].key)
                    try await client.answer(commands[0], allow: false)
                }
            case .resolved(_, let id): XCTAssertEqual(id, .string("1"))
            case .approval(let request):
                XCTAssertTrue(request.details.contains { $0.contains("network") })
                try await client.answer(request, allow: true)
            case .completed:
                await withinDeadline("Close session") { await client.close() }
                return
            default: break
            }
        }
        XCTFail()
    }

    func testFailureAndCloseWhileInitializing() async throws {
        for command in ["sys.exit(0)", "print('invalid',flush=True)", "time.sleep(60)"] {
            let server = try MockServer("read()\n" + command)
            defer { try? server.remove() }
            let client = server.client()
            let starting = Task { try await client.start(worktree: server.folder, settings: settings) }
            if command.hasPrefix("time") {
                try await Task.sleep(for: .milliseconds(100))
                await withinDeadline("Close session") { await client.close() }
            }
            do { _ = try await starting.value; XCTFail("Unexpected success") } catch {}
            await withinDeadline("Close session") { await client.close() }
        }
    }

    func testApprovalDescriptionsAndDecisions() throws {
        let key = ItemKey(thread: "t", turn: "1", item: "i")
        let connection: JSON = .object(["host": .string("example.test"), "protocol": .string("https")])
        func command(_ params: [String: JSON]) -> ApprovalRequest {
            ApprovalRequest(id: .integer(7), kind: .command, key: key, params: .object(params))
        }
        for kind in [nil, "command", "writeStdin"] {
            var params: [String: JSON] = ["networkApprovalContext": connection, "cwd": .string("/tmp")]
            params["kind"] = kind.map(JSON.string)
            XCTAssertTrue(command(params).canAllow)
            params["command"] = .string("input")
            let request = command(params)
            XCTAssertTrue(request.canAllow)
            XCTAssertTrue(request.details.contains("input"))
            XCTAssertTrue(request.details.contains("Connection: https://example.test"))
            XCTAssertEqual(request.title, kind == "writeStdin" ? "Send input to terminal" : "Run command")
        }
        for params: [String: JSON] in [[:], ["reason": .string("reason")], ["kind": .string("unknown"), "command": .string("cmd")]] {
            let request = command(params)
            XCTAssertFalse(request.canAllow)
            XCTAssertThrowsError(try request.result(allow: true))
            XCTAssertEqual(try request.result(allow: false)["decision"], .string("decline"))
        }
        let legacy = ApprovalRequest(id: .integer(8), kind: .legacyCommand, key: key, params: .object(["command": .array([.string("ls")])]))
        XCTAssertEqual(try legacy.result(allow: true)["decision"], .string("approved"))
        XCTAssertNotNil(try legacy.result(allow: false)["decision"]["denied"]["rejection"].text)
        let permission = ApprovalRequest(id: .integer(9), kind: .permissions, key: key, params: .object(["permissions": .object(["network": .object(["enabled": .bool(true)])])]))
        XCTAssertEqual(try permission.result(allow: false), .object(["permissions": .object([:]), "scope": .string("turn")]))
    }
}
