# リポジトリと worktree

## 作業先を選ぶ

- サイドバーの「Open Repository…」でローカルフォルダを開く。Git がそのフォルダから特定したリポジトリの worktree を、フォルダ名とパスで表示する。読み込み中は進捗を、失敗時はエラーを表示する。同じフォルダを開き直して再試行できる。
- 作業先は一覧から明示的に選ぶ。Git が `prunable` と報告した行には「Unavailable」を表示し、選択を無効にする。選択した既存 worktree のフルパスは開始画面に表示する。
- 「New Worktree」は選択できる。開始画面には既存 worktree を選ぶよう案内し、「Start Session」を無効にする。
- 別のフォルダを開くと作業先と開始時のエラーを解除する。以前の一覧読み込みや開始前の検証が遅れて終わっても、その結果で新しい選択を上書きしない。

## 一覧の取得と開始前の検証

- 一覧には Git の `worktree list --porcelain -z` を使う。パスに空白や改行があってもレコードの区切りを保つ。bare リポジトリでは linked worktree だけを載せる。
- main worktree の場所には、開いたフォルダから確認したルート、照合できたローカルの `core.worktree`、照合できた Git の一覧の先頭パスの順で採用する。Git の一覧を使った場合や場所を特定できない場合は、main worktree のフォルダを直接開く方法を案内する。
- 開始直前に、選んだフォルダが引き続き同じリポジトリに属する利用可能な worktree のルートか確認する。一覧取得時のリンク解決先と共有 Git ディレクトリの識別情報を照合する。検証に失敗した場合はエラーを表示し、作業先を選び直せるよう選択を解除する。
- 検証を通過した worktree のルートを CLI の作業ディレクトリにする。検証中に作業先が変われば、その試行を取り消す。

## セッション中に作業先を変える

- 接続中、チャット表示中、切断後に別の行を選ぶと、現在の会話を終了するか確認する。「Cancel」は元の選択に戻す。「End Session」は選んだ作業先に切り替え、現在のセッションを閉じて開始画面に戻る。次のセッションは「Start Session」で開始する。
- 「New Session」で会話を閉じた場合は、作業先の選択を引き継ぐ。別のリポジトリを開く操作は開始画面で使える。

実装は [GitWorktreeCatalog.swift](../Quetzal/GitWorktreeCatalog.swift)、[WorktreeSessionStart.swift](../Quetzal/WorktreeSessionStart.swift)、[WorktreeSidebar.swift](../Quetzal/WorktreeSidebar.swift)、[ContentView.swift](../Quetzal/ContentView.swift) を参照。
