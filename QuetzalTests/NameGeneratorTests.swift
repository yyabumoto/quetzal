import XCTest
@testable import Quetzal

/// 受け取った引数・stdin・作業フォルダ・PATH・pid を calls/ に書き出してから、program のとおりに振る舞う偽の CLI。
private struct FakeNamingCLI {
    struct Call: Decodable {
        let args: [String]
        let stdin: String
        let cwd: String
        let entries: [String]
        let path: String
        let pid: Int32
        let schema: String?
    }

    let folder: URL
    let executable: URL

    init(_ name: String, ignoreTerm: Bool = false, _ program: String) throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("calls"), withIntermediateDirectories: true)
        executable = folder.appendingPathComponent(name)
        let source = """
        #!/usr/bin/python3
        import json, os, signal, sys, time
        \(ignoreTerm ? "signal.signal(signal.SIGTERM, signal.SIG_IGN)" : "")
        signal.alarm(30)
        args = sys.argv[1:]
        record = {"args": args, "stdin": sys.stdin.read(), "cwd": os.getcwd(), "entries": os.listdir("."),
                  "path": os.environ.get("PATH", ""), "pid": os.getpid(), "schema": None}
        if "--output-schema" in args:
            record["schema"] = open(args[args.index("--output-schema") + 1]).read()
        calls = os.path.join(os.environ["FAKE_DIR"], "calls")
        name = os.path.join(calls, str(time.time_ns()))
        with open(name + ".tmp", "w") as f:
            json.dump(record, f)
        os.rename(name + ".tmp", name + ".json")
        def write_output(value):
            with open(args[args.index("-o") + 1], "w") as f:
                json.dump(value, f)
        """ + "\n" + program
        try Data(source.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }

    var generator: NameGenerator {
        NameGenerator(environment: ["PATH": "/usr/bin:/bin", "FAKE_DIR": folder.path])
    }

    func request(_ provider: Provider, model: String? = nil) -> NamingRequest {
        NamingRequest(prompt: "Name this\n<request>\nfix it\n</request>", provider: provider,
                      executable: executable, model: model)
    }

    func calls() throws -> [Call] {
        let directory = folder.appendingPathComponent("calls")
        return try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".json") }.sorted()
            .map { try JSONDecoder().decode(Call.self, from: Data(contentsOf: directory.appendingPathComponent($0))) }
    }

    func remove() throws { try FileManager.default.removeItem(at: folder) }
}

final class NameGeneratorTests: XCTestCase {
    private let claudeResult = #"print(json.dumps({"type":"result","structured_output":{"type":"fix","slug":"login-error","title":"Login"}}))"#
    private let proposal = NameProposal(type: "fix", slug: "login-error", title: "Login")

    private func waitForCalls(_ cli: FakeNamingCLI, count: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while try cli.calls().count < count {
            guard ContinuousClock.now < deadline else { throw NamingFailure.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func assertTemporaryWorkFolder(_ call: FakeNamingCLI.Call, file: StaticString = #filePath, line: UInt = #line) {
        // getcwd は実パス（/private/var/…）を返すので、一時フォルダも realpath で比べる。
        let temporary = realpath(FileManager.default.temporaryDirectory.path, nil).map {
            defer { free($0) }
            return String(cString: $0)
        } ?? ""
        XCTAssertTrue(call.cwd.hasPrefix(temporary + "/"), call.cwd, file: file, line: line)
        XCTAssertEqual(call.entries, [], file: file, line: line)
        XCTAssertFalse(FileManager.default.fileExists(atPath: call.cwd), file: file, line: line)
        XCTAssertFalse(FileManager.default.fileExists(atPath: URL(fileURLWithPath: call.cwd).deletingLastPathComponent().path),
                       file: file, line: line)
    }

    private func assertFailure(_ expected: NamingFailure, file: StaticString = #filePath, line: UInt = #line,
                               _ operation: () async throws -> NameProposal) async {
        do {
            _ = try await operation()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch let failure as NamingFailure {
            XCTAssertEqual(failure, expected, file: file, line: line)
        } catch {
            XCTFail("\(error)", file: file, line: line)
        }
    }

    func testClaudeReturnsStructuredOutput() async throws {
        let cli = try FakeNamingCLI("claude", claudeResult)
        defer { try? cli.remove() }
        let request = cli.request(.claudeCode, model: "haiku")
        let result = try await cli.generator.propose(request)
        XCTAssertEqual(result, proposal)
        let call = try XCTUnwrap(cli.calls().first)
        XCTAssertEqual(call.args, [
            "-p", "--output-format", "json", "--json-schema", NameFormat.schema, "--tools", "", "--safe-mode",
            "--strict-mcp-config", "--no-session-persistence", "--permission-prompts", "none", "--model", "haiku"
        ])
        XCTAssertFalse(call.args.contains("--bare"))
        XCTAssertFalse(call.args.contains("--effort"))
        XCTAssertEqual(call.stdin, request.prompt)
        XCTAssertEqual(call.path, cli.folder.path + ":/usr/bin:/bin")
        assertTemporaryWorkFolder(call)
    }

    func testClaudeWithoutModelOmitsModelArgument() async throws {
        let cli = try FakeNamingCLI("claude", claudeResult)
        defer { try? cli.remove() }
        _ = try await cli.generator.propose(cli.request(.claudeCode))
        XCTAssertFalse(try XCTUnwrap(cli.calls().first).args.contains("--model"))
    }

    func testClaudeFailures() async throws {
        let missing = try FakeNamingCLI("claude", #"print(json.dumps({"type":"result","result":"no"}))"#)
        let failed = try FakeNamingCLI("claude", #"print(json.dumps({"type":"result","is_error":True}))"# + "\nsys.exit(1)")
        let notJSON = try FakeNamingCLI("claude", #"print("oops")"#)
        defer { try? missing.remove(); try? failed.remove(); try? notJSON.remove() }
        await assertFailure(.malformed) { try await missing.generator.propose(missing.request(.claudeCode)) }
        await assertFailure(.exit(1)) { try await failed.generator.propose(failed.request(.claudeCode)) }
        await assertFailure(.malformed) { try await notJSON.generator.propose(notJSON.request(.claudeCode)) }
    }

    func testLaunchFailure() async throws {
        let request = NamingRequest(prompt: "p", provider: .claudeCode,
                                    executable: URL(fileURLWithPath: "/nonexistent/claude"), model: nil)
        await assertFailure(.launch) { try await NameGenerator().propose(request) }
    }

    func testCodexDisablesEnabledServersAndReadsOutputFile() async throws {
        let cli = try FakeNamingCLI("codex", #"""
        if args[-3:] == ["mcp", "list", "--json"]:
            print(json.dumps([{"name":"a","enabled":True},{"name":"b","enabled":False},{"name":"c.d","enabled":True}]))
            sys.exit(0)
        write_output({"type":"fix","slug":"login-error","title":"Login"})
        print("final message")
        """#)
        defer { try? cli.remove() }
        let request = cli.request(.codex, model: "gpt-test")
        let result = try await cli.generator.propose(request)
        XCTAssertEqual(result, proposal)
        let calls = try cli.calls()
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].args, ["--disable", "plugins", "--disable", "apps", "mcp", "list", "--json"])
        XCTAssertEqual(calls[0].stdin, "")
        let exec = calls[1]
        let schema = try XCTUnwrap(exec.args.firstIndex(of: "--output-schema"))
        let output = try XCTUnwrap(exec.args.firstIndex(of: "-o"))
        XCTAssertEqual(exec.args, [
            "exec", "--ephemeral", "--skip-git-repo-check", "--sandbox", "read-only", "--color", "never",
            "--ignore-rules", "--disable", "hooks", "--disable", "plugins", "--disable", "apps",
            "-c", "mcp_servers.a.enabled=false",
            "--output-schema", exec.args[schema + 1], "-o", exec.args[output + 1],
            "-c", #"approval_policy="never""#, "-c", "features.shell_tool=false", "-c", "project_doc_max_bytes=0",
            "-c", #"model_reasoning_effort="low""#, "-m", "gpt-test", "-"
        ])
        XCTAssertEqual(exec.schema, NameFormat.schema)
        XCTAssertEqual(exec.stdin, request.prompt)
        XCTAssertEqual(exec.path, cli.folder.path + ":/usr/bin:/bin")
        assertTemporaryWorkFolder(calls[0])
        assertTemporaryWorkFolder(exec)
    }

    func testCodexServerListFailureStillNames() async throws {
        for list in ["sys.exit(1)", #"print("not json"); sys.exit(0)"#] {
            let cli = try FakeNamingCLI("codex", """
            if args[-3:] == ["mcp", "list", "--json"]:
                \(list)
            write_output({"type":"fix","slug":"login-error","title":"Login"})
            """)
            defer { try? cli.remove() }
            let result = try await cli.generator.propose(cli.request(.codex))
            XCTAssertEqual(result, proposal)
            let calls = try cli.calls()
            XCTAssertEqual(calls.count, 2)
            XCTAssertFalse(calls[1].args.contains { $0.hasPrefix("mcp_servers.") })
            XCTAssertFalse(calls[1].args.contains("-m"))
        }
    }

    func testCodexWithoutOutputFileIsMalformed() async throws {
        let cli = try FakeNamingCLI("codex", #"""
        if args[-3:] == ["mcp", "list", "--json"]:
            print("[]")
        """#)
        defer { try? cli.remove() }
        await assertFailure(.malformed) { try await cli.generator.propose(cli.request(.codex)) }
    }

    func testCancelDuringCodexServerListSkipsExec() async throws {
        let cli = try FakeNamingCLI("codex", "time.sleep(30)")
        defer { try? cli.remove() }
        let generator = cli.generator, request = cli.request(.codex)
        let task = Task { try await generator.propose(request) }
        try await waitForCalls(cli, count: 1)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("\(error)")
        }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(try cli.calls().count, 1)
    }

    func testCancelBeforeLaunchDoesNotStartCLI() async throws {
        let cli = try FakeNamingCLI("claude", claudeResult)
        defer { try? cli.remove() }
        let generator = cli.generator, request = cli.request(.claudeCode)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await generator.propose(request)
        }
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("\(error)")
        }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(try cli.calls().count, 0)
    }

    func testCancelAfterLaunchStopsAndReapsChild() async throws {
        for ignoreTerm in [false, true] {
            let cli = try FakeNamingCLI("claude", ignoreTerm: ignoreTerm, "time.sleep(30)")
            defer { try? cli.remove() }
            let generator = cli.generator, request = cli.request(.claudeCode)
            let task = Task { try await generator.propose(request) }
            try await waitForCalls(cli, count: 1)
            let call = try XCTUnwrap(cli.calls().first)
            let started = ContinuousClock.now
            task.cancel()
            do {
                _ = try await task.value
                XCTFail("Expected cancellation")
            } catch is CancellationError {
            } catch {
                XCTFail("\(error)")
            }
            XCTAssertEqual(kill(call.pid, 0), -1)
            XCTAssertEqual(errno, ESRCH)
            let elapsed = ContinuousClock.now - started
            assertTemporaryWorkFolder(call)
            if ignoreTerm {
                XCTAssertGreaterThan(elapsed, .milliseconds(1500))
                XCTAssertLessThan(elapsed, .seconds(4))
            } else {
                XCTAssertLessThan(elapsed, .seconds(1))
            }
        }
    }

    func testEnabledServers() {
        let json = Data(#"[{"name":"a_b-1","enabled":true},{"name":"off","enabled":false},{"name":"c.d","enabled":true},{"name":"","enabled":true},{"enabled":true}]"#.utf8)
        XCTAssertEqual(NamingCLI.enabledServers(in: json), ["a_b-1"])
        XCTAssertEqual(NamingCLI.enabledServers(in: Data("{}".utf8)), [])
        XCTAssertEqual(NamingCLI.enabledServers(in: Data("oops".utf8)), [])
    }
}
