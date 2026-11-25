import SwiftUI

struct ChatView: View {
    @Bindable var session: ChatSession

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text(session.title ?? session.provider.rawValue).font(.headline)
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
                if session.phase != .disconnected {
                    if session.phase == .sending { Text("Sending…") }
                    if session.phase == .running { Text("Running…") }
                    if session.phase == .interrupting { Text("Interrupting…") }
                    HStack(alignment: .bottom, spacing: 8) {
                        TextField("Message \(session.provider.rawValue)", text: $session.draft, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(2...6)
                            .disabled(session.phase != .ready)

                        let showsInterrupt = session.phase == .sending || session.phase == .running || session.phase == .interrupting
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
                        .keyboardShortcut(showsInterrupt ? nil : KeyboardShortcut(.return, modifiers: .command))
                        .disabled(showsInterrupt ? !session.canInterrupt : !session.canSend)
                    }
                }
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
