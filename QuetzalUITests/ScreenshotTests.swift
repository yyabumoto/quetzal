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

    func testNoRepository() {
        capture("no-repository") { app in
            [.exists(app.buttons["Open Repository…"]), .exists(app.staticTexts["Select a worktree in the sidebar."])]
        }
    }

    func testWorktreeSelected() {
        capture("worktree-selected") { app in
            [.exists(app.staticTexts["quetzal-sidebar"]), .enabled(app.buttons["Start Session"])]
        }
    }

    func testSessionInProgress() {
        let reply = "The empty state uses ContentUnavailableView with an Open Repository button. I'll add a test for it next."
        capture("session-in-progress") { app in
            [.exists(app.staticTexts[reply]), .exists(app.buttons["Send"]), .absent(app.buttons["Interrupt"])]
        }
    }

    func testPendingApproval() {
        capture("pending-approval") { app in
            [.enabled(app.buttons["Allow"]), .enabled(app.buttons["Interrupt"])]
        }
    }

    func testErrorNotice() {
        capture("error-notice") { app in
            [.exists(app.staticTexts["The Codex connection closed. Start a new session."]), .absent(app.buttons["Send"])]
        }
    }

    private func capture(_ scenario: String, until conditions: (XCUIApplication) -> [Condition]) {
        continueAfterFailure = false
        for appearance in ["light", "dark"] {
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
