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

`scripts/ui-screenshots.sh [output-directory]` launches Quetzal in fixed fixture states (no repository open, worktree selected, session in progress, pending approval, error notice) in light and dark appearance and writes one PNG per state and appearance, named `<scenario>-<appearance>.png` (for example `pending-approval-dark.png`). Without an argument it writes to a new directory under `$TMPDIR` and prints the path. An output directory you pass must be outside the repository and empty. It needs no agent CLIs. `xcodebuild test -scheme Quetzal` does not run these UI tests.

Run it from the repository root exactly as `scripts/ui-screenshots.sh` or `scripts/ui-screenshots.sh <output-directory>`, as a command of its own: no `cd` prefix, `&&` chain, pipe, or redirect. Tools that let the developer allow a command outside the sandbox match the command line as written, and anything added around it stops the match.

Prerequisites:

- A logged-in macOS GUI session. The UI tests take over the screen, keyboard, and mouse while they run.
- Run the script outside your command sandbox. UI tests launch the app, which a sandbox that blocks launching apps prevents. Ask for that permission the way your tool requires; don't change sandbox settings in this repository.
- Automation Mode enabled without authentication. The developer sets this up once with `sudo automationmodetool enable-automationmode-without-authentication` and can undo it with `sudo automationmodetool disable-automationmode-without-authentication`. `automationmodetool` with no argument shows the current setting.
- Quetzal is not running. Launching the UI test app terminates a running Quetzal, so the script refuses to start while one is running. This includes the Quetzal instance an agent session runs in: an agent started from Quetzal can't run the script.

If the script exits with code 3 (Automation Mode), first rerun it outside your command sandbox: inside a sandbox the check reports that authentication is required even when the Mac is set up. If it still exits with code 3 there, or another prerequisite is not met (it refuses because Quetzal is running, or xcodebuild cannot launch the app), stop and report it to the developer with the command or action from the message. Don't work around it, for example by changing system or sandbox settings yourself or by reporting the UI as checked without screenshots.

The script exits non-zero and names the screenshots that are missing or unexpected unless it wrote exactly the ten expected PNGs.

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
