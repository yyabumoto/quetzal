import XCTest
@testable import Quetzal

final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value { lock.withLock { stored } }

    func update<Result>(_ body: (inout Value) -> Result) -> Result { lock.withLock { body(&stored) } }
}

final class WorkNamerTests: XCTestCase {
    private let executable = URL(fileURLWithPath: "/usr/bin/false")
    private let date = Date(timeIntervalSince1970: 0)

    func testProposalBecomesGeneratedNames() async throws {
        let namer = WorkNamer(now: { [date] in date }, propose: { _ in
            NameProposal(type: "fix", slug: "login-error", title: "Login")
        })
        let names = try await namer.names(for: "fix it", provider: .codex, executable: executable)
        XCTAssertEqual(names.origin, .generated)
        XCTAssertEqual(names.branch, "fix/login-error")
        XCTAssertEqual(names.session, "Login")
    }

    func testFailureFallsBack() async throws {
        let namer = WorkNamer(now: { [date] in date }, propose: { _ in throw NamingFailure.exit(1) })
        let names = try await namer.names(for: "fix it", provider: .codex, executable: executable)
        XCTAssertEqual(names, NameFormat.fallback(message: "fix it", date: date))
    }

    func testTimeoutFallsBackAndCancelsProposal() async throws {
        let cancelled = Locked(false)
        let namer = WorkNamer(timeout: .milliseconds(50), propose: { _ in
            try await withTaskCancellationHandler {
                try await Task.sleep(for: .seconds(30))
                return NameProposal(type: "fix", slug: "late", title: "Late")
            } onCancel: {
                cancelled.update { $0 = true }
            }
        })
        let started = ContinuousClock.now
        let names = try await namer.names(for: "fix it", provider: .codex, executable: executable)
        XCTAssertEqual(names.origin, .fallback)
        XCTAssertTrue(cancelled.value)
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(5))
    }

    func testCallerCancellationThrows() async throws {
        let started = Locked(false)
        let namer = WorkNamer(propose: { _ in
            started.update { $0 = true }
            try await Task.sleep(for: .seconds(30))
            return NameProposal(type: "fix", slug: "late", title: "Late")
        })
        let executable = executable
        let task = Task { try await namer.names(for: "fix it", provider: .codex, executable: executable) }
        while !started.value { try await Task.sleep(for: .milliseconds(10)) }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("\(error)")
        }
    }

    func testModelForProviderReachesRequest() async throws {
        let requests = Locked<[NamingRequest]>([])
        let namer = WorkNamer(model: { $0 == .claudeCode ? "haiku" : "gpt" }, propose: { request in
            requests.update { $0.append(request) }
            throw NamingFailure.malformed
        })
        _ = try await namer.names(for: "a", provider: .claudeCode, executable: executable)
        _ = try await namer.names(for: "b", provider: .codex, executable: executable)
        XCTAssertEqual(requests.value.map(\.model), ["haiku", "gpt"])
        XCTAssertEqual(requests.value.map(\.provider), [.claudeCode, .codex])
        XCTAssertEqual(requests.value.first?.prompt, NameFormat.prompt(for: "a"))
        XCTAssertEqual(requests.value.first?.executable, executable)
    }
}
