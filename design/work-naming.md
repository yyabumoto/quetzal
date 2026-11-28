# Session, worktree, and branch names

Quetzal derives a session name, a worktree name, and a branch name from the first message of a session. The [chat header](chat-sessions.md) shows the session name. Creating a worktree and its branch with these names belongs to the flow that starts a session from the first message; until then, only the session name is visible.

## When names are generated

- Sending the first message starts naming in parallel with the request. Naming runs only while the session has no name, so later messages do not rename it.
- If the first message returns to the composer because the request did not start, Quetzal cancels naming and discards any name it already set. The next message that is sent starts naming again.
- Ending the session cancels naming. A naming result from an ended session or a canceled attempt never changes the header.

## Generating names with the CLI

- Quetzal runs the CLI of the session's provider once, non-interactively, with the CLI's saved login, so no separate API key is needed. The CLI runs in an empty temporary folder unrelated to the worktree, and the folder is removed after the CLI has exited.
- The prompt asks the model to name the task without performing it and includes the first 4,000 characters of the message. The model returns structured JSON with `type`, `slug`, and `title`.
- Claude Code runs as `claude -p` with `--json-schema`, no tools, `--safe-mode`, `--strict-mcp-config`, and `--no-session-persistence`. `--bare` is not used because it does not read the OAuth login.
- Codex runs as `codex exec --ephemeral` with `--output-schema`, a read-only sandbox, and hooks, plugins, and apps disabled. The user's `config.toml` is still read, so its login settings and default model apply. Quetzal lists MCP servers with `codex mcp list --json` and disables each enabled one with `-c mcp_servers.<name>.enabled=false`. Servers whose names are not made of letters, digits, `_`, and `-` are left as they are. If listing fails, naming continues without disabling servers.
- The child process gets the same `PATH` adjustment as the session's CLI: the executable's folder is placed first.
- **Settings** has a **Naming** section with a model for each provider. Blank or whitespace-only values use `haiku` for Claude Code and the CLI default for Codex.

## Name formats

- Branch names follow [Conventional Branch](https://conventionalbranch.org) as `<type>/<description>`. The type is `feat`, `fix`, `hotfix`, `release`, or `chore`; an unknown type becomes `feat`. The description uses lowercase letters, digits, and single hyphens and is at most 48 characters. The worktree's folder name is the description.
- The session name is a single line of at most 40 characters. Line breaks and tabs become spaces, other control characters are removed, and runs of spaces are collapsed.
- If the model's `title` or `slug` is unusable, only that part is replaced with the fallback value below.

## Fallback names

- If the CLI cannot be launched, exits with an error, returns invalid output, or does not finish within 15 seconds, Quetzal uses fallback names and continues. The header does not report that a fallback was used.
- The fallback session name is the first non-empty line of the message, or `New Session`. The fallback branch is `feat/session-<yyyyMMdd-HHmmss>` in local time.
- Canceling naming stops the CLI with `SIGTERM` and sends `SIGKILL` if it has not exited after 2 seconds.

## Avoiding existing names

- Before a worktree and branch are created, the names are checked against existing branches (local branches and remote-tracking branches without the remote name) and existing worktree folder names. Comparisons ignore case. A branch also collides with a branch that would be its parent or child, such as `feat` and `feat/x`.
- If a branch named after the type exists, such as `feat`, the type is replaced with its Conventional Branch alias (`feat` → `feature`, `fix` → `bugfix`). If there is no alias or the alias is also taken, the names cannot be used.
- If the description collides, Quetzal appends `-2`, `-3`, and so on up to `-99`, shortening the description to stay within 48 characters, and uses the first number that is free for both the branch and the worktree. If all are taken, the names cannot be used and creation fails.

See [WorkNaming.swift](../Quetzal/WorkNaming.swift), [NameGenerator.swift](../Quetzal/NameGenerator.swift), [NamingSettings.swift](../Quetzal/NamingSettings.swift), and [ChatSession.swift](../Quetzal/ChatSession.swift).
