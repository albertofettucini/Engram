import XCTest
@testable import Engram

/// The MCP protocol handler, driven message by message (no stdio, no subprocess).
final class MCPServerTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-mcp-test-" + UUID().uuidString)
            .appendingPathComponent("memories")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    private func makeServer() throws -> MCPServer {
        MCPServer(engine: try MemoryEngine(root: root), root: root)
    }

    private func initialize(_ server: MCPServer, version: String? = "2025-06-18", client: String?) -> [String: Any] {
        var params: [String: Any] = [:]
        if let version { params["protocolVersion"] = version }
        if let client { params["clientInfo"] = ["name": client, "version": "1.0"] }
        let reply = server.handle(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": params])
        return (reply?["result"] as? [String: Any]) ?? [:]
    }

    private func call(_ server: MCPServer, _ tool: String, _ args: [String: Any]) -> (text: String, isError: Bool) {
        let reply = server.handle(["jsonrpc": "2.0", "id": 7, "method": "tools/call",
                                   "params": ["name": tool, "arguments": args]])
        let result = reply?["result"] as? [String: Any] ?? [:]
        let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        return (text, (result["isError"] as? Bool) ?? false)
    }

    // MARK: provenance

    /// A Claude Code session's memories are tagged claude-code (0.1.0 tagged everything claude-desktop).
    func testClaudeCodeClientTagsRemember() throws {
        let server = try makeServer()
        _ = initialize(server, client: "claude-code")
        let r = call(server, "remember", ["text": "The staging database is called pelican."])
        XCTAssertFalse(r.isError, r.text)

        let mems = server.engine.store.allMemories()
        XCTAssertEqual(mems.map(\.source), ["claude-code"])
        XCTAssertEqual(mems.map(\.conversationID), ["claude-code"])   // default conversation follows the client
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("claude-code.md").path))
    }

    func testClaudeDesktopAndExplicitConversation() throws {
        let server = try makeServer()
        _ = initialize(server, client: "claude-ai")
        _ = call(server, "remember", ["text": "Prefers metric units.", "conversation": "trip-planning"])
        let m = try XCTUnwrap(server.engine.store.allMemories().first)
        XCTAssertEqual(m.source, "claude-desktop")
        XCTAssertEqual(m.conversationID, "trip-planning")
    }

    func testClientNameMapping() {
        XCTAssertEqual(MCPServer.source(forClientName: "claude-ai"), "claude-desktop")
        XCTAssertEqual(MCPServer.source(forClientName: "claude-code"), "claude-code")
        XCTAssertEqual(MCPServer.source(forClientName: "Claude-Code"), "claude-code")
        XCTAssertEqual(MCPServer.source(forClientName: "cursor-vscode"), "cursor-vscode")
        XCTAssertEqual(MCPServer.source(forClientName: "Visual Studio Code!"), "visual-studio-code")
        XCTAssertEqual(MCPServer.source(forClientName: "  Zed_Editor 2.0 "), "zed-editor-2-0")
        XCTAssertEqual(MCPServer.source(forClientName: String(repeating: "a", count: 60)), String(repeating: "a", count: 40))
        XCTAssertEqual(MCPServer.source(forClientName: "日本語"), "mcp")
        XCTAssertEqual(MCPServer.source(forClientName: ""), "mcp")
        XCTAssertEqual(MCPServer.source(forClientName: nil), "mcp")
    }

    func testMissingClientInfoBecomesMCP() throws {
        let server = try makeServer()
        _ = call(server, "remember", ["text": "Written before any initialize."])
        _ = initialize(server, client: nil)
        _ = call(server, "remember", ["text": "Written by a client with no clientInfo."])
        XCTAssertEqual(Set(server.engine.store.allMemories().map(\.source)), ["mcp"])
    }

    // MARK: initialize

    func testServerInfoVersionIsTheConstant() throws {
        let result = initialize(try makeServer(), client: "claude-code")
        let info = try XCTUnwrap(result["serverInfo"] as? [String: Any])
        XCTAssertEqual(info["name"] as? String, "engram")
        XCTAssertEqual(info["version"] as? String, EngramVersion.current)
        XCTAssertNotNil((result["capabilities"] as? [String: Any])?["tools"])
    }

    func testProtocolVersionNegotiation() throws {
        let server = try makeServer()
        for v in ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"] {
            XCTAssertEqual(initialize(server, version: v, client: "x")["protocolVersion"] as? String, v)
        }
        // Never blindly echo a version we don't implement.
        XCTAssertEqual(initialize(server, version: "2099-01-01", client: "x")["protocolVersion"] as? String, "2025-11-25")
        XCTAssertEqual(initialize(server, version: nil, client: "x")["protocolVersion"] as? String, "2025-11-25")
    }

    // MARK: tools/list

    /// The advertised tools are exactly what 0.1.0 advertised (captured from the 0.1.0 binary, sorted keys).
    func testToolsListUnchangedFrom010() throws {
        let golden = #"""
[{"description":"Save a durable fact, preference, decision, or piece of context to the user's local memory so it can be recalled in future sessions.","inputSchema":{"properties":{"conversation":{"description":"Optional conversation id; groups memories into one file.","type":"string"},"tags":{"description":"Optional tags.","items":{"type":"string"},"type":"array"},"text":{"description":"The fact to remember, in a self-contained sentence.","type":"string"}},"required":["text"],"type":"object"},"name":"remember"},{"description":"Search the user's local memory and return the most relevant remembered facts. Call this before answering when prior context about the user might help. Note: with the default scope 'all' this searches across EVERY conversation, so results may include personal context from other chats.","inputSchema":{"properties":{"conversation":{"description":"Required when scope is 'conversation'.","type":"string"},"file":{"description":"Required when scope is 'file' — the name of a combined file to search within.","type":"string"},"k":{"description":"How many results (default 5).","type":"integer"},"query":{"description":"What to look up.","type":"string"},"scope":{"description":"'all' = collective memory across every conversation (default); 'conversation' = only the given conversation; 'file' = only the conversations inside a user-made combined file (pass its name in 'file').","enum":["all","conversation","file"],"type":"string"}},"required":["query"],"type":"object"},"name":"recall"}]
"""#
        let expected = try JSONSerialization.jsonObject(with: Data(golden.utf8)) as? NSArray
        let reply = try XCTUnwrap(try makeServer().handle(["jsonrpc": "2.0", "id": 2, "method": "tools/list"]))
        let tools = (reply["result"] as? [String: Any])?["tools"]
        // Round-trip through JSON so the comparison is on what goes over the wire.
        let wire = try JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: tools as Any)) as? NSArray
        XCTAssertEqual(wire, expected)
    }

    // MARK: other methods

    func testPingNotificationsAndUnknownMethods() throws {
        let server = try makeServer()
        let ping = try XCTUnwrap(server.handle(["jsonrpc": "2.0", "id": "p1", "method": "ping"]))
        XCTAssertEqual(ping["id"] as? String, "p1")
        XCTAssertEqual((ping["result"] as? [String: Any])?.isEmpty, true)

        XCTAssertNil(server.handle(["jsonrpc": "2.0", "method": "notifications/initialized"]))
        XCTAssertNil(server.handle(["jsonrpc": "2.0", "method": "tools/list"]))   // no id → no reply
        XCTAssertNil(server.handle(["jsonrpc": "2.0", "id": 4, "result": [:]]))     // a response, not a request

        let unknown = try XCTUnwrap(server.handle(["jsonrpc": "2.0", "id": 9, "method": "server/discover"]))
        XCTAssertEqual((unknown["error"] as? [String: Any])?["code"] as? Int, -32601)
    }

    func testRecallThroughTheHandler() throws {
        let server = try makeServer()
        _ = initialize(server, client: "claude-code")
        _ = call(server, "remember", ["text": "The deploy script lives in tools/deploy.sh"])
        let hit = call(server, "recall", ["query": "how do I deploy"])
        XCTAssertFalse(hit.isError)
        XCTAssertTrue(hit.text.hasPrefix("Relevant memories:\n1. The deploy script lives in tools/deploy.sh"), hit.text)
        XCTAssertTrue(hit.text.contains("source: claude-code"))

        XCTAssertTrue(call(server, "recall", ["query": "x", "scope": "conversation"]).isError)
        XCTAssertTrue(call(server, "recall", ["query": "x", "scope": "file", "file": "nope"]).isError)
        XCTAssertTrue(call(server, "remember", ["text": "   "]).isError)
        XCTAssertTrue(call(server, "forget", [:]).isError)
    }
}
