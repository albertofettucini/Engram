import Foundation

/// Bring existing notes IN. Point it at a folder (or file) of .md/.txt/.json — an Obsidian vault,
/// exported notes, your own docs, an Engram export — and each file becomes a conversation whose
/// paragraphs become memories, so users don't start from zero. The external files are never moved or
/// modified; their content is copied into the local store and re-embedded locally.
public struct MarkdownImporter {
    let engine: MemoryEngine

    public init(engine: MemoryEngine) { self.engine = engine }

    public static let fileExtensions = ["md", "markdown", "txt", "text", "json"]

    /// One file → one conversation (named after the file), EXCEPT an Engram JSON export, which restores
    /// each memory's own conversation + source so export → import round-trips. Idempotent: identical
    /// non-deleted content is skipped; a matching tombstone is REVIVED rather than duplicated.
    @discardableResult
    public func importFile(at url: URL, source: String = "import", distill: Bool = false) throws -> Int {
        guard let raw = Self.readText(url) else { return 0 }
        let isJSON = url.pathExtension.lowercased() == "json"

        // Engram's own export (array of full Memory records) → re-insert preserving structure.
        if isJSON, let mems = Self.decodeEngramExport(raw), !mems.isEmpty {
            var added = 0, revived = false
            for m in mems where !m.deleted {
                let r = importOne(m.content, tags: m.tags, source: m.source, conversation: m.conversationID)
                if r != .skipped { added += 1 }
                if r == .revived { revived = true }
            }
            if revived { engine.index.rebuild(from: engine.store.allMemories()) }
            return added
        }

        let conversation = url.deletingPathExtension().lastPathComponent
        var chunks = isJSON ? Self.chunksFromJSON(raw) : Self.chunk(raw)
        if isJSON && chunks.isEmpty { chunks = Self.chunk(raw) }   // unparseable/empty JSON → treat as plain text, don't drop the file
        if distill {
            let userMsgs = Self.userMessagesFromJSON(raw)        // role-aware: distill only the USER's turns
            chunks = HeuristicDistiller().distill(userMessages: userMsgs.isEmpty ? chunks : userMsgs)
        }
        let tags = distill ? ["import", "distilled"] : ["import"]
        var added = 0, revived = false
        for chunk in chunks {
            let r = importOne(chunk, tags: tags, source: source, conversation: conversation)
            if r != .skipped { added += 1 }
            if r == .revived { revived = true }
        }
        if revived { engine.index.rebuild(from: engine.store.allMemories()) }
        return added
    }

    /// Import raw pasted text (no file). Detects an Engram/AI json export vs plain prose, the same way
    /// importFile does, and pulls memories into one conversation. Returns how many were added.
    @discardableResult
    public func importText(_ raw: String, source: String, conversation: String, distill: Bool = false) throws -> Int {
        if let mems = Self.decodeEngramExport(raw), !mems.isEmpty {
            var added = 0, revived = false
            for m in mems where !m.deleted {
                let r = importOne(m.content, tags: m.tags, source: m.source, conversation: m.conversationID)
                if r != .skipped { added += 1 }
                if r == .revived { revived = true }
            }
            if revived { engine.index.rebuild(from: engine.store.allMemories()) }
            return added
        }
        // A deliberate paste is not bulk file-import: don't drop short notes (the 20-char floor in `chunk`
        // is for filtering headings/noise out of whole files). Keep every non-empty paragraph, and if even
        // that yields nothing, save the whole trimmed text — so a short note always sticks.
        var chunks = Self.chunksFromJSON(raw)         // a pasted ChatGPT/Gemini json → prose extraction
        if chunks.isEmpty {
            chunks = raw.components(separatedBy: "\n\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        if chunks.isEmpty {
            let whole = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !whole.isEmpty { chunks = [whole] }
        }
        if distill {
            let userMsgs = Self.userMessagesFromJSON(raw)        // role-aware: distill only the USER's turns
            chunks = HeuristicDistiller().distill(userMessages: userMsgs.isEmpty ? chunks : userMsgs)
        }
        let tags = distill ? ["import", "paste", "distilled"] : ["import", "paste"]
        var added = 0, revived = false
        for chunk in chunks {
            let r = importOne(chunk, tags: tags, source: source, conversation: conversation)
            if r != .skipped { added += 1 }
            if r == .revived { revived = true }
        }
        if revived { engine.index.rebuild(from: engine.store.allMemories()) }
        return added
    }

    private enum ImportResult { case added, revived, skipped }

    /// Skip an identical live memory; revive a matching tombstone (re-indexing it) instead of appending
    /// a duplicate; otherwise remember it fresh.
    private func importOne(_ content: String, tags: [String], source: String, conversation: String) -> ImportResult {
        let inConv = engine.store.memories(in: conversation)
        if inConv.contains(where: { !$0.deleted && $0.content == content }) { return .skipped }
        if engine.store.restoreDeleted(content: content, in: conversation) != nil {
            return .revived   // caller re-indexes once at the end
        }
        _ = try? engine.remember(content, tags: tags, source: source, conversation: conversation)
        return .added
    }

    /// Walk a folder and import every supported file inside it.
    @discardableResult
    public func importFolder(at folder: URL, source: String = "import", distill: Bool = false) throws -> Int {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else { return 0 }
        var total = 0
        for case let f as URL in walker where Self.fileExtensions.contains(f.pathExtension.lowercased()) {
            total += (try? importFile(at: f, source: source, distill: distill)) ?? 0
        }
        return total
    }

    // MARK: Readers

    /// UTF-8 first, then let the OS sniff the encoding, then a couple of legacy fallbacks — so a non-UTF8
    /// file imports (lossily at worst) instead of being silently skipped.
    static func readText(_ url: URL) -> String? {
        if let s = try? String(contentsOf: url, encoding: .utf8) { return s }
        var used: String.Encoding = .utf8
        if let s = try? String(contentsOf: url, usedEncoding: &used) { return s }
        if let d = try? Data(contentsOf: url) {
            for e: String.Encoding in [.isoLatin1, .windowsCP1252, .utf16] {
                if let s = String(data: d, encoding: e) { return s }
            }
        }
        return nil
    }

    static func decodeEngramExport(_ raw: String) -> [Memory]? {
        guard let data = raw.data(using: .utf8) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode([Memory].self, from: data)
    }

    /// Split on blank lines into paragraph chunks; drop tiny fragments (headings, stray lines).
    static func chunk(_ text: String) -> [String] {
        text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 20 }
    }

    /// Pull readable message text out of an arbitrary JSON export (Claude / ChatGPT / generic). Walks the
    /// whole structure and keeps prose-looking strings — long enough AND containing a space, which skips
    /// ids, hashes, roles, timestamps. De-duplicated, order preserved. `.fragmentsAllowed` so a bare
    /// scalar root still parses.
    static func chunksFromJSON(_ raw: String) -> [String] {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return [] }
        var collected: [String] = []
        collectStrings(obj, into: &collected)
        var seen = Set<String>()
        return collected
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 20 && $0.contains(" ") && seen.insert($0).inserted }
    }

    private static func collectStrings(_ any: Any, into out: inout [String]) {
        if let s = any as? String {
            out.append(s)
        } else if let arr = any as? [Any] {
            for v in arr { collectStrings(v, into: &out) }
        } else if let dict = any as? [String: Any] {
            for key in dict.keys.sorted() { collectStrings(dict[key]!, into: &out) }
        }
    }

    /// Pull ONLY the user's message text out of a conversation JSON — so distillation judges what the
    /// person said, not the assistant's replies. Handles the ChatGPT export shape (`mapping` nodes with
    /// `author.role` + `content.parts`) and the simple `{role, content}` shape. Empty if no user turns.
    public static func userMessagesFromJSON(_ raw: String) -> [String] {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return [] }
        var out: [String] = []
        collectUserMessages(obj, into: &out)
        var seen = Set<String>()
        return out.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                  .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private static func collectUserMessages(_ any: Any, into out: inout [String]) {
        if let dict = any as? [String: Any] {
            let role = (dict["role"] as? String) ?? ((dict["author"] as? [String: Any])?["role"] as? String)
            if role == "user", let text = messageText(dict) { out.append(text) }
            for v in dict.values { collectUserMessages(v, into: &out) }
        } else if let arr = any as? [Any] {
            for v in arr { collectUserMessages(v, into: &out) }
        }
    }

    /// Text of a message dict: ChatGPT `content.parts: [String]`, or a plain `content: String`.
    private static func messageText(_ dict: [String: Any]) -> String? {
        if let content = dict["content"] as? [String: Any], let parts = content["parts"] as? [Any] {
            let s = parts.compactMap { $0 as? String }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return s.isEmpty ? nil : s
        }
        if let content = dict["content"] as? String {
            let s = content.trimmingCharacters(in: .whitespacesAndNewlines)
            return s.isEmpty ? nil : s
        }
        return nil
    }
}
