import Foundation

/// Turn a set of memories into a single shareable document — Markdown (human-readable, grouped by
/// conversation) or JSON (machine-readable, round-trippable back into Engram). Used by the app's
/// "Export" action; kept here in the library so the formatting is unit-testable.
public enum Exporter {

    /// One readable `.md`: a `##` heading per conversation, each memory as a bullet (oldest first).
    public static func markdown(from memories: [Memory]) -> String {
        let groups = Dictionary(grouping: memories.filter { !$0.deleted }, by: { $0.conversationID })
        var out = "# Engram export\n\n"
        for conv in groups.keys.sorted() {
            out += "## \(conv)\n\n"
            for m in (groups[conv] ?? []).sorted(by: { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }) {
                // keep multi-line content intact as an indented list continuation (not flattened to one line)
                out += "- \(m.content.replacingOccurrences(of: "\n", with: "\n  "))\n"
            }
            out += "\n"
        }
        return out
    }

    /// One `.json` array of the full memory records (ISO-8601 dates) — re-importable later.
    public static func json(from memories: [Memory]) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let clean = memories.filter { !$0.deleted }
        return (try? encoder.encode(clean)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }
}
