import Foundation

nonisolated enum JSON: Codable, Equatable, Sendable {
    case object([String: Self]), array([Self]), string(String), integer(Int64), number(Double), bool(Bool), null

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let bool = try? value.decode(Bool.self) { self = .bool(bool) }
        else if let integer = try? value.decode(Int64.self) { self = .integer(integer) }
        else if let number = try? value.decode(Double.self) { self = .number(number) }
        else if let string = try? value.decode(String.self) { self = .string(string) }
        else if let array = try? value.decode([Self].self) { self = .array(array) }
        else { self = .object(try value.decode([String: Self].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .object(let object): try value.encode(object)
        case .array(let array): try value.encode(array)
        case .string(let string): try value.encode(string)
        case .integer(let integer): try value.encode(integer)
        case .number(let number): try value.encode(number)
        case .bool(let bool): try value.encode(bool)
        case .null: try value.encodeNil()
        }
    }

    var fields: [String: Self]? { if case .object(let value) = self { value } else { nil } }
    var elements: [Self]? { if case .array(let value) = self { value } else { nil } }
    var text: String? { if case .string(let value) = self { value } else { nil } }
    subscript(key: String) -> Self { fields?[key] ?? .null }

    var formatted: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? String(decoding: encoder.encode(self), as: UTF8.self)) ?? ""
    }
}

nonisolated struct CodexFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }

    static let malformed = Self("Codex sent an invalid message. Start a new session.")
    static let disconnected = Self("The Codex connection closed. Start a new session.")
}

nonisolated enum RequestID: Hashable, Sendable {
    case integer(Int64), string(String)

    init?(_ json: JSON) {
        switch json {
        case .integer(let id): self = .integer(id)
        case .string(let id): self = .string(id)
        default: return nil
        }
    }

    var json: JSON {
        switch self {
        case .integer(let id): .integer(id)
        case .string(let id): .string(id)
        }
    }
}

nonisolated struct ItemKey: Hashable, Sendable {
    let thread: String
    let turn: String
    let item: String
}

nonisolated struct FileChange: Equatable, Sendable {
    let path: String
    let operation: String
    let destination: String?

    init?(path: String?, kind: JSON) {
        guard let path, !path.isEmpty, let type = kind["type"].text,
              ["add", "delete", "update"].contains(type) else { return nil }
        self.path = path
        operation = type
        destination = kind["move_path"].text
    }

    var summary: String {
        "\(operation.capitalized): \(path)" + (destination.map { " → \($0)" } ?? "")
    }
}

nonisolated struct ApprovalRequest: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable {
        case command = "item/commandExecution/requestApproval"
        case file = "item/fileChange/requestApproval"
        case permissions = "item/permissions/requestApproval"
        case legacyCommand = "execCommandApproval"
        case legacyFile = "applyPatchApproval"
    }

    let id: RequestID
    let kind: Kind
    let key: ItemKey
    let params: JSON
    var changes: [FileChange] = []

    var title: String {
        switch kind {
        case .command:
            switch params["kind"].text ?? "command" {
            case "command": return "Run command"
            case "writeStdin": return "Send input to terminal"
            default: return "Unknown command operation"
            }
        case .legacyCommand: return "Run command"
        case .file, .legacyFile: return "Change files"
        case .permissions: return "Grant permissions for this turn"
        }
    }

    private var command: String? {
        if kind == .legacyCommand { return params["command"].elements?.map(\.formatted).joined(separator: " ") }
        return params["command"].text
    }

    private var connection: String? {
        let network = params["networkApprovalContext"]
        guard let host = network["host"].text, !host.isEmpty,
              let scheme = network["protocol"].text, !scheme.isEmpty else { return nil }
        return "\(scheme)://\(host)"
    }

    var details: [String] {
        var rows: [String] = []
        if let command, !command.isEmpty { rows.append(command) }
        if let cwd = params["cwd"].text { rows.append("Working directory: \(cwd)") }
        if let connection { rows.append("Connection: \(connection)") }
        if kind == .permissions { rows.append(params["permissions"].formatted) }
        if kind == .file || kind == .legacyFile {
            rows += changes.isEmpty ? ["File targets unavailable"] : changes.map(\.summary)
            if let root = params["grantRoot"].text { rows.append("Write access for this session: \(root)") }
        }
        if let reason = params["reason"].text { rows.append(reason) }
        return rows
    }

    var canAllow: Bool {
        switch kind {
        case .command:
            let known = ["command", "writeStdin"].contains(params["kind"].text ?? "command")
            let network = params["networkApprovalContext"]
            return known && (network == .null || connection != nil) && (hasCommand || connection != nil)
        case .legacyCommand: return hasCommand
        case .file, .legacyFile: return !changes.isEmpty
        case .permissions: return params["permissions"].fields?.isEmpty == false
        }
    }

    private var hasCommand: Bool {
        command?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    func result(allow: Bool) throws -> JSON {
        guard !allow || canAllow else { throw CodexFailure("Approval details are unavailable.") }
        switch kind {
        case .command, .file: return .object(["decision": .string(allow ? "accept" : "decline")])
        case .permissions:
            return .object(["permissions": allow ? params["permissions"] : .object([:]), "scope": .string("turn")])
        case .legacyCommand, .legacyFile:
            let denied: JSON = .object(["denied": .object(["rejection": .string("Declined by user")])])
            return .object(["decision": allow ? .string("approved") : denied])
        }
    }
}

nonisolated enum CodexEvent: Sendable {
    case started(thread: String, turn: String)
    case completed(thread: String, turn: String, status: String, error: String?)
    case message(ItemKey, text: String, final: Bool)
    case approval(ApprovalRequest)
    case resolved(thread: String, id: RequestID)
    case changes(ItemKey, [FileChange])
    case error(thread: String, turn: String, message: String, retrying: Bool)

    static func notification(_ method: String, _ p: JSON) throws -> Self? {
        let supported = ["turn/started", "turn/completed", "item/started", "item/completed",
                         "item/agentMessage/delta", "item/fileChange/patchUpdated", "error", "serverRequest/resolved"]
        guard supported.contains(method) else { return nil }
        guard let thread = p["threadId"].text else { throw CodexFailure.malformed }
        if method == "serverRequest/resolved" {
            guard let id = RequestID(p["requestId"]) else { throw CodexFailure.malformed }
            return .resolved(thread: thread, id: id)
        }
        if method.hasPrefix("turn/") {
            guard let turn = p["turn"]["id"].text else { throw CodexFailure.malformed }
            if method == "turn/started" { return .started(thread: thread, turn: turn) }
            guard let status = p["turn"]["status"].text,
                  ["completed", "failed", "interrupted"].contains(status) else { throw CodexFailure.malformed }
            return .completed(thread: thread, turn: turn, status: status, error: p["turn"]["error"]["message"].text)
        }
        guard let turn = p["turnId"].text else { throw CodexFailure.malformed }
        if method == "error" {
            guard let message = p["error"]["message"].text else { throw CodexFailure.malformed }
            return .error(thread: thread, turn: turn, message: message, retrying: p["willRetry"] == .bool(true))
        }
        let item = p["item"]
        guard let id = p["itemId"].text ?? item["id"].text else { throw CodexFailure.malformed }
        let key = ItemKey(thread: thread, turn: turn, item: id)
        switch method {
        case "item/agentMessage/delta":
            guard let text = p["delta"].text else { throw CodexFailure.malformed }
            return .message(key, text: text, final: false)
        case "item/completed" where item["type"].text == "agentMessage":
            guard let text = item["text"].text else { throw CodexFailure.malformed }
            return .message(key, text: text, final: true)
        case "item/started" where item["type"].text == "fileChange", "item/fileChange/patchUpdated":
            let entries = (method == "item/started" ? item : p)["changes"].elements ?? []
            let changes = entries.compactMap { FileChange(path: $0["path"].text, kind: $0["kind"]) }
            return .changes(key, changes.count == entries.count ? changes : [])
        default: return nil
        }
    }
}
