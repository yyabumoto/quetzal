# Chat and sessions

## Start a session and choose settings

- Each window has its own worktree selection, CLI connection, and conversation. Choose Codex or Claude Code on the setup screen and start a session in the [selected worktree](worktrees.md). If Quetzal cannot find the CLI, you can choose its executable. While connecting, use **Cancel** to stop startup.
- **Settings** saves the default model and effort for each provider. Edits on the setup screen apply to the next session started with that provider. Blank or whitespace-only values defer to the CLI defaults. The model used for naming sessions is set separately in the **Naming** section.

## Compose messages and read the conversation

- The header shows the session name and worktree path. Until the [session name](work-naming.md) is generated from the first message, the header shows the provider name. The user's name and messages are right-aligned. Agent responses and session notices are left-aligned. Agent responses appear as they stream in.
- When the composer is ready, **Send** appears to its right. Click the button or press ⌘Return to send. Blank or whitespace-only messages cannot be sent. If sending fails before the request starts, Quetzal restores the message to the composer.
- While sending, running, or interrupting a request, **Interrupt** appears in the same position. The button is enabled when a request is running and Quetzal can identify it. Once the request ends, the composer accepts the next message. Failed and interrupted requests produce a notice in the conversation.

## Approve requests and end a session

- Each approval request from the CLI appears in its own card below the conversation. The card shows the operation and any targets or reasons provided by the CLI. Use **Allow** or **Decline** to respond. **Allow** is disabled when required details are missing. If the details change after the card is displayed, the user must review the updated request before allowing it.
- If the CLI disconnects, Quetzal keeps the conversation and error visible and removes the composer and approval cards. **New Session** returns to the setup screen. Ending a session discards its conversation, draft, and approvals and stops the CLI.

See [ChatSession.swift](../Quetzal/ChatSession.swift), [ChatView.swift](../Quetzal/ChatView.swift), and [ModelSettings.swift](../Quetzal/ModelSettings.swift).
