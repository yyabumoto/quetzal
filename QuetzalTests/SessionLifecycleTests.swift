import XCTest
@testable import Quetzal

extension XCTestCase {
    func withinDeadline(
        _ description: String, seconds: TimeInterval = 5,
        operation: @escaping @MainActor () async throws -> Void
    ) async {
        let finished = expectation(description: description)
        let task = Task { @MainActor in
            defer { finished.fulfill() }
            do { try await operation() }
            catch { XCTFail("\(description): \(error)") }
        }
        await fulfillment(of: [finished], timeout: seconds)
        task.cancel()
    }
}

@MainActor
final class SessionLifecycleTests: XCTestCase {
    func testIdleWindowsLeaveCapacityForStartSendAndClose() async {
        let strict = ProcessInfo.processInfo.environment["LIBDISPATCH_COOPERATIVE_POOL_STRICT"] ?? "default"
        await withinDeadline("Start, send, and close with cooperative pool setting \(strict)", seconds: 12) {
            let idle = try MockServer("start()\ntime.sleep(60)")
            let active = try MockServer("""
            start()
            req = turn(1)
            response(req,{"turn":{"id":"1"}})
            completed(1)
            """)
            defer { try? idle.remove(); try? active.remove() }
            let settings = ModelSettings(model: nil, effort: "high")
            var windows: [CodexClient] = []
            for _ in 0..<(ProcessInfo.processInfo.activeProcessorCount + 1) {
                let client = idle.client()
                windows.append(client)
                _ = try await client.start(worktree: idle.folder, settings: settings)
            }
            let client = active.client()
            _ = try await client.start(worktree: active.folder, settings: settings)
            let turn = try await client.startTurn(threadID: "t", text: "1", settings: settings)
            XCTAssertEqual(turn, "1")
            await client.close()
            for window in windows { await window.close() }
        }
    }

    func testChangedDefaultsAndPerFieldOverridesReachTheServer() async throws {
        let suite = UUID().uuidString
        let store = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { store.removePersistentDomain(forName: suite) }
        let original = ModelSettings(model: "first", effort: "low")
        original.save(for: .codex, store: store)
        var draft = SessionSettingsDraft()
        XCTAssertEqual(draft.settings(defaultModel: "first", defaultEffort: "low"), original)
        let changed = ModelSettings(model: "updated", effort: "high")
        changed.save(for: .codex, store: store)
        let cases: [(String?, String?, String, String)] = [
            (nil, nil, #"{"model":"updated","config":{"model_reasoning_effort":"high"}}"#, #"{"model":"updated","effort":"high"}"#),
            ("custom", nil, #"{"model":"custom","config":{"model_reasoning_effort":"high"}}"#, #"{"model":"custom","effort":"high"}"#),
            (nil, "low", #"{"model":"updated","config":{"model_reasoning_effort":"low"}}"#, #"{"model":"updated","effort":"low"}"#),
            ("", nil, #"{"config":{"model_reasoning_effort":"high"}}"#, #"{"effort":"high"}"#),
            (nil, "", #"{"model":"updated"}"#, #"{"model":"updated"}"#)
        ]
        for (model, effort, threadOptions, turnOptions) in cases {
            draft.model = model
            draft.effort = effort
            let settings = draft.settings(defaultModel: store.string(forKey: Provider.codex.key("model")) ?? "",
                                          defaultEffort: store.string(forKey: Provider.codex.key("effort")) ?? "")
            let server = try MockServer("""
            start(\(threadOptions))
            req = read()
            assert req["params"] == dict(\(turnOptions),threadId="t",input=[{"type":"text","text":"1"}])
            response(req,{"turn":{"id":"1"}})
            """)
            defer { try? server.remove() }
            let client = server.client()
            _ = try await client.start(worktree: server.folder, settings: settings)
            _ = try await client.startTurn(threadID: "t", text: "1", settings: settings)
            await withinDeadline("Close after server exit") { await client.close() }
            XCTAssertEqual(ModelSettings.defaults(for: .codex, store: store), changed)
        }
    }

    func testClaudeDefaultsAndOverridesReachTheCLI() async throws {
        let suite = UUID().uuidString
        let store = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { store.removePersistentDomain(forName: suite) }
        let changed = ModelSettings(model: "updated", effort: "high")
        changed.save(for: .claudeCode, store: store)
        var draft = SessionSettingsDraft()
        let cases: [(String?, String?, String, String)] = [
            (nil, nil, #""updated""#, #""high""#),
            ("custom", nil, #""custom""#, #""high""#),
            (nil, "low", #""updated""#, #""low""#),
            ("", nil, "None", #""high""#),
            (nil, "", #""updated""#, "None")
        ]
        for (model, effort, expectedModel, expectedEffort) in cases {
            draft.model = model
            draft.effort = effort
            let settings = draft.settings(defaultModel: store.string(forKey: Provider.claudeCode.key("model")) ?? "",
                                          defaultEffort: store.string(forKey: Provider.claudeCode.key("effort")) ?? "")
            let server = try ClaudeMockServer("start(model=\(expectedModel), effort=\(expectedEffort))\nwait()")
            defer { try? server.remove() }
            let client = server.client()
            _ = try await client.start(worktree: server.folder, settings: settings)
            await withinDeadline("Close session") { await client.close() }
            XCTAssertEqual(ModelSettings.defaults(for: .claudeCode, store: store), changed)
        }
    }
}
