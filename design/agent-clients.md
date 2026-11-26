# CLI 連携

アプリはセッションごとに CLI を子プロセスとして起動し、標準入出力で改行区切りの JSON をやり取りする。各 CLI の応答、承認、完了を共通のイベントに変換し、[チャット](chat-sessions.md)に渡す。ウインドウを閉じた場合や開始を取り消した場合は、その接続を閉じて子プロセスを終了する。終了済みの接続から届いたイベントは、新しいセッションの状態に反映しない。

## Codex

- `codex app-server --stdio` を起動する。初期化後、選択した worktree を `cwd` に指定して `thread/start` を呼ぶ。応答の `cwd` が選択した worktree と一致することを確認する。
- モデルはスレッドの開始時、effort は各 `turn/start` に渡す。中断には `turn/interrupt` を使い、依頼の終了は `turn/completed` で判断する。
- コマンドの実行、端末への入力、ファイル変更、依頼単位の権限付与の承認を扱う。承認は要求 ID を単位とし、ファイル変更の対象はスレッド、依頼、項目の組で照合する。対象が後から届いた場合は、該当するカードを更新する。コマンドの承認に接続先が含まれる場合は、接続先のプロトコルとホストを表示する。

## Claude Code

- `claude` を `stream-json` で起動し、モデルと effort を起動引数に渡す。初期化と中断は制御メッセージで行う。CLI から受け取った初期化イベントの作業ディレクトリとセッション ID を照合する。起動の応答待ちは、報告された SessionStart フックの実行中はタイムアウトを停止する。
- テキストの増分と確定テキストを履歴に反映し、`result` を依頼の終端として扱う。ツール使用の承認は標準入出力で受け取り、要求ごとに許可または拒否を返す。CLI が要求を取り消した場合はカードを取り除く。
- 選択した worktree 内の `CLAUDE.md` と `.claude/CLAUDE.md` から、読み込み条件を満たす指示を初期化時に渡す。リンクは worktree 内のファイルを指す場合に読み込む。
- CLI の設定ソースは利用者設定に限定する。worktree 内の `.claude/settings.json` と `.claude/settings.local.json` から取り込む設定は `permissions.deny` と `permissions.ask` に限る。該当するプロジェクト設定ファイルや `.mcp.json` がある場合は、チャットに設定の扱いを表示する。

実装は [CodexClient.swift](../Quetzal/CodexClient.swift)、[ClaudeCodeClient.swift](../Quetzal/ClaudeCodeClient.swift)、[ClaudeCodeProtocol.swift](../Quetzal/ClaudeCodeProtocol.swift)、[AgentProtocol.swift](../Quetzal/AgentProtocol.swift) を参照。
