import Foundation

/// The façade the MCP server and the menubar app both talk to. Ties the Markdown store (truth)
/// to the in-memory vector index (fast recall). The four verbs map straight to the product:
/// remember · recall (with collective-mind scope) · search (which file) · forget.
/// `@unchecked Sendable`: an engine is built on a background task and then handed to the app's
/// MainActor, after which it's only touched there. (The MCP server and capture tool each run in their
/// own process with their own engine, so there's no cross-thread sharing of a single instance.)
public final class MemoryEngine: @unchecked Sendable {
    public let store: MarkdownStore
    public let index: MemoryIndex

    public init(root: URL, embedder: EmbeddingProvider = HashingEmbedder()) throws {
        self.store = try MarkdownStore(root: root)
        self.index = MemoryIndex(embedder: embedder)
        index.rebuild(from: store.allMemories())
    }

    /// Write a memory into its conversation's .md file and the live index.
    @discardableResult
    public func remember(_ content: String,
                         tags: [String] = [],
                         source: String,
                         conversation: String) throws -> Memory {
        let m = Memory(content: content, tags: tags, source: source, conversationID: conversation)
        try store.append(m)
        index.add(m)
        return m
    }

    /// Semantic recall. `.all` = ortak akıl (every conversation); `.conversation(id)` = one chat.
    public func recall(_ query: String, scope: RecallScope = .all, k: Int = 5) -> [RecallHit] {
        index.recall(query, scope: scope, k: k)
    }

    /// Keyword search — returns matches with their conversationID (which .md file the word is in).
    public func search(_ keyword: String) -> [Memory] {
        store.keywordSearch(keyword)
    }

    /// Soft-delete a memory (stays on disk, leaves recall/search). Drops just that entry from the index —
    /// no full re-embed (which would re-encode the entire store on every single forget).
    public func forget(_ id: UUID) throws {
        try store.softDelete(id)
        index.remove(id: id)
    }
}
