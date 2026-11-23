import SwiftUI

struct ChatView: View {
    @Bindable var session: ChatSession

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Codex").font(.headline)
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
                            VStack(alignment: .leading, spacing: 4) {
                                Text(message.author.rawValue).font(.caption.bold()).foregroundStyle(.secondary)
                                Text(verbatim: message.text).textSelection(.enabled)
                            }
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
                    TextField("Message Codex", text: $session.draft, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...6)
                        .disabled(session.phase != .ready)
                    HStack {
                        if session.phase == .sending { Text("Sending…") }
                        if session.phase == .running { Text("Running…") }
                        if session.phase == .interrupting { Text("Interrupting…") }
                        Spacer()
                        Button("Interrupt") { Task { await session.interrupt() } }
                            .disabled(!session.canInterrupt)
                        Button("Send") { Task { await session.send(session.draft) } }
                            .keyboardShortcut(.return, modifiers: .command)
                            .disabled(!session.canSend)
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
