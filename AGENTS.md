# Quetzal

Native macOS app (SwiftUI) that chats with the Claude Code and Codex CLIs. See [README.md](README.md) for requirements and layout.

## Language

Write everything in English: code comments, commit messages, issues, PRs, review comments, and docs.

## Build and test

```sh
xcodebuild build -project Quetzal.xcodeproj -scheme Quetzal -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
xcodebuild test -project Quetzal.xcodeproj -scheme Quetzal -destination 'platform=macOS'
```

CI ([.github/workflows/build.yml](.github/workflows/build.yml)) runs only the build, on macOS 26 and 27. Run the tests locally before opening a PR.

### UI screenshots

The `QuetzalUITests` scheme launches Quetzal in fixed fixture states (no repository open, worktree selected, session in progress, pending approval, error notice) in light and dark appearance. Each state and appearance is its own test, which fails when the state is not reached, and attaches a PNG of the window named `<scenario>-<appearance>` (for example `pending-approval-dark`). The tests need no agent CLIs. `xcodebuild test -scheme Quetzal` does not run them.

Run these commands one at a time from the repository root, each exactly as written: no `cd` prefix, `&&` chain, pipe, or redirect. Tools that let the developer allow a command outside the sandbox match the command line as written, and anything added around it stops the match. Replace `<output-dir>` with a path outside the repository that does not exist yet or is an empty directory, for example under `$TMPDIR`.

1. `automationmodetool` must report "DOES NOT REQUIRE user authentication".
2. `pgrep -x Quetzal` must print nothing.
3. `xcodebuild test -project Quetzal.xcodeproj -scheme QuetzalUITests -configuration Debug -destination 'platform=macOS' -resultBundlePath <output-dir>/UITests.xcresult`
4. `xcrun xcresulttool export attachments --path <output-dir>/UITests.xcresult --output-path <output-dir>/screenshots`

The exported PNGs keep generated file names. Read `<output-dir>/screenshots/manifest.json` to find each screenshot: it is an array with one entry per test (`testIdentifier`, such as `ScreenshotTests/testPendingApprovalDark()`), and each entry's `attachments` list gives the file in `<output-dir>/screenshots/` as `exportedFileName` and the attachment name as `suggestedHumanReadableName`, which starts with `<scenario>-<appearance>`. Attachments with `isAssociatedWithFailure` set to `true` are ones XCTest adds for a failed test.

Prerequisites:

- A logged-in macOS GUI session. The UI tests take over the screen, keyboard, and mouse while they run.
- Run all four commands outside your command sandbox. Inside a sandbox, `automationmodetool` reports that authentication is required even when the Mac is set up, `pgrep` can't see processes the sandbox did not start, and the UI tests can't launch the app. Ask for that permission the way your tool requires; don't change sandbox settings in this repository.
- Automation Mode enabled without authentication. The developer sets this up once with `sudo automationmodetool enable-automationmode-without-authentication` and can undo it with `sudo automationmodetool disable-automationmode-without-authentication`.
- Quetzal is not running. Launching the UI test app terminates a running Quetzal. This includes the Quetzal instance an agent session runs in: an agent started from Quetzal can't run the UI tests.

If a prerequisite is not met (`automationmodetool` still reports that authentication is required outside the sandbox, `pgrep` prints a process ID, or xcodebuild cannot launch the app), stop and report it to the developer with the command or action needed. Don't work around it, for example by quitting Quetzal, changing system or sandbox settings yourself, or reporting the UI as checked without screenshots. If xcodebuild reports failed tests, the failing test names the state and appearance that was not reached.

## Specifications

[design/](design/README.md) records current behavior. When a change alters behavior described there, update the matching page in the same PR. A new feature with no matching page gets a new page, linked from `design/README.md`.

## Issues

- Every issue carries exactly one priority label:
  - `priority: high`: core chat in the native UI, shipped first
  - `priority: medium`: work-management features for the initial release
  - `priority: low`: features planned after the initial release
- When you start an issue, set its status to **In Progress** in the [Quetzal project](https://github.com/users/yyabumoto/projects/2). The project moves it to **Done** when the issue closes.

## Branches, commits, and PRs

- Branch: `<type>/issue-<N>-<slug>`, e.g. `feat/issue-16-worktree-sidebar`. Codex may prefix it with `codex/`.
- Commit: `<type>(<scope>): <summary>`, e.g. `feat(sidebar): select a worktree in the left pane`. Types: `feat`, `fix`, `refactor`, `test`, `docs`, `ci`, `chore`.
- One issue per PR. The PR body includes `Closes #<N>`.
