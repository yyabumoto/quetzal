import XCTest
@testable import Quetzal

final class NamingSettingsTests: XCTestCase {
    func testDefaultsTrimmingAndSeparateKeys() throws {
        let suite = UUID().uuidString
        let store = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { store.removePersistentDomain(forName: suite) }
        XCTAssertEqual(NamingSettings.key(for: .claudeCode), "Naming.Claude Code.model")
        XCTAssertEqual(NamingSettings.key(for: .codex), "Naming.Codex.model")
        XCTAssertEqual(NamingSettings.model(for: .claudeCode, store: store), "haiku")
        XCTAssertNil(NamingSettings.model(for: .codex, store: store))

        store.set("  sonnet \n", forKey: "Naming.Claude Code.model")
        store.set(" gpt-mini ", forKey: "Naming.Codex.model")
        XCTAssertEqual(NamingSettings.model(for: .claudeCode, store: store), "sonnet")
        XCTAssertEqual(NamingSettings.model(for: .codex, store: store), "gpt-mini")

        store.set("   ", forKey: "Naming.Claude Code.model")
        store.set("", forKey: "Naming.Codex.model")
        XCTAssertEqual(NamingSettings.model(for: .claudeCode, store: store), "haiku")
        XCTAssertNil(NamingSettings.model(for: .codex, store: store))

        ModelSettings(model: "opus", effort: "high").save(for: .claudeCode, store: store)
        XCTAssertEqual(store.string(forKey: "Claude Code.model"), "opus")
        XCTAssertEqual(NamingSettings.model(for: .claudeCode, store: store), "haiku")
    }
}
