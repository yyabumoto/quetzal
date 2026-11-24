import Foundation

nonisolated enum Provider: String, CaseIterable, Identifiable {
    case codex = "Codex"
    case claudeCode = "Claude Code"

    var id: Self { self }
    func key(_ field: String) -> String { "\(rawValue).\(field)" }
}

nonisolated struct ModelSettings: Equatable, Sendable {
    var model: String?
    var effort: String?

    init(model: String?, effort: String?) {
        self.model = Self.value(model)
        self.effort = Self.value(effort)
    }

    private static func value(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    static func defaults(for provider: Provider, store: UserDefaults = .standard) -> Self {
        Self(model: store.string(forKey: provider.key("model")), effort: store.string(forKey: provider.key("effort")))
    }

    func save(for provider: Provider, store: UserDefaults = .standard) {
        store.set(model, forKey: provider.key("model"))
        store.set(effort, forKey: provider.key("effort"))
    }
}

nonisolated struct SessionSettingsDraft {
    var model: String?
    var effort: String?

    func settings(defaultModel: String, defaultEffort: String) -> ModelSettings {
        ModelSettings(model: model ?? defaultModel, effort: effort ?? defaultEffort)
    }
}
