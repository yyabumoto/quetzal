#if DEBUG
import SwiftUI

struct UIFixture: Equatable {
    enum Scenario: String, CaseIterable {
        case noRepository = "no-repository"
        case worktreeSelected = "worktree-selected"
        case sessionInProgress = "session-in-progress"
        case pendingApproval = "pending-approval"
        case errorNotice = "error-notice"
    }

    enum Appearance: String, CaseIterable {
        case light, dark
    }

    let scenario: Scenario
    let appearance: Appearance

    /// nil when `arguments` has no `--ui-fixture`. Stops the app with `fatalError` when a value is missing or unknown.
    init?(arguments: [String]) {
        guard let scenario = Self.value(of: "--ui-fixture", in: arguments, as: Scenario.self) else { return nil }
        self.scenario = scenario
        appearance = Self.value(of: "--ui-appearance", in: arguments, as: Appearance.self) ?? .light
    }

    private static func value<Value: RawRepresentable & CaseIterable>(
        of option: String, in arguments: [String], as _: Value.Type
    ) -> Value? where Value.RawValue == String {
        guard let index = arguments.firstIndex(of: option) else { return nil }
        let expected = Value.allCases.map(\.rawValue).joined(separator: ", ")
        guard index + 1 < arguments.count else { fatalError("Missing \(option) value. Expected one of \(expected).") }
        let raw = arguments[index + 1]
        guard let value = Value(rawValue: raw) else { fatalError("Unknown \(option) value: \(raw). Expected one of \(expected).") }
        return value
    }

    static let windowSize = CGSize(width: 960, height: 640)

    static let folder = URL(fileURLWithPath: "/Users/example/Developer/quetzal", isDirectory: true)
    static let sidebarWorktree = URL(fileURLWithPath: "/Users/example/Developer/quetzal-sidebar", isDirectory: true)
    static let settings = ModelSettings(model: "gpt-5.5", effort: "medium")

    static let repository = RepositoryWorktrees(
        openedFolder: folder,
        identity: GitRepositoryIdentity(commonDirectory: folder.appendingPathComponent(".git", isDirectory: true),
                                        device: 1, inode: 1),
        entries: [GitWorktree(directory: folder, isPrunable: false),
                  GitWorktree(directory: sidebarWorktree, isPrunable: false)],
        mainLocation: .confirmed
    )

    /// `@AppStorage` store for fixture windows, so screenshots show the same saved model and effort
    /// on every machine and nothing the fixture does writes the user's settings.
    static let defaults: UserDefaults = {
        let name = "com.github.yyabumoto.Quetzal.ui-fixture"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        defaults.set(settings.model, forKey: Provider.codex.key("model"))
        defaults.set(settings.effort, forKey: Provider.codex.key("effort"))
        return defaults
    }()

    static let firstPrompt = "Summarize the open issues in this repository."
    static let firstReply = "There are three open issues: the sidebar empty state, the status line layout, and screenshot capture."
    static let progressPrompt = "Start with the sidebar empty state."
    static let progressReply = "The empty state uses ContentUnavailableView with an Open Repository button. I'll add a test for it next."
    static let approvalPrompt = "Run the unit tests."
    static let approvalReply = "I'll run the unit tests first."
    static let approvalParams: JSON = .object([
        "command": .string("xcodebuild test -scheme Quetzal"),
        "cwd": .string(folder.path),
        "reason": .string("Run the unit tests")
    ])

    private var exchanges: [(prompt: String, turn: FixtureTurn)] {
        let first = (Self.firstPrompt, FixtureTurn(reply: Self.firstReply))
        switch scenario {
        case .noRepository, .worktreeSelected:
            return []
        case .sessionInProgress:
            return [first, (Self.progressPrompt, FixtureTurn(reply: Self.progressReply))]
        case .pendingApproval:
            return [first, (Self.approvalPrompt, FixtureTurn(reply: Self.approvalReply, approval: Self.approvalParams))]
        case .errorNotice:
            return [first]
        }
    }

    var colorScheme: ColorScheme {
        switch appearance {
        case .light: .light
        case .dark: .dark
        }
    }

    func makeSession() -> ChatSession {
        let turns = exchanges.map(\.turn)
        let disconnect = scenario == .errorNotice ? CodexFailure.disconnected.message : nil
        return ChatSession(namer: .fallbackOnly) { _, _ in FixtureAgentClient(turns: turns, disconnectAfterLastTurn: disconnect) }
    }

    func makeSidebar() -> WorktreeSidebarModel {
        let repository = Self.repository
        return WorktreeSidebarModel { _ in repository }
    }

    /// Drives the real models into `scenario` and returns once its final state is reached or 5 seconds pass.
    func prepare(session: ChatSession, worktreeStart: WorktreeSessionStart, sidebar: WorktreeSidebarModel) async {
        guard scenario != .noRepository else { return }
        let deadline = ContinuousClock.now + .seconds(5)
        await sidebar.open(Self.folder).value
        guard case .loaded(let repository) = sidebar.contents,
              let target = repository.target(for: .worktree(Self.folder)) else { return }
        worktreeStart.request(target, sessionActive: false)
        guard scenario != .worktreeSelected else { return }

        await session.start(worktree: Self.folder, settings: Self.settings,
                            executable: URL(fileURLWithPath: "/usr/bin/false"), provider: .codex)
        for exchange in exchanges {
            guard await wait(until: deadline, for: { session.phase == .ready }) else { return }
            await session.send(exchange.prompt)
        }
        _ = await wait(until: deadline) {
            switch scenario {
            case .noRepository, .worktreeSelected: true
            case .sessionInProgress: session.phase == .ready && session.messages.count == 4
            case .pendingApproval: session.phase == .running && session.approvals.count == 1
            case .errorNotice: session.phase == .disconnected
            }
        }
    }

    private func wait(until deadline: ContinuousClock.Instant, for condition: () -> Bool) async -> Bool {
        while !condition() {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }
}

nonisolated struct FixtureTurn: Sendable {
    let reply: String
    /// Params of a command approval. When set, the turn stays running with this approval pending.
    var approval: JSON? = nil
}

actor FixtureAgentClient: AgentClient {
    nonisolated let events: AsyncThrowingStream<AgentEvent, Error>
    private let continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
    private let turns: [FixtureTurn]
    private let disconnectAfterLastTurn: String?
    private var sent = 0

    init(turns: [FixtureTurn], disconnectAfterLastTurn: String?) {
        (events, continuation) = AsyncThrowingStream.makeStream()
        self.turns = turns
        self.disconnectAfterLastTurn = disconnectAfterLastTurn
    }

    func start(worktree: URL, settings: ModelSettings) async throws -> String {
        "fixture-thread"
    }

    func startTurn(threadID: String, text: String, settings: ModelSettings) async throws -> String {
        guard sent < turns.count else { throw CodexFailure("The fixture has no reply for this message.") }
        let turn = turns[sent]
        sent += 1
        let id = "turn-\(sent)"
        continuation.yield(.message(ItemKey(thread: threadID, turn: id, item: "reply"), text: turn.reply, final: true))
        if let approval = turn.approval {
            let key = ItemKey(thread: threadID, turn: id, item: "command")
            continuation.yield(.approval(ApprovalRequest(id: .string("approval-\(sent)"), kind: .command,
                                                         key: key, params: approval)))
        } else {
            continuation.yield(.completed(thread: threadID, turn: id, status: "completed", error: nil))
        }
        if sent == turns.count, let disconnectAfterLastTurn {
            continuation.finish(throwing: CodexFailure(disconnectAfterLastTurn))
        }
        return id
    }

    func interrupt(threadID: String, turnID: String) async throws {}

    func answer(_ request: ApprovalRequest, allow: Bool) async throws {}

    func close() async {
        continuation.finish()
    }
}

struct UIFixtureRoot: View {
    let fixture: UIFixture
    @State private var session: ChatSession
    @State private var worktreeStart = WorktreeSessionStart()
    @State private var sidebar: WorktreeSidebarModel

    init(fixture: UIFixture) {
        self.fixture = fixture
        _session = State(initialValue: fixture.makeSession())
        _sidebar = State(initialValue: fixture.makeSidebar())
    }

    var body: some View {
        ContentView(session: session, worktreeStart: worktreeStart, sidebar: sidebar)
            .task { await fixture.prepare(session: session, worktreeStart: worktreeStart, sidebar: sidebar) }
            .defaultAppStorage(UIFixture.defaults)
            .preferredColorScheme(fixture.colorScheme)
            .frame(width: UIFixture.windowSize.width, height: UIFixture.windowSize.height)
    }
}
#endif
