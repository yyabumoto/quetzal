# Repositories and worktrees

## Choose a worktree

- Select **Open Repository…** in the sidebar and choose a local folder. Quetzal uses Git to identify the repository and lists its worktrees by folder name and path. The sidebar shows progress while loading and an error if loading fails. Reopen the same folder to retry.
- Select a worktree from the list. Entries Git marks as `prunable` appear as **Unavailable** and cannot be selected. The setup screen shows the full path of the selected worktree.
- You can select **New Worktree**. The setup screen then prompts you to select an existing worktree and disables **Start Session**.
- Opening another folder clears the selected worktree and any startup error. Earlier list or validation results cannot overwrite the new selection if they arrive late.

## Listing and validating worktrees

- Quetzal uses `git worktree list --porcelain -z` so that spaces and newlines in paths are preserved. For a bare repository, the list contains only linked worktrees.
- To locate the main worktree, Quetzal checks the root confirmed from the opened folder, a verified local `core.worktree` setting, and the verified first path from Git's list, in that order. When using the path from Git's list or when the location is unknown, the sidebar explains how to open the main worktree's folder directly.
- Before launch, Quetzal verifies that the selected folder is still the root of an available worktree in the same repository. It checks the resolved path and the identity of the shared Git directory against the values recorded when the list was loaded. If validation fails, Quetzal shows an error and clears the selection so the user can choose again.
- The CLI starts with the validated worktree root as its working directory. Changing the selection during validation cancels that launch attempt.

## Switch worktrees during a session

- Selecting another worktree while connecting, while viewing a conversation, or after a disconnect prompts the user to end the current conversation. **Cancel** restores the previous selection. **End Session** switches to the chosen worktree, closes the current session, and returns to the setup screen. Choose **Start Session** to start the next session.
- **New Session** ends the conversation and keeps the selected worktree. You can open another repository from the setup screen.

See [GitWorktreeCatalog.swift](../Quetzal/GitWorktreeCatalog.swift), [WorktreeSessionStart.swift](../Quetzal/WorktreeSessionStart.swift), [WorktreeSidebar.swift](../Quetzal/WorktreeSidebar.swift), and [ContentView.swift](../Quetzal/ContentView.swift).
