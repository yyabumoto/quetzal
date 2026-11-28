# Quetzal

Quetzal is a native macOS app for chatting with [Claude Code](https://docs.claude.com/en/docs/claude-code) and [Codex](https://github.com/openai/codex) in one UI. Pick a Git worktree, start a session with either agent, and review its approval requests in the chat.

## Requirements

- macOS 26.0 or later
- Xcode 26.6 or later (to build from source)
- The `claude` and/or `codex` CLI, installed and signed in

## Install

Builds will be published on [GitHub Releases](https://github.com/yyabumoto/quetzal/releases). Until then, build from source.

## Build from source

Open `Quetzal.xcodeproj` in Xcode and run the `Quetzal` scheme, or build from the command line:

```sh
xcodebuild build -project Quetzal.xcodeproj -scheme Quetzal -destination 'platform=macOS'
```

## Repository layout

| Path | Contents |
| --- | --- |
| `Quetzal/` | App source |
| `QuetzalTests/` | Unit tests |
| `QuetzalUITests/` | UI tests that capture screenshots of fixture states |
| `design/` | Specifications of current behavior. Start at [design/README.md](design/README.md) |
| `.github/workflows/` | CI workflow that builds the app on macOS 26 and 27 |

## License

Licensed under the [Apache License 2.0](LICENSE).
