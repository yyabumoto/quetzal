#if DEBUG
import XCTest
@testable import Quetzal

@MainActor
final class UIFixtureTests: XCTestCase {
    private struct Models {
        let session: ChatSession
        let worktreeStart: WorktreeSessionStart
        let sidebar: WorktreeSidebarModel
    }

    private func fixture(_ scenario: UIFixture.Scenario) -> UIFixture {
        UIFixture(arguments: ["/path/Quetzal", "--ui-fixture", scenario.rawValue])!
    }

    private func prepared(_ scenario: UIFixture.Scenario) async -> Models {
        let fixture = fixture(scenario)
        let models = Models(session: fixture.makeSession(), worktreeStart: WorktreeSessionStart(),
                            sidebar: fixture.makeSidebar())
        await fixture.prepare(session: models.session, worktreeStart: models.worktreeStart, sidebar: models.sidebar)
        return models
    }

    private func entries(_ sidebar: WorktreeSidebarModel) -> [URL]? {
        guard case .loaded(let repository) = sidebar.contents else { return nil }
        return repository.entries.map(\.directory)
    }

    func testNoFixtureArgumentIsANormalLaunch() {
        XCTAssertNil(UIFixture(arguments: ["/path/Quetzal"]))
    }

    func testScenarioDefaultsToLightAppearance() {
        let fixture = UIFixture(arguments: ["/path/Quetzal", "--ui-fixture", "pending-approval"])
        XCTAssertEqual(fixture?.scenario, .pendingApproval)
        XCTAssertEqual(fixture?.appearance, .light)
    }

    func testScenarioAndAppearance() {
        let fixture = UIFixture(arguments: ["/path/Quetzal", "--ui-fixture", "error-notice", "--ui-appearance", "dark"])
        XCTAssertEqual(fixture?.scenario, .errorNotice)
        XCTAssertEqual(fixture?.appearance, .dark)
    }

    func testArgumentsInAnyOrderAmongAppleArguments() {
        let fixture = UIFixture(arguments: ["/path/Quetzal", "-ApplePersistenceIgnoreState", "YES",
                                            "--ui-appearance", "dark", "--ui-fixture", "worktree-selected"])
        XCTAssertEqual(fixture, UIFixture(arguments: ["/path/Quetzal", "--ui-fixture", "worktree-selected",
                                                      "--ui-appearance", "dark"]))
        XCTAssertEqual(fixture?.scenario, .worktreeSelected)
        XCTAssertEqual(fixture?.appearance, .dark)
    }

    func testEveryScenarioParses() {
        for scenario in UIFixture.Scenario.allCases {
            XCTAssertEqual(UIFixture(arguments: ["/path/Quetzal", "--ui-fixture", scenario.rawValue])?.scenario, scenario)
        }
    }

    func testNoRepository() async {
        let models = await prepared(.noRepository)
        guard case .empty = models.sidebar.contents else { return XCTFail("The sidebar must stay empty.") }
        XCTAssertNil(models.worktreeStart.target)
        XCTAssertEqual(models.session.phase, .setup)
    }

    func testWorktreeSelected() async {
        let models = await prepared(.worktreeSelected)
        XCTAssertEqual(entries(models.sidebar), [UIFixture.folder, UIFixture.sidebarWorktree])
        XCTAssertEqual(models.worktreeStart.selectedItem, .worktree(UIFixture.folder))
        XCTAssertTrue(models.worktreeStart.canStart)
        XCTAssertEqual(models.session.phase, .setup)
    }

    func testSessionInProgress() async {
        let models = await prepared(.sessionInProgress)
        let session = models.session
        XCTAssertEqual(session.phase, .ready)
        XCTAssertEqual(session.messages.map(\.author), [.user, .codex, .user, .codex])
        XCTAssertEqual(session.messages.map(\.text), [UIFixture.firstPrompt, UIFixture.firstReply,
                                                      UIFixture.progressPrompt, UIFixture.progressReply])
        XCTAssertTrue(session.approvals.isEmpty)
        XCTAssertNil(session.notice)
        XCTAssertEqual(session.settings, ModelSettings(model: "gpt-5.5", effort: "medium"))
        XCTAssertEqual(session.worktree, UIFixture.folder)
        await session.close()
    }

    func testPendingApproval() async {
        let models = await prepared(.pendingApproval)
        let session = models.session
        XCTAssertEqual(session.phase, .running)
        XCTAssertEqual(session.messages.map(\.text), [UIFixture.firstPrompt, UIFixture.firstReply,
                                                      UIFixture.approvalPrompt, UIFixture.approvalReply])
        XCTAssertEqual(session.approvals.count, 1)
        XCTAssertEqual(session.approvals.first?.title, "Run command")
        XCTAssertEqual(session.approvals.first?.canAllow, true)
        XCTAssertTrue(session.canInterrupt)
        await session.close()
    }

    func testErrorNotice() async {
        let models = await prepared(.errorNotice)
        let session = models.session
        XCTAssertEqual(session.phase, .disconnected)
        XCTAssertEqual(session.messages.map(\.text), [UIFixture.firstPrompt, UIFixture.firstReply])
        XCTAssertEqual(session.notice, CodexFailure.disconnected.message)
        XCTAssertTrue(session.approvals.isEmpty)
        await session.close()
    }

    func testMessageBeyondTheScriptRestoresTheDraft() async {
        let models = await prepared(.sessionInProgress)
        let session = models.session
        await session.send("One more")
        XCTAssertEqual(session.phase, .ready)
        XCTAssertEqual(session.draft, "One more")
        XCTAssertEqual(session.notice, "The fixture has no reply for this message.")
        XCTAssertEqual(session.messages.count, 4)
        await session.close()
    }
}
#endif
