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
// Preserves any other MCP servers already configured. The decisions (which path, how to merge, did the
// write land) live in the library's Connector so they're unit-tested; this only prints.

if CommandLine.arguments.contains("--connect") {
    let report = Connector(env: HostEnvironment.current()).run(argv0: CommandLine.arguments[0])
    for line in report.logs { log(line) }
    for line in report.messages { print(line) }
    exit(report.failed ? 1 : 0)
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

// MARK: - JSON-RPC over stdio
// The protocol itself (methods, tools, version negotiation, client provenance) is MCPServer in the
// library, where it's unit-tested. This loop only moves lines between stdin/stdout and the handler.

func send(_ message: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: message),
          let line = String(data: data, encoding: .utf8) else { return }
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
}

let server = MCPServer(engine: engine, root: memoriesRoot())

while let line = readLine(strippingNewline: true) {
    if line.isEmpty { continue }
    guard let data = line.data(using: .utf8),
          let msg = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
        log("engram-mcp: skipped unparseable line")
        continue
    }
    if let response = server.handle(msg) { send(response) }
}
