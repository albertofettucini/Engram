import Foundation
import Engram

// engram-mcp — a minimal, zero-dependency MCP server over stdio (newline-delimited JSON-RPC 2.0).
// Claude Desktop / Claude Code launch this as a subprocess and call its two tools:
//   • remember(text, tags?, conversation?)  — write a memory
//   • recall(query, scope?, conversation?, k?) — semantic top-k ("ortak akıl" = scope "all")
//
// Protocol notes: stdout carries ONLY JSON-RPC messages (one per line); all logging goes to stderr
// so it never corrupts the stream. Notifications (no "id") get no reply.

// MARK: - Engine

func memoriesRoot() -> URL { CombinedFileStore.defaultMemoriesRoot() }   // one shared definition (honors ENGRAM_ROOT)

func log(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

// MARK: - One-click connect (engram-mcp --connect)
// Writes/merges this server into Claude Desktop's config so the user NEVER edits JSON by hand.
// Preserves any other MCP servers already configured.

func installToClaudeDesktop() {
    let configPath: String
    if let env = ProcessInfo.processInfo.environment["ENGRAM_CLAUDE_CONFIG"], !env.isEmpty {
        configPath = env
    } else {
        configPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json").path
    }

    var p = CommandLine.arguments[0]
    if !p.hasPrefix("/") { p = FileManager.default.currentDirectoryPath + "/" + p }
    let binaryPath = URL(fileURLWithPath: p).resolvingSymlinksInPath().path

    var root: [String: Any] = [:]
    if let data = FileManager.default.contents(atPath: configPath) {
        // The file EXISTS. If it's present but NOT valid JSON, overwriting it would wipe the user's other
        // MCP servers — so back it up and bail instead of clobbering.
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            let bak = configPath + ".engram-backup"
            try? data.write(to: URL(fileURLWithPath: bak))
            log("engram-mcp: existing config is not valid JSON — left untouched (backup at \(bak))")
            print("Your Claude Desktop config isn't valid JSON, so I didn't touch it (backed it up to \(bak)). Fix it, then re-run --connect.")
            exit(1)
        }
        root = obj   // keep everything the user already has
    }
    var servers = root["mcpServers"] as? [String: Any] ?? [:]
    servers["engram"] = ["command": binaryPath]
    root["mcpServers"] = servers

    do {
        try FileManager.default.createDirectory(
            atPath: (configPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try out.write(to: URL(fileURLWithPath: configPath), options: .atomic)   // atomic — never leave a truncated config
        log("engram-mcp: connected → \(configPath) (command = \(binaryPath))")
        print("Connected to Claude Desktop. Restart Claude Desktop to load Engram.")
    } catch {
        log("engram-mcp: connect FAILED: \(error)")
        print("Connect failed: \(error.localizedDescription)")
        exit(1)
    }
}

if CommandLine.arguments.contains("--connect") {
    installToClaudeDesktop()
    exit(0)
}

// One-time, opt-in fetch of Apple's transformer embedding model (the only path that touches the
// network). After this, recall uses the better model with zero runtime network.
if CommandLine.arguments.contains("--prepare-embeddings") {
    print(NLContextualEmbeddingProvider.prepare())
    exit(0)
}

let engine: MemoryEngine
do {
    let root = memoriesRoot()
    engine = try MemoryEngine(root: root, embedder: NLContextualEmbeddingProvider())   // transformer if present, else word embedder — no runtime network
    log("engram-mcp: ready · store = \(root.path)")
} catch {
    log("engram-mcp: FATAL could not open store: \(error)")
    exit(1)
}

// MARK: - JSON-RPC plumbing

func send(_ message: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: message),
          let line = String(data: data, encoding: .utf8) else { return }
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
}

func reply(id: Any, result: [String: Any]) {
    send(["jsonrpc": "2.0", "id": id, "result": result])
}
func replyError(id: Any, code: Int, _ message: String) {
    send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
}
func textResult(_ text: String) -> [String: Any] {
    ["content": [["type": "text", "text": text]]]
}
/// A tool result flagged as an error, so MCP clients can distinguish failure from success.
func errorResult(_ text: String) -> [String: Any] {
    ["content": [["type": "text", "text": text]], "isError": true]
}

// MARK: - Tool definitions (advertised via tools/list)

let toolDefs: [[String: Any]] = [
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

// MARK: - Tool dispatch

func callTool(_ name: String, _ args: [String: Any]) -> [String: Any] {
    switch name {
    case "remember":
        guard let text = (args["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return errorResult("Nothing to remember: 'text' was empty.")
        }
        let tags = (args["tags"] as? [String]) ?? []
        let conversation = (args["conversation"] as? String) ?? "claude-desktop"
        do {
            let m = try engine.remember(text, tags: tags, source: "claude-desktop", conversation: conversation)
            return textResult("Remembered (id \(m.id.uuidString.prefix(8)), conversation \"\(conversation)\").")
        } catch {
            return errorResult("Could not save memory: \(error.localizedDescription)")
        }

    case "recall":
        guard let query = (args["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
            return errorResult("Nothing to recall: 'query' was empty.")
        }
        let k = max(0, min((args["k"] as? Int) ?? 5, 100))   // clamp: a negative k would crash; cap a runaway request
        let scope: RecallScope
        switch (args["scope"] as? String) {
        case "conversation":
            guard let conv = (args["conversation"] as? String), !conv.trimmingCharacters(in: .whitespaces).isEmpty else {
                return errorResult("scope 'conversation' requires a non-empty 'conversation' id.")   // don't silently widen to 'all'
            }
            scope = .conversation(conv)
        case "file":
            guard let fileName = (args["file"] as? String), !fileName.trimmingCharacters(in: .whitespaces).isEmpty else {
                return errorResult("scope 'file' requires a non-empty 'file' name.")
            }
            let root = memoriesRoot()
            let matches = CombinedFileStore.files(named: fileName, memoriesRoot: root)
            if matches.isEmpty {
                let names = CombinedFileStore.load(memoriesRoot: root).map { "\"\($0.name)\"" }
                let avail = names.isEmpty ? "There are no combined files yet." : "Available files: \(names.joined(separator: ", "))."
                return errorResult("No combined file named \"\(fileName)\". \(avail)")
            }
            if matches.count > 1 {
                return errorResult("There are \(matches.count) combined files named \"\(fileName)\" — rename one so the scope is unambiguous.")
            }
            scope = .conversations(matches[0].conversations)
        default:
            scope = .all
        }
        let hits = engine.recall(query, scope: scope, k: k)
        if hits.isEmpty { return textResult("No relevant memories found.") }
        let body = hits.enumerated().map { i, h in
            "\(i + 1). \(h.memory.content)  —  [from \"\(h.conversationID)\", source: \(h.memory.source)]"
        }.joined(separator: "\n")
        return textResult("Relevant memories:\n\(body)")

    default:
        return errorResult("Unknown tool: \(name)")
    }
}

// MARK: - Main loop

while let line = readLine(strippingNewline: true) {
    if line.isEmpty { continue }
    guard let data = line.data(using: .utf8),
          let msg = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
        log("engram-mcp: skipped unparseable line")
        continue
    }
    let method = msg["method"] as? String ?? ""
    let id = msg["id"]   // absent for notifications

    switch method {
    case "initialize":
        let clientVersion = (msg["params"] as? [String: Any])?["protocolVersion"] as? String ?? "2024-11-05"
        if let id {
            reply(id: id, result: [
                "protocolVersion": clientVersion,
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "engram", "version": "0.1.0"],
            ])
        }

    case "tools/list":
        if let id { reply(id: id, result: ["tools": toolDefs]) }

    case "tools/call":
        guard let id else { break }
        let params = msg["params"] as? [String: Any] ?? [:]
        let name = params["name"] as? String ?? ""
        let args = params["arguments"] as? [String: Any] ?? [:]
        reply(id: id, result: callTool(name, args))

    case "ping":
        if let id { reply(id: id, result: [:]) }

    default:
        // Notifications (e.g. notifications/initialized) and unknown methods: ignore unless they need a reply.
        if let id, !method.isEmpty {
            replyError(id: id, code: -32601, "Method not found: \(method)")
        }
    }
}
