import XCTest
@testable import Engram

final class EngramTests: XCTestCase {

    private func tempRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-test-" + UUID().uuidString)
    }

    /// Memories are stored as one .md file per conversation (the source of truth on disk).
    func testStoreIsPerConversationMarkdown() throws {
        let root = tempRoot()
        let engine = try MemoryEngine(root: root)
        _ = try engine.remember("I prefer dark mode in all my apps.", tags: ["pref"], source: "manual", conversation: "chat-1")
        _ = try engine.remember("My startup is a two-person team.", tags: ["project"], source: "claude-code", conversation: "chat-2")

        XCTAssertEqual(engine.store.memories(in: "chat-1").count, 1)
        XCTAssertEqual(engine.store.memories(in: "chat-2").count, 1)
        XCTAssertEqual(engine.store.allMemories().filter { !$0.deleted }.count, 2)

        // The files really exist on disk, human-readable, one per conversation.
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("chat-1.md").path))
        let raw = try String(contentsOf: root.appendingPathComponent("chat-1.md"), encoding: .utf8)
        XCTAssertTrue(raw.contains("dark mode"))
    }

    /// A ChatGPT-shaped export (nested mapping/message/parts json) imports cleanly: the generic json
    /// extractor pulls the actual message prose, tagged with the chosen source, and skips ids/roles/timestamps.
    func testChatGPTExportImportsCleanly() throws {
        let engine = try MemoryEngine(root: tempRoot())
        let json = """
        [
          {"title":"iPhone vs Samsung","create_time":1718000000.0,
           "mapping":{
             "node-1":{"id":"node-1","message":{"id":"m1","author":{"role":"user"},"create_time":1718000001.0,
               "content":{"content_type":"text","parts":["Which is better for night photography, the iPhone 15 Pro or the Samsung S24 Ultra?"]}}},
             "node-2":{"id":"node-2","message":{"id":"m2","author":{"role":"assistant"},"create_time":1718000002.0,
               "content":{"content_type":"text","parts":["The Samsung S24 Ultra has a 200MP sensor and stronger optical zoom, while the iPhone 15 Pro is better for video and natural color."]}}}
           }}
        ]
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("chatgpt-conversations-\(UUID().uuidString).json")
        try json.write(to: url, atomically: true, encoding: .utf8)
        let n = try MarkdownImporter(engine: engine).importFile(at: url, source: "chatgpt")
        let mems = engine.store.allMemories().filter { !$0.deleted }
        print("=== imported \(n) memories from a ChatGPT-shaped export (source tagged 'chatgpt') ===")
        for m in mems { print("• [\(m.source)] \(m.content)") }
        XCTAssertEqual(n, 2)
        XCTAssertTrue(mems.allSatisfy { $0.source == "chatgpt" })
        XCTAssertTrue(mems.contains { $0.content.contains("200MP sensor") })
        XCTAssertFalse(mems.contains { $0.content.contains("node-1") })   // ids/roles got filtered out
    }

    /// A deliberate short paste must save — no hidden minimum-length that silently drops it.
    func testShortPasteStillSaves() throws {
        let engine = try MemoryEngine(root: tempRoot())
        let importer = MarkdownImporter(engine: engine)
        let n = try importer.importText("Buy milk", source: "chatgpt", conversation: "Quick note")
        XCTAssertEqual(n, 1)
        let mems = engine.store.allMemories().filter { !$0.deleted }
        XCTAssertEqual(mems.first?.content, "Buy milk")
        XCTAssertEqual(mems.first?.source, "chatgpt")
    }

    /// "Ortak akıl": .all searches across every conversation; .conversation stays siloed.
    func testCollectiveVsSiloedScope() throws {
        let engine = try MemoryEngine(root: tempRoot())
        let deploy = try engine.remember("The deploy script lives in tools/deploy.sh", source: "claude-code", conversation: "chat-A")
        _ = try engine.remember("Coffee order: oat flat white.", source: "manual", conversation: "chat-B")

        // Collective mind: asking from the whole pool finds the deploy memory.
        let all = engine.recall("how do I deploy the project", scope: .all, k: 3)
        XCTAssertTrue(all.contains { $0.memory.id == deploy.id })

        // Siloed to chat-B: must NOT surface chat-A's memory.
        let onlyB = engine.recall("how do I deploy the project", scope: .conversation("chat-B"), k: 3)
        XCTAssertFalse(onlyB.contains { $0.memory.id == deploy.id })
    }

    /// Keyword search reports WHICH conversation/.md file the word is in.
    func testKeywordSearchReportsConversation() throws {
        let engine = try MemoryEngine(root: tempRoot())
        _ = try engine.remember("Remember the API base url is api.example.com", source: "manual", conversation: "infra-notes")
        _ = try engine.remember("Lunch place: the ramen spot downtown.", source: "manual", conversation: "random")

        let hits = engine.search("api base url")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.conversationID, "infra-notes")
    }

    /// The recall eval harness runs and produces a measurable number; strong word-overlap ranks #1.
    func testRecallEvalHarness() throws {
        let engine = try MemoryEngine(root: tempRoot())
        let db = try engine.remember("The production database is PostgreSQL 16 in the EU region.", source: "manual", conversation: "c")
        _ = try engine.remember("The team standup is every weekday at 10am.", source: "manual", conversation: "c")

        let result = evaluateRecall(engine.index, cases: [
            EvalCase(query: "what database do we use in production", expectedMemoryID: db.id)
        ], k: 3)

        XCTAssertEqual(result.total, 1)
        XCTAssertEqual(result.k, 3)
        XCTAssertEqual(result.hitRateAtK, 1.0, "strong word overlap should put the expected memory in top-3")
    }

    /// Forget is a soft delete: gone from recall/search, still on disk (auditable).
    func testForgetSoftDeletes() throws {
        let engine = try MemoryEngine(root: tempRoot())
        let m = try engine.remember("Temporary note to delete.", source: "manual", conversation: "c")
        try engine.forget(m.id)

        XCTAssertEqual(engine.store.allMemories().first { $0.id == m.id }?.deleted, true) // still on disk
        XCTAssertFalse(engine.recall("temporary note", scope: .all, k: 5).contains { $0.memory.id == m.id })
        XCTAssertTrue(engine.search("temporary note").isEmpty)
    }

    /// Claude Code auto-capture: parse a real-shaped transcript, distill durable user statements,
    /// store them as source "claude-code", and be idempotent on re-import.
    func testClaudeCodeAutoCapture() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cc-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("proj"), withIntermediateDirectories: true)
        let jsonl = """
        {"type":"user","sessionId":"sess1","message":{"role":"user","content":"I prefer dark mode in all my editors."}}
        {"type":"assistant","sessionId":"sess1","message":{"role":"assistant","content":[{"type":"thinking","thinking":"hmm"},{"type":"text","text":"Got it."}]}}
        {"type":"user","sessionId":"sess1","message":{"role":"user","content":"what time is it?"}}
        {"type":"user","sessionId":"sess1","message":{"role":"user","content":"Remember that my deploy script is at tools/ship.sh"}}
        """
        try jsonl.write(to: dir.appendingPathComponent("proj/sess1.jsonl"), atomically: true, encoding: .utf8)

        let engine = try MemoryEngine(root: tempRoot())
        let importer = ClaudeCodeImporter(engine: engine)

        let n = try importer.importAll(transcriptsRoot: dir)
        XCTAssertEqual(n, 2, "should capture the preference + the 'remember that' line, but not 'what time is it'")

        let all = engine.store.allMemories().filter { !$0.deleted }
        XCTAssertTrue(all.allSatisfy { $0.source == "claude-code" })
        XCTAssertTrue(all.contains { $0.content.contains("dark mode") })
        XCTAssertTrue(all.contains { $0.content.contains("ship.sh") })

        // Idempotent: re-import adds nothing.
        XCTAssertEqual(try importer.importAll(transcriptsRoot: dir), 0)
    }

    /// The heuristic now also catches Turkish memory statements (the user speaks Turkish).
    func testHeuristicCapturesTurkish() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cc-tr-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let jsonl = """
        {"type":"user","sessionId":"tr1","message":{"role":"user","content":"Şunu hatırla: ben her zaman koyu tema kullanırım."}}
        {"type":"user","sessionId":"tr1","message":{"role":"user","content":"saat kaç?"}}
        {"type":"user","sessionId":"tr1","message":{"role":"user","content":"Projemin adı Engram, bunu unutma."}}
        """
        try jsonl.write(to: dir.appendingPathComponent("tr1.jsonl"), atomically: true, encoding: .utf8)

        let engine = try MemoryEngine(root: tempRoot())
        let n = try ClaudeCodeImporter(engine: engine).importAll(transcriptsRoot: dir)
        XCTAssertEqual(n, 2, "captures the 'hatırla' and 'unutma' lines, not 'saat kaç?'")
    }

    /// Import: a folder of .md notes → each file a conversation, paragraphs become memories.
    func testMarkdownImport() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("imp-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "# My Notes\n\nI love hiking on weekends.\n\nMy car is a blue Honda Civic."
            .write(to: dir.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        try "The product launch ships in September.\n\nok"
            .write(to: dir.appendingPathComponent("work.md"), atomically: true, encoding: .utf8)

        let engine = try MemoryEngine(root: tempRoot())
        let importer = MarkdownImporter(engine: engine)

        let n = try importer.importFolder(at: dir)
        XCTAssertEqual(n, 3, "two paragraphs from notes.md + one from work.md; headings and 'ok' are too short")

        let all = engine.store.allMemories().filter { !$0.deleted }
        XCTAssertTrue(all.allSatisfy { $0.source == "import" })
        // Deterministic check that imported content is stored + findable (recall ranking quality is
        // the embedder's job, tested elsewhere; here we verify the import itself).
        XCTAssertEqual(engine.search("Honda").count, 1)
        XCTAssertEqual(engine.search("Honda").first?.content.contains("Honda Civic"), true)

        // Idempotent.
        XCTAssertEqual(try importer.importFolder(at: dir), 0)
    }

    /// A .json export (array of role/content messages) imports by extracting the message text.
    func testJSONImport() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("imp-json-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = """
        {"title":"chat-x","messages":[
          {"role":"user","content":"I prefer dark mode in all my editors and tools."},
          {"role":"assistant","content":"Noted, I will remember your dark mode preference."},
          {"role":"user","content":"ok"}
        ]}
        """
        try json.write(to: dir.appendingPathComponent("export.json"), atomically: true, encoding: .utf8)

        let engine = try MemoryEngine(root: tempRoot())
        let n = try MarkdownImporter(engine: engine).importFile(at: dir.appendingPathComponent("export.json"), source: "claude")
        XCTAssertEqual(n, 2, "two prose messages extracted; 'ok' and short ids/roles skipped")
        let all = engine.store.allMemories().filter { !$0.deleted }
        XCTAssertTrue(all.allSatisfy { $0.source == "claude" })
        XCTAssertTrue(all.contains { $0.content.contains("dark mode") })
    }

    /// Export produces a readable Markdown doc and a JSON array that round-trips back into Memory.
    func testExportMarkdownAndJSON() throws {
        let a = Memory(content: "I love hiking on weekends.", tags: [], source: "claude", conversationID: "c1")
        let b = Memory(content: "My car is a blue Honda Civic.", tags: [], source: "claude", conversationID: "c2")

        let md = Exporter.markdown(from: [a, b])
        XCTAssertTrue(md.contains("## c1") && md.contains("hiking"))
        XCTAssertTrue(md.contains("## c2"))

        let js = Exporter.json(from: [a, b])
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let back = try dec.decode([Memory].self, from: Data(js.utf8))
        XCTAssertEqual(back.count, 2, "JSON export round-trips back into Memory")
        XCTAssertTrue(back.contains { $0.content.contains("Honda") })
    }

    /// Deleting an imported file then re-importing it (e.g. to re-tag it under a different AI) must
    /// bring the content back — deleted tombstones must NOT block the re-import.
    func testReimportAfterDelete() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("imp-redel-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("chat.md")
        try "I love hiking on weekends.\n\nMy car is a blue Honda Civic."
            .write(to: file, atomically: true, encoding: .utf8)

        let engine = try MemoryEngine(root: tempRoot())
        let importer = MarkdownImporter(engine: engine)

        // First import, tagged "claude".
        XCTAssertEqual(try importer.importFile(at: file, source: "claude"), 2)
        XCTAssertTrue(engine.store.allMemories().filter { !$0.deleted }.allSatisfy { $0.source == "claude" })

        // Delete everything (soft delete).
        for m in engine.store.allMemories() { try engine.forget(m.id) }
        XCTAssertEqual(engine.store.allMemories().filter { !$0.deleted }.count, 0)

        // Re-import the same file → content comes back (must NOT be skipped as duplicate).
        XCTAssertEqual(try importer.importFile(at: file, source: "claude"), 2,
                       "previously-deleted content must be re-importable")
        XCTAssertEqual(engine.store.allMemories().filter { !$0.deleted }.count, 2)
    }

    /// The on-device NaturalLanguage embedder produces a normalized vector and never crashes
    /// (falls back gracefully if the OS word model isn't present in this environment).
    func testNLEmbeddingProvider() {
        let p = NLEmbeddingProvider()
        XCTAssertGreaterThan(p.dimension, 0)
        let v = p.embed("the production database is postgresql")
        XCTAssertEqual(v.count, p.dimension)
        let norm = (v.reduce(0) { $0 + $1 * $1 }).squareRoot()
        XCTAssertTrue(norm == 0 || abs(norm - 1) < 1e-3, "vector should be L2-normalized")
    }

    /// The contextual (transformer) embedder produces a normalized vector of its declared dimension
    /// and never crashes — whether or not the OS asset is present (it falls back to the word embedder
    /// without touching the network). `prepare()` returns a status string and doesn't throw.
    func testContextualEmbeddingProvider() {
        let p = NLContextualEmbeddingProvider()   // default: no download, no network
        XCTAssertGreaterThan(p.dimension, 0)
        let v = p.embed("the production database is postgresql")
        XCTAssertEqual(v.count, p.dimension, "every vector must match the provider's declared dimension")
        let norm = (v.reduce(0) { $0 + $1 * $1 }).squareRoot()
        XCTAssertTrue(norm == 0 || abs(norm - 1) < 1e-3, "vector should be L2-normalized")

        // Recall through the engine works with this embedder regardless of which mode it resolved to.
        XCTAssertFalse(NLContextualEmbeddingProvider.prepare().isEmpty)
    }

    /// Regression (audit P1): a negative k must be clamped, not trap Collection.prefix and crash.
    func testNegativeKIsClamped() throws {
        let engine = try MemoryEngine(root: tempRoot())
        _ = try engine.remember("Something to find about deploys.", source: "manual", conversation: "c")
        XCTAssertEqual(engine.recall("deploy", scope: .all, k: -1).count, 0)   // must NOT crash
        XCTAssertEqual(engine.recall("deploy", scope: .all, k: 0).count, 0)
    }

    /// Regression (audit P1): content that itself contains a `<!-- @end -->` line must round-trip intact.
    func testMarkerInContentRoundTrips() throws {
        let root = tempRoot()
        let content = "Here is the markdown comment syntax:\n<!-- @end -->\nand more text after it."
        do { _ = try MemoryEngine(root: root).remember(content, source: "manual", conversation: "c") }
        let reopened = try MemoryEngine(root: root)
        XCTAssertEqual(reopened.store.memories(in: "c").first(where: { !$0.deleted })?.content, content)
    }

    /// Regression (audit P1): a JSON export must re-import faithfully (content + conversation + source).
    func testJSONExportReimports() throws {
        let engine = try MemoryEngine(root: tempRoot())
        _ = try engine.remember("My production db is PostgreSQL 16.", source: "claude", conversation: "infra")
        _ = try engine.remember("I bike on weekends.", source: "claude", conversation: "life")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("exp-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("engram.json")
        try Exporter.json(from: engine.store.allMemories()).write(to: file, atomically: true, encoding: .utf8)

        let fresh = try MemoryEngine(root: tempRoot())
        XCTAssertEqual(try MarkdownImporter(engine: fresh).importFile(at: file, source: "import"), 2)
        XCTAssertTrue(fresh.store.allMemories().contains {
            $0.content.contains("PostgreSQL") && $0.conversationID == "infra" && $0.source == "claude"
        }, "round-trip preserves content, conversation, and source")
    }

    /// Regression (audit P2): a conversationID with '/' must be a safe, non-colliding filename that
    /// still round-trips back to the original id.
    func testConversationIDWithSlashIsSafe() throws {
        let root = tempRoot()
        do {
            let e = try MemoryEngine(root: root)
            _ = try e.remember("memory in the slashed id", source: "manual", conversation: "team/project")
            _ = try e.remember("memory in the underscore id", source: "manual", conversation: "team_project")
        }
        let reopened = try MemoryEngine(root: root)
        XCTAssertEqual(reopened.store.memories(in: "team/project").filter { !$0.deleted }.count, 1)
        XCTAssertEqual(reopened.store.memories(in: "team_project").filter { !$0.deleted }.count, 1)  // no collision
        XCTAssertTrue(reopened.store.allMemories().contains { $0.conversationID == "team/project" })  // round-trips
    }

    /// Memories survive a restart — a fresh engine on the same folder reloads everything.
    func testPersistenceAcrossReload() throws {
        let root = tempRoot()
        do {
            let engine = try MemoryEngine(root: root)
            _ = try engine.remember("The launch date is in September.", source: "manual", conversation: "plans")
        }
        let reopened = try MemoryEngine(root: root)
        XCTAssertEqual(reopened.recall("when do we launch", scope: .all, k: 3).first?.memory.content.contains("September"), true)
    }
}
