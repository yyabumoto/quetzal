import Foundation
import Observation

@MainActor @Observable
final class ChatSession {
    enum Phase: Equatable {
        case setup, connecting, ready, sending, running, interrupting, disconnected
    }

    struct Message: Identifiable {
        enum Author: String { case user = "You", codex = "Codex", claude = "Claude", status = "Session" }
        let id = UUID()
        let author: Author
        var text: String
    }

    private(set) var phase: Phase = .setup
    private(set) var provider: Provider = .codex
    private(set) var worktree: URL?
    private(set) var messages: [Message] = []
    private(set) var approvals: [ApprovalRequest] = []
    private(set) var answering: Set<RequestID> = []
    private(set) var notice: String?
    var draft = ""

    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var client: (any AgentClient)?
    @ObservationIgnored private var subscription: Task<Void, Never>?
    @ObservationIgnored private var settings = ModelSettings(model: nil, effort: nil)
    @ObservationIgnored private var threadID: String?
    @ObservationIgnored private var turnID: String?
    @ObservationIgnored private var submission: UUID?
    @ObservationIgnored private var completed: Set<String> = []
    @ObservationIgnored private var messageIndices: [ItemKey: Int] = [:]
    @ObservationIgnored private var lastErrors: [String: String] = [:]

    var canSend: Bool { phase == .ready && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var canInterrupt: Bool { phase == .running && turnID != nil }

    func start(worktree: URL, settings: ModelSettings, executable: URL, provider: Provider = .codex) async {
        guard phase == .setup else { return }
        phase = .connecting
        self.provider = provider
        self.settings = settings
        self.worktree = worktree
        let project = provider == .claudeCode ? ClaudeCodeProject.load(in: worktree) : nil
        let connection: any AgentClient = if let project {
            ClaudeCodeClient(executable: executable, project: project)
        } else {
            CodexClient(executable: executable)
        }
        client = connection
        let token = generation
        subscription = Task { [weak self] in
            do {
                for try await event in connection.events {
                    guard let self, generation == token else { return }
                    consume(event)
                }
            } catch {
                guard let self, generation == token else { return }
                disconnect(error)
            }
        }
        do {
            let thread = try await connection.start(worktree: worktree, settings: settings)
            guard generation == token, phase == .connecting else { return }
            threadID = thread
            phase = .ready
            if let project, !project.ignoredFiles.isEmpty {
                var text = "Project settings in this worktree are not applied, except permission deny and ask rules: "
                    + project.ignoredFiles.joined(separator: ", ") + "."
                if !project.unreadableFiles.isEmpty { text += " Could not read: " + project.unreadableFiles.joined(separator: ", ") + "." }
                messages.append(Message(author: .status, text: text))
            }
        } catch {
            if generation == token { disconnect(error) }
        }
    }

    func send(_ text: String) async {
        guard phase == .ready, let client, let threadID,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let token = generation
        let request = UUID()
        submission = request
        notice = nil
        draft = ""
        let message = Message(author: .user, text: text)
        messages.append(message)
        phase = .sending
        do {
            let id = try await client.startTurn(threadID: threadID, text: text, effort: settings.effort)
            guard generation == token, submission == request, phase != .disconnected else { return }
            began(id)
        } catch {
            guard generation == token, submission == request else { return }
            if turnID == nil {
                messages.removeAll { $0.id == message.id }
                draft = text
                if phase != .disconnected { phase = .ready }
            }
            notice = error.localizedDescription
        }
    }

    func answer(_ id: RequestID, allow: Bool, reviewed: ApprovalRequest? = nil) async {
        guard let request = approvals.first(where: { $0.id == id }), let client,
              !allow || request.canAllow else { return }
        if allow, let reviewed, reviewed != request {
            notice = "Approval details changed. Review the updated request."
            return
        }
        guard answering.insert(id).inserted else { return }
        let token = generation
        do {
            try await client.answer(request, allow: allow)
            guard generation == token else { return }
            approvals.removeAll { $0.id == id }
        } catch {
            guard generation == token else { return }
            if approvals.contains(where: { $0.id == id }) { notice = error.localizedDescription }
        }
        answering.remove(id)
    }

    func interrupt() async {
        guard canInterrupt, let turnID, let threadID, let client else { return }
        let token = generation
        phase = .interrupting
        do {
            try await client.interrupt(threadID: threadID, turnID: turnID)
        } catch {
            guard generation == token, self.turnID == turnID, phase == .interrupting else { return }
            phase = .running
            notice = error.localizedDescription
        }
    }

    func close() async {
        generation = UUID()
        subscription?.cancel()
        subscription = nil
        let connection = client
        client = nil
        phase = .setup
        worktree = nil
        threadID = nil
        turnID = nil
        submission = nil
        completed.removeAll()
        messageIndices.removeAll()
        lastErrors.removeAll()
        messages.removeAll()
        approvals.removeAll()
        answering.removeAll()
        notice = nil
        draft = ""
        await connection?.close()
    }

    private func began(_ turn: String) {
        guard !completed.contains(turn), phase == .sending || (phase == .running && turnID == turn) else { return }
        turnID = turn
        phase = .running
    }

    private func consume(_ event: AgentEvent) {
        guard phase != .disconnected else { return }
        switch event {
        case let .started(thread, turn) where thread == threadID:
            began(turn)
        case let .message(key, text, final) where key.thread == threadID && !completed.contains(key.turn):
            began(key.turn)
            if let index = messageIndices[key] {
                if final { messages[index].text = text } else { messages[index].text += text }
            } else {
                messageIndices[key] = messages.count
                messages.append(Message(author: provider == .codex ? .codex : .claude, text: text))
            }
        case let .approval(request) where request.key.thread == threadID && !completed.contains(request.key.turn):
            if !request.key.turn.isEmpty { began(request.key.turn) }
            if let index = approvals.firstIndex(where: { $0.id == request.id }) {
                approvals[index] = request
            } else { approvals.append(request) }
        case let .resolved(thread, id) where thread == threadID:
            approvals.removeAll { $0.id == id }
            answering.remove(id)
        case let .error(thread, turn, message, retrying) where thread == threadID && !completed.contains(turn):
            lastErrors[turn] = message
            if retrying { notice = message }
        case let .completed(thread, turn, status, error) where thread == threadID:
            guard completed.insert(turn).inserted else { return }
            messageIndices = messageIndices.filter { $0.key.turn != turn }
            let resolved = approvals.filter { $0.key.turn == turn || $0.key.turn.isEmpty }.map(\.id)
            approvals.removeAll { resolved.contains($0.id) }
            answering.subtract(resolved)
            let reason = lastErrors.removeValue(forKey: turn)
            if status == "failed" { messages.append(Message(author: .status, text: error ?? reason ?? "Turn failed.")) }
            if status == "interrupted" { messages.append(Message(author: .status, text: "Turn interrupted.")) }
            if turnID == nil || turnID == turn {
                turnID = nil
                submission = nil
                phase = .ready
                notice = nil
            }
        default: break
        }
    }

    private func disconnect(_ error: Error) {
        guard phase != .disconnected else { return }
        phase = .disconnected
        notice = error.localizedDescription
        approvals.removeAll()
        answering.removeAll()
        turnID = nil
    }
}
