import SwiftUI

nonisolated enum NamingSettings {
    static func key(for provider: Provider) -> String { "Naming.\(provider.key("model"))" }

    static func defaultModel(for provider: Provider) -> String? {
        provider == .claudeCode ? "haiku" : nil
    }

    /// 保存値の前後の空白を削り、空なら defaultModel を返す。
    static func model(for provider: Provider, store: UserDefaults = .standard) -> String? {
        guard let value = store.string(forKey: key(for: provider))?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return defaultModel(for: provider) }
        return value
    }
}

struct NamingSettingsSection: View {
    var body: some View {
        Section {
            ForEach([Provider.claudeCode, .codex]) { provider in
                NamingModelField(provider: provider)
            }
        } header: {
            Text("Naming")
        } footer: {
            Text("Names for sessions, worktrees, and branches are generated with the CLI of the session's agent.")
        }
    }
}

private struct NamingModelField: View {
    let provider: Provider
    @AppStorage private var model: String

    init(provider: Provider) {
        self.provider = provider
        _model = AppStorage(wrappedValue: "", NamingSettings.key(for: provider))
    }

    var body: some View {
        TextField("\(provider.rawValue) Model", text: $model,
                  prompt: Text(NamingSettings.defaultModel(for: provider) ?? "CLI default"))
    }
}
