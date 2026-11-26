# macOS 対応とビルド

- Quetzal は SwiftUI の macOS アプリで、最低対応バージョンは macOS 26.0。Xcode のプロジェクトとビルドスキームはいずれも `Quetzal`。
- アプリは Git とエージェントの CLI を起動し、選んだ worktree を作業先として使う。アプリターゲットの Debug と Release では App Sandbox を無効にしている。
- GitHub Actions の「Build」は `main` への push と PR で実行する。macOS 26 と 27 用のジョブを設け、それぞれ Xcode と SDK のバージョンを出力し、コード署名なしで Debug ビルドを実行する。
- CI の「Build」が確認するのはコンパイルとリンク。アプリの起動やテストの実行は別途確認する。

定義は [Xcode プロジェクト](../Quetzal.xcodeproj/project.pbxproj) と [Build ワークフロー](../.github/workflows/build.yml) を参照。
