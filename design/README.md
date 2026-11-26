# Quetzal specifications

| Specification | Scope |
| --- | --- |
| [Repositories and worktrees](worktrees.md) | Selecting a worktree in the sidebar, validating it before launch, and switching worktrees during a session |
| [Chat and sessions](chat-sessions.md) | Starting and ending sessions, composing messages, conversation history, approvals, and settings |
| [Session, worktree, and branch names](work-naming.md) | Generating names from the first message, Settings for the naming model, fallback names, and avoiding existing names |
| [CLI integration](agent-clients.md) | Codex and Claude Code connections, protocols, and project settings |
| [macOS support and builds](macos-build.md) | Minimum supported macOS version, Xcode project, and CI build coverage |

Record user-visible behavior, expectations for external CLIs, and design decisions that should hold as the implementation changes. When a specification changes, update its page in the same PR as the implementation. If a new feature has no relevant page, add one and link it here.
