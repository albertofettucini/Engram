import Foundation

/// A single remembered fact. The schema is append-only + soft-delete and forward-compatible
/// (supersedes/version hooks) so a future merge / forget / contradiction layer can be added
/// without a migration.
public struct Memory: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var content: String
    public var tags: [String]
    /// Which client wrote it — e.g. "claude-code", "claude-desktop", "manual". Surfaced in the UI.
    public var source: String
    /// Groups memories into ONE .md file per conversation (the source of truth on disk).
    public var conversationID: String
    public var createdAt: Date
    public var updatedAt: Date
    /// Forward-compat: id of a memory this one replaces (for a future merge/version layer). Unused in v1.
    public var supersedes: UUID?
    /// Soft delete — the entry stays on disk (auditable) but is excluded from recall/search.
    public var deleted: Bool

    public init(id: UUID = UUID(),
                content: String,
                tags: [String] = [],
                source: String,
                conversationID: String,
                createdAt: Date = Date(),
                updatedAt: Date = Date(),
                supersedes: UUID? = nil,
                deleted: Bool = false) {
        self.id = id
        self.content = content
        self.tags = tags
        self.source = source
        self.conversationID = conversationID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.supersedes = supersedes
        self.deleted = deleted
    }
}
