import Foundation

/// A user-made "combined file": a named weave of however many conversations the user chose. Lives in the
/// shared store so BOTH the app (which creates/edits them) and the MCP server (which can recall WITHIN
/// one) see the exact same definitions.
public struct CombinedFile: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var conversations: Set<String>
    public init(id: String, name: String, conversations: Set<String>) {
        self.id = id
        self.name = name
        self.conversations = conversations
    }
}

/// On-disk store for combined files: a single JSON file that sits next to the memories store
/// (…/Engram/combined-files.json). Both the app and the MCP read/write it, so a file the user builds in
/// the dashboard is immediately a recall scope the AI can target.
public enum CombinedFileStore {
    /// The ONE true memories-root resolution — honors ENGRAM_ROOT, else …/Application Support/Engram/memories.
    /// Shared by the app, the MCP server, and the capture CLI so all three agree on where memories AND
    /// combined-files.json live. (If they diverged, the app would write files the MCP could never find.)
    public static func defaultMemoriesRoot() -> URL {
        if let env = ProcessInfo.processInfo.environment["ENGRAM_ROOT"], !env.isEmpty {
            return URL(fileURLWithPath: env, isDirectory: true)
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return appSupport.appendingPathComponent("Engram/memories", isDirectory: true)
    }

    /// The json lives in the parent of the memories directory (…/Engram/combined-files.json), so it
    /// follows any ENGRAM_ROOT override the memories store uses.
    public static func url(memoriesRoot: URL) -> URL {
        memoriesRoot.deletingLastPathComponent().appendingPathComponent("combined-files.json", isDirectory: false)
    }

    public static func load(memoriesRoot: URL) -> [CombinedFile] {
        let u = url(memoriesRoot: memoriesRoot)
        guard let data = try? Data(contentsOf: u),
              let files = try? JSONDecoder().decode([CombinedFile].self, from: data) else { return [] }
        return files
    }

    /// Returns true ONLY if the file was actually written — callers rely on this before dropping any
    /// backup copy of the data (so a failed write never causes data loss).
    @discardableResult
    public static func save(_ files: [CombinedFile], memoriesRoot: URL) -> Bool {
        let u = url(memoriesRoot: memoriesRoot)
        do {
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(files)
            try data.write(to: u, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// All combined files whose name matches (case-insensitive, trimmed). Plural so the MCP can detect an
    /// ambiguous name instead of silently grabbing whichever happens to be first.
    public static func files(named name: String, memoriesRoot: URL) -> [CombinedFile] {
        let target = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return load(memoriesRoot: memoriesRoot).filter { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == target }
    }
}
