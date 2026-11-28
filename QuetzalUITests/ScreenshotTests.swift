import XCTest

@MainActor
final class ScreenshotTests: XCTestCase {
    @MainActor
    private struct Condition {
        let holds: () -> Bool
        static func exists(_ element: XCUIElement) -> Self { Self { element.exists } }
        static func enabled(_ element: XCUIElement) -> Self { Self { element.exists && element.isEnabled } }
        static func absent(_ element: XCUIElement) -> Self { Self { !element.exists } }
    }

    private static let progressReply =
        "The empty state uses ContentUnavailableView with an Open Repository button. I'll add a test for it next."

    func testNoRepositoryLight() { captureNoRepository("light") }
    func testNoRepositoryDark() { captureNoRepository("dark") }
    func testWorktreeSelectedLight() { captureWorktreeSelected("light") }
    func testWorktreeSelectedDark() { captureWorktreeSelected("dark") }
    func testSessionInProgressLight() { captureSessionInProgress("light") }
    func testSessionInProgressDark() { captureSessionInProgress("dark") }
    func testPendingApprovalLight() { capturePendingApproval("light") }
    func testPendingApprovalDark() { capturePendingApproval("dark") }
    func testErrorNoticeLight() { captureErrorNotice("light") }
    func testErrorNoticeDark() { captureErrorNotice("dark") }

    private func captureNoRepository(_ appearance: String) {
        capture("no-repository", appearance) { app in
            [.exists(app.buttons["Open Repository…"]), .exists(app.staticTexts["Select a worktree in the sidebar."])]
        }
    }

    private func captureWorktreeSelected(_ appearance: String) {
        capture("worktree-selected", appearance) { app in
            [.exists(app.staticTexts["quetzal-sidebar"]), .enabled(app.buttons["Start Session"])]
        }
    }

    private func captureSessionInProgress(_ appearance: String) {
        capture("session-in-progress", appearance) { app in
            [.exists(app.staticTexts[Self.progressReply]), .exists(app.buttons["Send"]), .absent(app.buttons["Interrupt"])]
        }
    }

    private func capturePendingApproval(_ appearance: String) {
        capture("pending-approval", appearance) { app in
            [.enabled(app.buttons["Allow"]), .enabled(app.buttons["Interrupt"])]
        }
    }

    private func captureErrorNotice(_ appearance: String) {
        capture("error-notice", appearance) { app in
            [.exists(app.staticTexts["The Codex connection closed. Start a new session."]), .absent(app.buttons["Send"])]
        }
    }

    private func capture(_ scenario: String, _ appearance: String,
                         until conditions: (XCUIApplication) -> [Condition]) {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-fixture", scenario, "--ui-appearance", appearance,
                               "-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        XCTAssertTrue(waitUntilAll(conditions(app), timeout: 10),
                      "\(scenario)-\(appearance) did not reach its final state")
        let attachment = XCTAttachment(data: app.windows.firstMatch.screenshot().pngRepresentation,
                                       uniformTypeIdentifier: "public.png")
        attachment.name = "\(scenario)-\(appearance)"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.terminate()
    }

    // XCTNSPredicateExpectation stops evaluating a predicate once it holds, so separate
    // expectations could each be met at a different moment. Capture only after one pass
    // finds every condition true.
    private func waitUntilAll(_ conditions: [Condition], timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if conditions.allSatisfy({ $0.holds() }) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return conditions.allSatisfy { $0.holds() }
    }
}
