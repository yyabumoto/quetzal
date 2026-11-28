# macOS support and builds

- Quetzal is a SwiftUI app with a minimum deployment target of macOS 26.0. The Xcode project and build scheme are both named `Quetzal`.
- The app launches Git and agent CLIs and uses the selected worktree as the agent's working directory. App Sandbox is disabled for both Debug and Release builds of the app target.
- The GitHub Actions **Build** workflow runs on pushes to `main` and on pull requests. It has separate macOS 26 and macOS 27 jobs. Each prints the Xcode and SDK versions and runs an unsigned Debug build.
- The **Build** workflow checks compilation and linking. App launch and test execution are separate checks.
- The `QuetzalUITests` target and its shared scheme capture screenshots of fixed states. Debug builds accept `--ui-fixture <scenario>` and `--ui-appearance <light|dark>`, which replace Git and the agent CLIs with fixture data. Release builds do not contain fixture mode. The shared `Quetzal` scheme builds only the app, and its test action runs only `QuetzalTests`.

See the [Xcode project](../Quetzal.xcodeproj/project.pbxproj) and [Build workflow](../.github/workflows/build.yml).
