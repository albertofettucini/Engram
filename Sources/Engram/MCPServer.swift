import Foundation

/// The MCP protocol handler: one parsed JSON-RPC message in, the reply out (nil for notifications).
/// It lives in the library — not in the engram-mcp executable — so every method is unit-tested; the
/// executable keeps only the stdin/stdout loop and the command-line flags.
public final class MCPServer {
    /// Protocol versions this server speaks, newest first.
    public static let supportedProtocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    public static var latestProtocolVersion: String { supportedProtocolVersions[0] }

    public let engine: MemoryEngine
    /// The memories folder — combined files (recall scope 'file') are looked up next to it.
    public let root: URL
    /// Who is talking to us, from initialize's clientInfo.name. Tags every memory this client writes.
    public private(set) var clientSource = "mcp"

    public init(engine: MemoryEngine, root: URL) {
        self.engine = engine
        self.root = root
    }

    // MARK: Dispatch

    public func handle(_ message: [String: Any]) -> [String: Any]? {
        let method = message["method"] as? String ?? ""
        let id = message["id"]   // absent for notifications
        let params = message["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            let clientInfo = params["clientInfo"] as? [String: Any]
            clientSource = Self.source(forClientName: clientInfo?["name"] as? String)
            guard let id else { return nil }
            return reply(id, [
                "protocolVersion": Self.negotiate(params["protocolVersion"] as? String),
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "engram", "version": EngramVersion.current],
            ])

        case "tools/list":
            guard let id else { return nil }
            return reply(id, ["tools": Self.toolDefinitions])

        case "tools/call":
            guard let id else { return nil }
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            return reply(id, callTool(name, args))

        case "ping":
            guard let id else { return nil }
            return reply(id, [:])

        default:
            // Notifications (e.g. notifications/initialized) and unknown methods: ignore unless they need a reply.
            guard let id, !method.isEmpty else { return nil }
            return ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found: \(method)"]]
        }
    }

    // MARK: Negotiation & provenance

    /// Echo the client's version when we speak it; otherwise answer with our newest (the client then
    /// decides whether it can continue — never blindly claim a version we don't implement).
    public static func negotiate(_ requested: String?) -> String {
        if let requested, supportedProtocolVersions.contains(requested) { return requested }
        return latestProtocolVersion
    }

    /// clientInfo.name → the memory's `source`. Claude Desktop identifies as "claude-ai"; Claude Code as
    /// "claude-code". Anything else is lowercased and reduced to [a-z0-9-] (runs of other characters become
    /// one '-'), at most 40 characters. No usable name → "mcp".
    public static func source(forClientName name: String?) -> String {
        let lower = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch lower {
        case "claude-ai": return "claude-desktop"
        case "claude-code": return "claude-code"
        default: break
        }
        var out = ""
        var pendingDash = false
        for scalar in lower.unicodeScalars {
            let isAllowed = ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar)
            if isAllowed {
                if pendingDash && !out.isEmpty { out.append("-") }
                pendingDash = false
                out.unicodeScalars.append(scalar)
            } else {
                pendingDash = true
            }
        }
        out = String(out.prefix(40))
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "mcp" : out
    }

    // MARK: Tool definitions (advertised via tools/list) — keep byte-identical unless a tool really changes.

    public static let toolDefinitions: [[String: Any]] = [
        [
            "name": "remember",
            "description": "Save a durable fact, preference, decision, or piece of context to the user's local memory so it can be recalled in future sessions.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "text": ["type": "string", "description": "The fact to remember, in a self-contained sentence."],
                    "tags": ["type": "array", "items": ["type": "string"], "description": "Optional tags."],
                    "conversation": ["type": "string", "description": "Optional conversation id; groups memories into one file."],
                ],
                "required": ["text"],
            ],
        ],
        [
            "name": "recall",
            "description": "Search the user's local memory and return the most relevant remembered facts. Call this before answering when prior context about the user might help. Note: with the default scope 'all' this searches across EVERY conversation, so results may include personal context from other chats.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "What to look up."],
                    "scope": ["type": "string", "enum": ["all", "conversation", "file"], "description": "'all' = collective memory across every conversation (default); 'conversation' = only the given conversation; 'file' = only the conversations inside a user-made combined file (pass its name in 'file')."],
                    "conversation": ["type": "string", "description": "Required when scope is 'conversation'."],
                    "file": ["type": "string", "description": "Required when scope is 'file' — the name of a combined file to search within."],
                    "k": ["type": "integer", "description": "How many results (default 5)."],
                ],
                "required": ["query"],
            ],
        ],
    ]

    // MARK: Tools

    func callTool(_ name: String, _ args: [String: Any]) -> [String: Any] {
        switch name {
        case "remember":
            guard let text = (args["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                return Self.errorResult("Nothing to remember: 'text' was empty.")
            }
            let tags = (args["tags"] as? [String]) ?? []
            let conversation = (args["conversation"] as? String) ?? clientSource
            do {
                let m = try engine.remember(text, tags: tags, source: clientSource, conversation: conversation)
                return Self.textResult("Remembered (id \(m.id.uuidString.prefix(8)), conversation \"\(conversation)\").")
            } catch {
                return Self.errorResult("Could not save memory: \(error.localizedDescription)")
            }

        case "recall":
            guard let query = (args["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
                return Self.errorResult("Nothing to recall: 'query' was empty.")
            }
            let k = max(0, min((args["k"] as? Int) ?? 5, 100))   // clamp: a negative k would crash; cap a runaway request
            let scope: RecallScope
            switch (args["scope"] as? String) {
            case "conversation":
                guard let conv = (args["conversation"] as? String), !conv.trimmingCharacters(in: .whitespaces).isEmpty else {
                    return Self.errorResult("scope 'conversation' requires a non-empty 'conversation' id.")   // don't silently widen to 'all'
                }
                scope = .conversation(conv)
            case "file":
                guard let fileName = (args["file"] as? String), !fileName.trimmingCharacters(in: .whitespaces).isEmpty else {
                    return Self.errorResult("scope 'file' requires a non-empty 'file' name.")
                }
                let matches = CombinedFileStore.files(named: fileName, memoriesRoot: root)
                if matches.isEmpty {
                    let names = CombinedFileStore.load(memoriesRoot: root).map { "\"\($0.name)\"" }
                    let avail = names.isEmpty ? "There are no combined files yet." : "Available files: \(names.joined(separator: ", "))."
                    return Self.errorResult("No combined file named \"\(fileName)\". \(avail)")
                }
                if matches.count > 1 {
                    return Self.errorResult("There are \(matches.count) combined files named \"\(fileName)\" — rename one so the scope is unambiguous.")
                }
                scope = .conversations(matches[0].conversations)
            default:
                scope = .all
            }
            let hits = engine.recall(query, scope: scope, k: k)
            if hits.isEmpty { return Self.textResult("No relevant memories found.") }
            let body = hits.enumerated().map { i, h in
                "\(i + 1). \(h.memory.content)  —  [from \"\(h.conversationID)\", source: \(h.memory.source)]"
            }.joined(separator: "\n")
            return Self.textResult("Relevant memories:\n\(body)")

        default:
            return Self.errorResult("Unknown tool: \(name)")
        }
    }

    // MARK: Helpers

    private func reply(_ id: Any, _ result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    static func textResult(_ text: String) -> [String: Any] {
        ["content": [["type": "text", "text": text]]]
    }

    /// A tool result flagged as an error, so MCP clients can distinguish failure from success.
    static func errorResult(_ text: String) -> [String: Any] {
        ["content": [["type": "text", "text": text]], "isError": true]
    }
}
