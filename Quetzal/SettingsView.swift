import SwiftUI

struct SettingsView: View {
    var body: some View {
        Form {
            ForEach(Provider.allCases) { provider in
                ProviderSettings(provider: provider)
            }
            NamingSettingsSection()
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ProviderSettings: View {
    let provider: Provider
    @AppStorage private var model: String
    @AppStorage private var effort: String

    init(provider: Provider) {
        self.provider = provider
        _model = AppStorage(wrappedValue: "", provider.key("model"))
        _effort = AppStorage(wrappedValue: "", provider.key("effort"))
    }

    var body: some View {
        Section(provider.rawValue) {
            TextField("Model", text: $model)
            TextField("Effort", text: $effort)
        }
    }
}
