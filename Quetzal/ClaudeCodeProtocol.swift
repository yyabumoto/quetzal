import Foundation

nonisolated struct ClaudeCodeFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }

    static let malformed = Self("Claude Code sent an invalid message. Start a new session.")
    static let disconnected = Self("The Claude Code connection closed. Start a new session.")
}

nonisolated enum ClaudeCodeArguments {
    static func make(settings: ModelSettings, sessionID: String, project: ClaudeCodeProject) -> [String] {
        var arguments = ["--output-format", "stream-json", "--verbose", "--input-format", "stream-json"]
        if let effort = settings.effort { arguments += ["--effort", effort] }
        if let model = settings.model { arguments += ["--model", model] }
        arguments += ["--permission-prompt-tool", "stdio", "--include-partial-messages",
                      "--session-id", sessionID, "--disallowedTools", "AskUserQuestion",
                      // 作業先は信頼の確認を経ていないので、プロジェクトの設定（許可、フック、MCP）を読ませない。
                      "--setting-sources", "user"]
        var permissions: [String: JSON] = [:]
        if !project.deny.isEmpty { permissions["deny"] = .array(project.deny.map(JSON.string)) }
        if !project.ask.isEmpty { permissions["ask"] = .array(project.ask.map(JSON.string)) }
        if !permissions.isEmpty {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            if let data = try? encoder.encode(JSON.object(["permissions": .object(permissions)])) {
                arguments += ["--settings", String(decoding: data, as: UTF8.self)]
            }
        }
        return arguments
    }
}

nonisolated struct ClaudeCodeProject: Equatable, Sendable {
    /// initialize の appendSystemPrompt に入れる文字列。作業先の CLAUDE.md と .claude/CLAUDE.md がどちらもなければ nil。
    var instructions: String? = nil
    /// 作業先の permissions.deny と permissions.ask から取り出した規則。--settings で渡す。
    var deny: [String] = []
    var ask: [String] = []
    /// 作業先にあって、制限の規則のほかは適用しない設定ファイルの相対パス。
    var ignoredFiles: [String] = []
    /// JSON として読めず、制限の規則も取り出せなかった設定ファイルの相対パス。
    var unreadableFiles: [String] = []

    private static let sizeLimit = 1 << 20
    private static let pathTools: Set<String> = ["Read", "Edit", "Write", "MultiEdit", "NotebookEdit"]

    static func load(in worktree: URL) -> Self {
        var project = Self()
        let root = worktree.resolvingSymlinksInPath().standardizedFileURL.path
        let manager = FileManager.default
        let instructions = ["CLAUDE.md", ".claude/CLAUDE.md"].compactMap { name -> String? in
            let file = worktree.appendingPathComponent(name)
            guard let text = readInstructions(file, root: root) else { return nil }
            return "Contents of \(file.path) (project instructions, checked into the codebase):\n\n\(text)"
        }
        if !instructions.isEmpty { project.instructions = instructions.joined(separator: "\n\n") }
        for name in [".claude/settings.json", ".claude/settings.local.json", ".mcp.json"] {
            let path = worktree.appendingPathComponent(name).path
            guard (try? manager.attributesOfItem(atPath: path)) != nil else { continue }
            project.ignoredFiles.append(name)
            guard name != ".mcp.json" else { continue }
            guard let settings = readJSON(path) else {
                project.unreadableFiles.append(name)
                continue
            }
            let permissions = settings["permissions"]
            for rule in rules(permissions["deny"], root: root) where !project.deny.contains(rule) { project.deny.append(rule) }
            for rule in rules(permissions["ask"], root: root) where !project.ask.contains(rule) { project.ask.append(rule) }
        }
        return project
    }

    private static func readInstructions(_ file: URL, root: String) -> String? {
        let real = file.resolvingSymlinksInPath().standardizedFileURL.path
        // CLAUDE.md を AGENTS.md へのリンクにする使い方は残し、作業先の外のファイルはモデルに送らない。
        guard real.hasPrefix(root + "/"),
              let attributes = try? FileManager.default.attributesOfItem(atPath: real),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? Int, size <= sizeLimit,
              let data = FileManager.default.contents(atPath: real) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func readJSON(_ path: String) -> JSON? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: URL(fileURLWithPath: path).resolvingSymlinksInPath().path),
              let size = attributes[.size] as? Int, size <= sizeLimit,
              let data = FileManager.default.contents(atPath: path),
              String(data: data, encoding: .utf8) != nil else { return nil }
        return try? JSONDecoder().decode(JSON.self, from: data)
    }

    private static func rules(_ list: JSON, root: String) -> [String] {
        (list.elements ?? []).compactMap(\.text).map { rule in
            // --settings の規則は "/" で始まる型を一時ファイルのフォルダから解決するので、作業先の絶対パスにする。
            guard let open = rule.firstIndex(of: "("), rule.hasSuffix(")"),
                  pathTools.contains(String(rule[..<open])) else { return rule }
            let pattern = rule[rule.index(after: open)..<rule.index(before: rule.endIndex)]
            guard pattern.hasPrefix("/"), !pattern.hasPrefix("//") else { return rule }
            return "\(rule[..<open])(/\(root)\(pattern))"
        }
    }
}

/// stdout の 1 行。会話を切るのは、JSON でない行と、必須項目が欠けた制御メッセージだけ。
nonisolated enum ClaudeCodeMessage {
    case response(id: String, result: Result<JSON, ClaudeCodeFailure>)
    case request(id: String, request: JSON)
    case cancel(id: String)
    case initialized(cwd: String?, sessionID: String?)
    case hook(id: String, started: Bool)
    case stream(JSON)
    case assistant(JSON)
    case result(JSON)
    case ignored

    init(_ data: Data) throws {
        guard let message = try? JSONDecoder().decode(JSON.self, from: data) else { throw ClaudeCodeFailure.malformed }
        let mainThread = message["parent_tool_use_id"] == .null
        switch message["type"].text {
        case "control_response":
            let response = message["response"]
            guard let id = response["request_id"].text else { throw ClaudeCodeFailure.malformed }
            switch response["subtype"].text {
            case "success": self = .response(id: id, result: .success(response["response"]))
            case "error":
                let reason = response["error"].text ?? "Claude Code rejected the request."
                self = .response(id: id, result: .failure(ClaudeCodeFailure(reason)))
            default: throw ClaudeCodeFailure.malformed
            }
        case "control_request":
            guard let id = message["request_id"].text, message["request"]["subtype"].text != nil else {
                throw ClaudeCodeFailure.malformed
            }
            self = .request(id: id, request: message["request"])
        case "control_cancel_request":
            guard let id = message["request_id"].text else { throw ClaudeCodeFailure.malformed }
            self = .cancel(id: id)
        case "system":
            switch message["subtype"].text {
            case "init": self = .initialized(cwd: message["cwd"].text, sessionID: message["session_id"].text)
            case "hook_started", "hook_response":
                guard let id = message["hook_id"].text else { self = .ignored; return }
                self = .hook(id: id, started: message["subtype"].text == "hook_started")
            default: self = .ignored
            }
        case "stream_event" where mainThread: self = .stream(message["event"])
        case "assistant" where mainThread && message["message"]["model"].text != "<synthetic>":
            self = .assistant(message["message"])
        case "result": self = .result(message)
        default: self = .ignored
        }
    }

    static func completion(_ result: JSON, interrupted: Bool) -> (status: String, error: String?) {
        let subtype = result["subtype"].text ?? ""
        if subtype == "success" && result["is_error"] != .bool(true) { return ("completed", nil) }
        if subtype == "error_during_execution" && interrupted { return ("interrupted", nil) }
        let errors = (result["errors"].elements ?? []).compactMap(\.text)
        let reason = [result["result"].text, errors.isEmpty ? nil : errors.joined(separator: "\n"), subtype]
            .compactMap { $0 }.first { !$0.isEmpty }
        return ("failed", reason)
    }
}

/// ストリームの文字の差分と、後から届く完成したブロックを同じ項目に対応づける。
nonisolated struct ClaudeTextBlocks {
    private var message: String?
    private var waiting: [String: [String]] = [:]
    private var extra = 0

    mutating func stream(_ event: JSON) -> (item: String, text: String)? {
        switch event["type"].text {
        case "message_start":
            message = event["message"]["id"].text
        case "content_block_start" where event["content_block"]["type"].text == "text":
            guard let message, case .integer(let index) = event["index"] else { return nil }
            waiting[message, default: []].append("\(message):\(index)")
        case "content_block_delta" where event["delta"]["type"].text == "text_delta":
            guard let message, case .integer(let index) = event["index"], let text = event["delta"]["text"].text else { return nil }
            return ("\(message):\(index)", text)
        default: break
        }
        return nil
    }

    mutating func assistant(_ message: JSON) -> [(item: String, text: String)] {
        guard let id = message["id"].text else { return [] }
        return (message["content"].elements ?? []).compactMap { block in
            guard block["type"].text == "text", let text = block["text"].text else { return nil }
            if let item = waiting[id]?.first {
                waiting[id]?.removeFirst()
                return (item, text)
            }
            extra += 1
            return ("\(id):final-\(extra)", text)
        }
    }

    mutating func reset() {
        message = nil
        waiting.removeAll()
    }
}
