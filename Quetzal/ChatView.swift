import SwiftUI

struct ChatView: View {
    @Bindable var session: ChatSession

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text(session.provider.rawValue).font(.headline)
                    Text(session.worktree?.path ?? "").foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
                Button("New Session") { Task { await session.close() } }
            }
            .padding()
            Divider()
            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(session.messages) { message in
                            let isUser = message.author == .user
                            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                                Text(message.author.rawValue).font(.caption.bold()).foregroundStyle(.secondary)
                                Text(verbatim: message.text)
                                    .multilineTextAlignment(isUser ? .trailing : .leading)
                                    .textSelection(.enabled)
                            }
                            .padding(.leading, isUser ? 32 : 0)
                            .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
                        }
                        ForEach(session.approvals) { request in
                            approvalCard(request)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: session.messages.last?.text) { scroll.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: session.approvals.map(\.id)) { scroll.scrollTo("bottom", anchor: .bottom) }
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                if let notice = session.notice {
                    Text(verbatim: notice).foregroundStyle(.red).textSelection(.enabled)
                }
                if session.phase == .disconnected {
                    if !session.draft.isEmpty {
                        Text(verbatim: session.draft).textSelection(.enabled)
                    }
                } else {
                    if session.phase == .sending { Text("Sending…") }
                    if session.phase == .running { Text("Running…") }
                    if session.phase == .interrupting { Text("Interrupting…") }
                    MessageInput(session: session, provider: session.provider)
                }
                SessionStatusLine(
                    provider: session.provider, providerSelection: nil,
                    model: Binding(get: { session.settings.model ?? "" }, set: { model in
                        session.updateSettings(ModelSettings(model: model, effort: session.settings.effort))
                    }),
                    effort: Binding(get: { session.settings.effort ?? "" }, set: { effort in
                        session.updateSettings(ModelSettings(model: session.settings.model, effort: effort))
                    })
                )
                .disabled(!session.canEditSettings)
            }
            .padding()
        }
    }

    private func approvalCard(_ request: ApprovalRequest) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text(request.title).font(.headline)
                Text(verbatim: request.details.joined(separator: "\n")).textSelection(.enabled)
                HStack {
                    Button("Decline") { Task { await session.answer(request.id, allow: false) } }
                    Button("Allow") { Task { await session.answer(request.id, allow: true, reviewed: request) } }
                        .disabled(!request.canAllow)
                }
                .disabled(session.answering.contains(request.id))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}


struct MessageInput: View {
    @Bindable var session: ChatSession
    let provider: Provider

    private var showsInterrupt: Bool {
        session.phase == .sending || session.phase == .running || session.phase == .interrupting
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message \(provider.rawValue)", text: $session.draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...6)
                .disabled(session.phase != .ready)

            let title: LocalizedStringKey = showsInterrupt ? "Interrupt" : "Send"
            Button(title, systemImage: showsInterrupt ? "stop.fill" : "paperplane.fill") {
                Task {
                    if showsInterrupt {
                        await session.interrupt()
                    } else {
                        await session.send(session.draft)
                    }
                }
            }
            .labelStyle(.iconOnly)
            .help(title)
            .keyboardShortcut(showsInterrupt || session.phase == .setup ? nil : KeyboardShortcut(.return, modifiers: .command))
            .disabled(showsInterrupt ? !session.canInterrupt : !session.canSend)
        }
    }
}

struct SessionStatusLine: View {
    let provider: Provider
    let providerSelection: Binding<Provider>?
    @Binding var model: String
    @Binding var effort: String

    var body: some View {
        HStack(spacing: 12) {
            if let providerSelection {
                Picker("Provider", selection: providerSelection) {
                    ForEach(Provider.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            } else {
                Text(provider.rawValue).foregroundStyle(.secondary)
            }

            SessionStatusValue("Model", value: $model, allowsEmpty: providerSelection != nil)
            if provider == .claudeCode && providerSelection == nil {
                Menu {
                    ForEach(ClaudeCodeEffort.levels, id: \.self) { level in
                        Button(level) { effort = level }
                    }
                } label: {
                    StatusValueLabel("Effort", value: effort)
                }
                .fixedSize()
            } else {
                SessionStatusValue("Effort", value: $effort, allowsEmpty: providerSelection != nil)
            }
            Spacer(minLength: 0)
        }
        .controlSize(.small)
    }
}

private struct SessionStatusValue: View {
    let title: LocalizedStringKey
    @Binding var value: String
    let allowsEmpty: Bool
    @State private var pendingValue = ""
    @State private var isEditing = false

    init(_ title: LocalizedStringKey, value: Binding<String>, allowsEmpty: Bool) {
        self.title = title
        _value = value
        self.allowsEmpty = allowsEmpty
    }

    var body: some View {
        Button {
            pendingValue = value
            isEditing = true
        } label: {
            StatusValueLabel(title, value: value)
        }
        .popover(isPresented: $isEditing) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                TextField(title, text: $pendingValue, prompt: Text("CLI default"))
                Button("Apply") {
                    value = pendingValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    isEditing = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!allowsEmpty && pendingValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
            .frame(width: 244)
        }
    }
}

private struct StatusValueLabel: View {
    let title: LocalizedStringKey
    let value: String

    init(_ title: LocalizedStringKey, value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(title).foregroundStyle(.secondary)
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("CLI default")
            } else {
                Text(verbatim: value)
            }
        }
        .lineLimit(1)
    }
}
