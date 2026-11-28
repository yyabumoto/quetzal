import XCTest
@testable import Quetzal

final class WorkNamingTests: XCTestCase {
    private let date = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: .current,
                                      year: 2026, month: 11, day: 25, hour: 14, minute: 30, second: 0).date!

    private func names(_ description: String, type: BranchType = .feat) -> WorkNames {
        WorkNames(session: "Session", type: type, prefix: type.rawValue, description: description, origin: .generated)
    }

    private func assertValidBranch(_ branch: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["check-ref-format", "--branch", branch]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, branch, file: file, line: line)
    }

    func testSlug() {
        XCTAssertEqual(NameFormat.slug("Fix Login"), "fix-login")
        XCTAssertEqual(NameFormat.slug("add_user  profile!page"), "add-user-profile-page")
        XCTAssertEqual(NameFormat.slug("--a---b--"), "a-b")
        XCTAssertEqual(NameFormat.slug("Café ＡＢＣ"), "cafe-abc")
        XCTAssertNil(NameFormat.slug("ログイン画面"))
        XCTAssertNil(NameFormat.slug("-_ !"))
        let words = "alpha-bravo-charlie-delta-echo-foxtrot-golf"
        XCTAssertEqual(NameFormat.slug(words), "alpha-bravo-charlie-delta-echo-foxtrot")
        XCTAssertEqual(NameFormat.slug(String(repeating: "a", count: 45)), String(repeating: "a", count: 40))
        let exact = String(repeating: "a", count: 40) + "-tail"
        XCTAssertEqual(NameFormat.slug(exact), String(repeating: "a", count: 40))
    }

    func testSessionTitle() {
        XCTAssertEqual(NameFormat.sessionTitle(" Fix\nthe\tlogin  bug "), "Fix the login bug")
        XCTAssertEqual(NameFormat.sessionTitle("a\u{7}b\u{0}c"), "abc")
        XCTAssertNil(NameFormat.sessionTitle(" \n\t "))
        let family = "👨‍👩‍👧"
        let title = NameFormat.sessionTitle(String(repeating: "あ", count: 39) + family + "x")
        XCTAssertEqual(title, String(repeating: "あ", count: 39) + family)
        let accented = String(repeating: "e\u{301}", count: 41)
        XCTAssertEqual(NameFormat.sessionTitle(accented), String(repeating: "e\u{301}", count: 40))
    }

    func testBranchTypeProposal() {
        XCTAssertEqual(BranchType(proposal: "feature"), .feat)
        XCTAssertEqual(BranchType(proposal: "BugFix"), .fix)
        XCTAssertEqual(BranchType(proposal: "chore"), .chore)
        XCTAssertNil(BranchType(proposal: "docs"))
    }

    func testNamesFromProposal() {
        let message = "\n  ログインのエラーを直して\n詳細"
        let good = NameFormat.names(from: NameProposal(type: "fix", slug: "login-error", title: "ログインのエラー"),
                                    message: message, date: date)
        XCTAssertEqual(good, WorkNames(session: "ログインのエラー", type: .fix, prefix: "fix",
                                       description: "login-error", origin: .generated))
        XCTAssertEqual(good.branch, "fix/login-error")
        XCTAssertEqual(good.worktree, "login-error")

        let noTitle = NameFormat.names(from: NameProposal(type: "fix", slug: "login-error", title: " "),
                                       message: message, date: date)
        XCTAssertEqual(noTitle.session, "ログインのエラーを直して")
        XCTAssertEqual(noTitle.origin, .generated)

        let noSlug = NameFormat.names(from: NameProposal(type: "fix", slug: "ログイン", title: "t"),
                                      message: message, date: date)
        XCTAssertEqual(noSlug.branch, "fix/session-20261125-143000")
        XCTAssertEqual(noSlug.origin, .generated)

        let badType = NameFormat.names(from: NameProposal(type: "docs", slug: "readme", title: "t"),
                                       message: message, date: date)
        XCTAssertEqual(badType.branch, "feat/readme")
        XCTAssertEqual(badType.origin, .generated)
    }

    func testFallback() {
        let fallback = NameFormat.fallback(message: "\n \nFirst line\nSecond", date: date)
        XCTAssertEqual(fallback, WorkNames(session: "First line", type: .feat, prefix: "feat",
                                           description: "session-20261125-143000", origin: .fallback))
        XCTAssertEqual(fallback.branch, "feat/session-20261125-143000")
        XCTAssertEqual(fallback.worktree, "session-20261125-143000")
        XCTAssertEqual(NameFormat.fallback(message: "", date: date).session, "New Session")
    }

    func testUniqued() throws {
        let x = names("x")
        let cases: [(TakenNames, String?, String?)] = [
            (.none, "feat/x", "x"),
            (TakenNames(branches: ["feat/x"]), "feat/x-2", "x-2"),
            (TakenNames(worktrees: ["x"]), "feat/x-2", "x-2"),
            (TakenNames(branches: ["feat/x", "feat/x-2"]), "feat/x-3", "x-3"),
            (TakenNames(branches: ["Feat/X"]), "feat/x-2", "x-2"),
            (TakenNames(branches: ["feat/x/y"]), "feat/x-2", "x-2"),
            (TakenNames(branches: ["feat"]), "feature/x", "x"),
            (TakenNames(branches: ["feat", "feature"]), nil, nil),
            (TakenNames(branches: ["feat", "feature/x"]), "feature/x-2", "x-2"),
            (TakenNames(branches: Set(["feat/x"] + (2...99).map { "feat/x-\($0)" })), nil, nil)
        ]
        var produced: [String] = []
        for (taken, branch, worktree) in cases {
            let result = x.uniqued(avoiding: taken)
            XCTAssertEqual(result?.branch, branch, "\(taken)")
            XCTAssertEqual(result?.worktree, worktree, "\(taken)")
            if let result {
                XCTAssertEqual(result.session, x.session)
                XCTAssertEqual(result.type, .feat)
                produced.append(result.branch)
            }
        }
        XCTAssertEqual(x.uniqued(avoiding: .none), x)

        let fix = names("x", type: .fix).uniqued(avoiding: TakenNames(branches: ["fix"]))
        XCTAssertEqual(fix?.branch, "bugfix/x")
        XCTAssertEqual(fix?.type, .fix)
        XCTAssertNil(names("x", type: .chore).uniqued(avoiding: TakenNames(branches: ["chore"])))

        let long = names("abcdefghij-abcdefghij-abcdefghij-abcdefghij-abcd")
        XCTAssertEqual(long.description.count, 48)
        let taken = TakenNames(branches: Set([long.branch] + (2...98).map { "feat/\(NameFormat.truncated(long.description, to: 48 - "-\($0)".count))-\($0)" }))
        let numbered = try XCTUnwrap(long.uniqued(avoiding: taken))
        XCTAssertEqual(numbered.description, "abcdefghij-abcdefghij-abcdefghij-abcdefghij-99")
        XCTAssertLessThanOrEqual(numbered.description.count, 48)
        let second = try XCTUnwrap(long.uniqued(avoiding: TakenNames(branches: [long.branch])))
        XCTAssertEqual(second.description, "abcdefghij-abcdefghij-abcdefghij-abcdefghij-2")
        produced += [numbered.branch, second.branch, long.branch, fix!.branch]

        let fallback = NameFormat.fallback(message: "", date: date)
        produced.append(fallback.branch)
        for branch in produced { try assertValidBranch(branch) }
    }

    func testPrompt() {
        let prompt = NameFormat.prompt(for: String(repeating: "a", count: 4100))
        XCTAssertTrue(prompt.hasSuffix("<request>\n" + String(repeating: "a", count: 4000) + "\n</request>"))
        XCTAssertTrue(prompt.hasPrefix("Name a coding task from the user's request below."))
        XCTAssertTrue(NameFormat.prompt(for: "Fix #12").contains("<request>\nFix #12\n</request>"))
    }

    func testSchemaIsJSON() throws {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(NameFormat.schema.utf8)) as? [String: Any])
        XCTAssertEqual(object["required"] as? [String], ["type", "slug", "title"])
        XCTAssertEqual(object["additionalProperties"] as? Bool, false)
    }
}
