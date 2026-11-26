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
