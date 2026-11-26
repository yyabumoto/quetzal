import Foundation

nonisolated enum Provider: String, CaseIterable, Identifiable {
    case codex = "Codex"
    case claudeCode = "Claude Code"

    var id: Self { self }
    func key(_ field: String) -> String { "\(rawValue).\(field)" }
}

extension Provider {
    private struct CodexModel {
        let id: String
        let efforts: [String]
        let defaultEffort: String
    }

    private static let commonCodexEfforts = ["low", "medium", "high", "xhigh"]
    private static let codexEffortsThroughMax = commonCodexEfforts + ["max"]
    private static let allCodexEfforts = codexEffortsThroughMax + ["ultra"]
    private static let codexModels: [CodexModel] = [
        CodexModel(id: "gpt-6.2-sol", efforts: allCodexEfforts, defaultEffort: "low"),
        CodexModel(id: "gpt-6.2-astra", efforts: allCodexEfforts, defaultEffort: "low"),
        CodexModel(id: "gpt-6.1-terra", efforts: allCodexEfforts, defaultEffort: "low"),
        CodexModel(id: "gpt-6.1-sol", efforts: allCodexEfforts, defaultEffort: "low"),
        CodexModel(id: "gpt-6-astra", efforts: allCodexEfforts, defaultEffort: "low"),
        CodexModel(id: "gpt-6-sol", efforts: allCodexEfforts, defaultEffort: "medium"),
        CodexModel(id: "gpt-6-luna", efforts: codexEffortsThroughMax, defaultEffort: "medium"),
        CodexModel(id: "gpt-5.6-sol", efforts: allCodexEfforts, defaultEffort: "low"),
        CodexModel(id: "gpt-5.6-terra", efforts: allCodexEfforts, defaultEffort: "medium"),
        CodexModel(id: "gpt-5.6-luna", efforts: codexEffortsThroughMax, defaultEffort: "medium"),
        CodexModel(id: "gpt-5.5", efforts: commonCodexEfforts, defaultEffort: "medium")
    ]

    func modelOptions(current: ModelSettings, saved: ModelSettings) -> [String] {
        let options = self == .codex ? Self.codexModels.map(\.id) : ["opus", "sonnet", "haiku"]
        return Self.menuOptions(options, saved: saved.model, current: current.model)
    }

    func effortOptions(current: ModelSettings, saved: ModelSettings, isSessionSetup: Bool) -> [String] {
        let options: [String]
        var savedEffort = saved.effort
        switch self {
        case .codex:
            let model = Self.codexModels.first { $0.id == current.model }
            options = model?.efforts ?? Self.commonCodexEfforts
            if let model, let effort = savedEffort,
               Self.allCodexEfforts.contains(effort), !model.efforts.contains(effort) {
                savedEffort = nil
            }
        case .claudeCode:
            options = ClaudeCodeEffort.levels
            if !isSessionSetup, let effort = savedEffort, !options.contains(effort) {
                savedEffort = nil
            }
        }
        return Self.menuOptions(options, saved: savedEffort, current: current.effort)
    }

    func selectingModel(_ id: String, in current: ModelSettings) -> ModelSettings {
        var updated = ModelSettings(model: id, effort: current.effort)
        if self == .codex, let model = Self.codexModels.first(where: { $0.id == updated.model }),
           updated.model != current.model, let effort = current.effort,
           Self.allCodexEfforts.contains(effort), !model.efforts.contains(effort) {
            updated.effort = model.defaultEffort
        }
        return updated
    }

    private static func menuOptions(_ options: [String], saved: String?, current: String?) -> [String] {
        var seen = Set<String>()
        let values = options + [saved, current].compactMap { $0 }
        return values.filter { seen.insert($0).inserted }
    }
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
