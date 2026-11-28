import SwiftUI

@main
struct QuetzalApp: App {
#if DEBUG
    private let fixture = UIFixture(arguments: ProcessInfo.processInfo.arguments)
#endif

    var body: some Scene {
        WindowGroup {
#if DEBUG
            if let fixture { UIFixtureRoot(fixture: fixture) } else { ContentView() }
#else
            ContentView()
#endif
        }
#if DEBUG
        .windowResizability(fixture == nil ? .automatic : .contentSize)
#endif
        Settings { SettingsView() }
    }
}
