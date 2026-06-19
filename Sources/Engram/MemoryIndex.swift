import Foundation

/// Where recall looks.
public enum RecallScope: Equatable {
    /// One conversation only — memories stay siloed to their own chat.
    case conversation(String)
    /// A curated set of conversations — the membership of one combined file ("recall within this file").
    case conversations(Set<String>)
    /// "Ortak akıl" (collective mind) — search across EVERY conversation at once.
    case all
}

public struct RecallHit: Equatable {
    public let memory: Memory
    public let score: Float
    public var conversationID: String { memory.conversationID }
}

/// In-memory vector index built from the Markdown store. For v1 scale (hundreds–thousands of
/// memories) brute-force cosine is microseconds and needs zero dependencies; a persisted
/// embedding cache / sqlite-vec is a later scale concern.
public final class MemoryIndex {
    private let embedder: EmbeddingProvider
    private var entries: [(memory: Memory, vector: [Float])] = []

    public init(embedder: EmbeddingProvider) { self.embedder = embedder }

    public func rebuild(from memories: [Memory]) {
        entries = memories.filter { !$0.deleted }.map { ($0, embedder.embed($0.content)) }
    }

    public func add(_ memory: Memory) {
        guard !memory.deleted else { return }
        entries.append((memory, embedder.embed(memory.content)))
    }

    /// Cheap removals — just drop entries, no re-embedding. Deleting must NOT re-embed the whole store.
    public func remove(id: UUID) { entries.removeAll { $0.memory.id == id } }
    public func removeConversation(_ conversationID: String) {
        entries.removeAll { $0.memory.conversationID == conversationID }
    }

    /// Top-k semantic matches. `scope: .all` is the collective mind; `.conversation(id)` is one chat.
    public func recall(_ query: String, scope: RecallScope = .all, k: Int = 5, minScore: Float = 0.05) -> [RecallHit] {
        let q = embedder.embed(query)
        // Degenerate (all-zero) query — empty / whitespace / fully out-of-vocabulary — matches nothing
        // meaningfully; cosine is 0 against everything, so don't surface arbitrary unrelated "hits".
        if q.allSatisfy({ $0 == 0 }) { return [] }
        let pool = entries.filter { e in
            switch scope {
            case .all: return true
            case .conversation(let id): return e.memory.conversationID == id
            case .conversations(let ids): return ids.contains(e.memory.conversationID)
            }
        }
        let n = max(0, k)   // a negative k would trap Collection.prefix (crashes the process / MCP server)
        return pool
            .map { RecallHit(memory: $0.memory, score: cosineSimilarity(q, $0.vector)) }
            .filter { $0.score > minScore }   // relevance floor — drop near-orthogonal junk
            .sorted { ($0.score, $0.memory.createdAt, $0.memory.id.uuidString)
                    > ($1.score, $1.memory.createdAt, $1.memory.id.uuidString) }   // total, deterministic order
            .prefix(n)
            .map { $0 }
    }
}
