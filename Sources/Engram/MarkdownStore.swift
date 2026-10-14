import Foundation

/// The source of truth: one human-readable `.md` file PER CONVERSATION on disk. The user owns
/// these files — open them in any editor, grep them, back them up. Nothing is hidden in a binary
/// blob. (A vector index is built FROM these for fast recall and is always rebuildable.)
///
/// File format — each memory is a block whose metadata rides in an HTML comment (invisible when
/// rendered), so the file reads cleanly as Markdown while staying machine-parseable:
///
///     # <conversationID>
///
///     <!-- @memory {"id":"…","len":3,"source":"…",…} -->
///     the remembered text
///     <!-- @end -->
///
/// `len` (content line count) lets the parser read the body opaquely, so content that itself
/// contains a line like `<!-- @end -->` round-trips intact instead of truncating.
public final class MarkdownStore {
    public let root: URL

    /// Moves a file to the Trash and returns where it landed. The default is the system Trash
    /// (FileManager.trashItem); tests swap it so they never touch the user's real Trash.
    public var moveToTrash: (URL) throws -> URL? = { url in
        var landed: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &landed)
        return landed as URL?
    }

    public init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    // MARK: Paths / codecs

    /// Characters kept verbatim in a filename; everything else (slashes, dots, control chars, unicode)
    /// is percent-encoded — so the conversationID maps to a SAFE, COLLISION-FREE, REVERSIBLE filename.
    /// Plain ids (UUIDs, "Session-2026-06-14") are unaffected; "a/b" and "a.b" no longer collide or escape.
    private static let filenameAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")

    private func fileURL(_ conversationID: String) -> URL {
        let trimmed = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: Self.filenameAllowed) ?? ""
        let safe = encoded.isEmpty ? "default" : encoded   // never an empty / "." / ".." path component
        return root.appendingPathComponent(safe).appendingPathExtension("md")
    }

    /// Recover the true conversationID from a filename (reverse of `fileURL`'s encoding).
    private func conversationID(fromFile f: URL) -> String {
        let raw = f.deletingPathExtension().lastPathComponent
        return raw.removingPercentEncoding ?? raw
    }

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }
    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    // NOTE: keep ANY newly-added field Optional (or give a custom init(from:) with decodeIfPresent),
    // so decoding an older file never throws and silently wipes the user's memories.
    private struct EntryMeta: Codable {
        let id: UUID
        var tags: [String]
        var source: String
        var createdAt: Date
        var updatedAt: Date
        var supersedes: UUID?
        var deleted: Bool
        var len: Int?   // content line count (added later → Optional for backward compatibility)
    }

    private func block(for m: Memory) -> String {
        let lineCount = m.content.components(separatedBy: "\n").count
        let meta = EntryMeta(id: m.id, tags: m.tags, source: m.source,
                             createdAt: m.createdAt, updatedAt: m.updatedAt,
                             supersedes: m.supersedes, deleted: m.deleted, len: lineCount)
        let json = (try? Self.encoder().encode(meta))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return "<!-- @memory \(json) -->\n\(m.content)\n<!-- @end -->"
    }

    // MARK: Read

    public func memories(in conversationID: String) -> [Memory] {
        guard let text = try? String(contentsOf: fileURL(conversationID), encoding: .utf8) else { return [] }
        return parse(text, conversationID: conversationID)
    }

    /// Every memory across every conversation (includes soft-deleted — callers filter).
    public func allMemories() -> [Memory] {
        let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        var out: [Memory] = []
        for f in files where f.pathExtension == "md" {
            if let text = try? String(contentsOf: f, encoding: .utf8) {
                out += parse(text, conversationID: conversationID(fromFile: f))
            }
        }
        return out
    }

    private static func isEnd(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces) == "<!-- @end -->"
    }

    private func parse(_ text: String, conversationID: String) -> [Memory] {
        var memories: [Memory] = []
        let lines = text.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("<!-- @memory ") && trimmed.hasSuffix(" -->") else { i += 1; continue }
            let jsonStr = String(trimmed.dropFirst("<!-- @memory ".count).dropLast(" -->".count))
            i += 1
            // Decode metadata FIRST — we use its `len` to read the body opaquely.
            guard let data = jsonStr.data(using: .utf8),
                  let meta = try? Self.decoder().decode(EntryMeta.self, from: data) else {
                FileHandle.standardError.write(Data("engram: skipped an undecodable @memory block in \"\(conversationID)\"\n".utf8))
                while i < lines.count && !Self.isEnd(lines[i]) { i += 1 }   // skip its body so the rest still parses
                if i < lines.count { i += 1 }
                continue
            }
            var contentLines: [String] = []
            if let len = meta.len {
                var taken = 0
                while i < lines.count && taken < len { contentLines.append(lines[i]); i += 1; taken += 1 }
                if i < lines.count && Self.isEnd(lines[i]) { i += 1 }
            } else {
                // Legacy block with no length: read up to the marker (pre-`len` behavior).
                while i < lines.count && !Self.isEnd(lines[i]) { contentLines.append(lines[i]); i += 1 }
                if i < lines.count { i += 1 }
            }
            let content = contentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            memories.append(Memory(id: meta.id, content: content, tags: meta.tags,
                                   source: meta.source, conversationID: conversationID,
                                   createdAt: meta.createdAt, updatedAt: meta.updatedAt,
                                   supersedes: meta.supersedes, deleted: meta.deleted))
        }
        return memories
    }

    // MARK: Write

    private func write(_ memories: [Memory], to conversationID: String) throws {
        let body = memories.map { block(for: $0) }.joined(separator: "\n\n")
        let text = "# \(conversationID)\n\n" + body + "\n"
        try text.write(to: fileURL(conversationID), atomically: true, encoding: .utf8)
    }

    public func append(_ memory: Memory) throws {
        var existing = memories(in: memory.conversationID)
        existing.append(memory)
        try write(existing, to: memory.conversationID)
    }

    /// Soft delete: marks the entry deleted but keeps it on disk (auditable / recoverable).
    /// Tombstones EVERY occurrence of the id across all files (duplicated ids can't leave a live copy).
    public func softDelete(_ id: UUID) throws {
        let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for f in files where f.pathExtension == "md" {
            let conv = conversationID(fromFile: f)
            var mems = memories(in: conv)
            var changed = false
            for idx in mems.indices where mems[idx].id == id && !mems[idx].deleted {
                mems[idx].deleted = true
                mems[idx].updatedAt = Date()
                changed = true
            }
            if changed { try write(mems, to: conv) }   // no early return — every file with a match gets tombstoned
        }
    }

    /// Revive the first soft-deleted memory whose content exactly matches, so a re-import resurrects a
    /// tombstone instead of appending a duplicate (keeps delete↔reimport cycles from growing the file).
    @discardableResult
    public func restoreDeleted(content: String, in conversationID: String) -> Memory? {
        var mems = memories(in: conversationID)
        guard let idx = mems.firstIndex(where: { $0.deleted && $0.content == content }) else { return nil }
        mems[idx].deleted = false
        mems[idx].updatedAt = Date()
        try? write(mems, to: conversationID)
        return mems[idx]
    }

    /// Forget a whole conversation: move its .md file out of the store (no tombstones left behind, so the
    /// same content can be re-imported later), but never hard-delete it. It goes to the Trash, so the user
    /// can put it back; if the Trash refuses, it moves to <Engram>/Trash/<name>-<timestamp>.md, which is
    /// outside the memories folder. Returns where the file went (nil when there was no file).
    @discardableResult
    public func deleteConversationFile(_ conversationID: String) throws -> URL? {
        let url = fileURL(conversationID)
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return nil }
        if let landed = try? moveToTrash(url) { return landed }
        if !fm.fileExists(atPath: url.path) { return nil }   // trashed, but the system didn't say where

        let trash = root.deletingLastPathComponent().appendingPathComponent("Trash", isDirectory: true)
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let base = url.deletingPathExtension().lastPathComponent + "-" + f.string(from: Date())
        var dest = trash.appendingPathComponent(base).appendingPathExtension("md")
        var n = 2
        while fm.fileExists(atPath: dest.path) {   // two forgets in the same second never overwrite each other
            dest = trash.appendingPathComponent("\(base)-\(n)").appendingPathExtension("md")
            n += 1
        }
        try fm.moveItem(at: url, to: dest)
        return dest
    }

    // MARK: Keyword search

    /// Plain substring search across all conversations. Each hit carries its conversationID, so the
    /// UI can show WHICH .md file the word was found in. (Distinct from semantic recall.)
    public func keywordSearch(_ keyword: String) -> [Memory] {
        let q = keyword.lowercased()
        guard !q.isEmpty else { return [] }
        return allMemories().filter { !$0.deleted && $0.content.lowercased().contains(q) }
    }
}
