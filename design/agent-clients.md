# CLI integration

Quetzal launches one CLI child process per session and exchanges newline-delimited JSON over standard input and output. It converts responses, approval requests, and completion messages into the common events used by the [chat session](chat-sessions.md). Closing a window or canceling startup closes the connection and stops its child process. Events from a closed connection cannot change the state of a new session.

## Codex

- Quetzal launches `codex app-server --stdio`. After initialization, it calls `thread/start` with the selected worktree as `cwd` and verifies that the returned `cwd` matches.
- Quetzal passes the model when starting the thread and the effort with each `turn/start`. It uses `turn/interrupt` to request interruption and `turn/completed` to determine when the turn ends.
- Quetzal handles approvals for command execution, terminal input, file changes, and turn-scoped permissions. It tracks approvals by request ID and matches file-change targets by thread, turn, and item. If the targets arrive later, it updates the corresponding card. If a command approval includes a network destination, the card shows its protocol and host.

## Claude Code

- Quetzal launches `claude` in `stream-json` mode and passes the model and effort as startup arguments. It initializes and interrupts the session with control messages. It checks the working directory and session ID reported in the initialization event. The startup timeout is suspended while a reported SessionStart hook is running.
- Quetzal displays incremental and final text in the conversation and uses `result` to determine when the turn ends. It reads tool approval requests from the CLI’s standard output and writes a decision for each request to its standard input. If the CLI cancels a request, Quetzal removes its card.
- At initialization, Quetzal passes instructions read from eligible `CLAUDE.md` and `.claude/CLAUDE.md` files in the selected worktree. It follows links to instruction files within the worktree.
- The CLI loads user settings. Quetzal also forwards `permissions.deny` and `permissions.ask` from the worktree's `.claude/settings.json` and `.claude/settings.local.json`. When either settings file or `.mcp.json` exists, the chat explains which project settings apply.

See [CodexClient.swift](../Quetzal/CodexClient.swift), [ClaudeCodeClient.swift](../Quetzal/ClaudeCodeClient.swift), [ClaudeCodeProtocol.swift](../Quetzal/ClaudeCodeProtocol.swift), and [AgentProtocol.swift](../Quetzal/AgentProtocol.swift).
