import Foundation

/// `engram-mcp --doctor`: explains why Claude can't see Engram, in one line per area. Strictly read-only —
/// it never writes a file, never runs the `claude` CLI and never downloads the embedding model — and it
/// runs before the engine is built, so it never pays for embedding the store.
public struct DoctorCheck: Equatable {
    public enum Status: String, Sendable { case ok, warn, fail, skip }

    public var status: Status
    public var area: String
    public var message: String
    /// The command that fixes it, printed as "Fix: <fix>".
    public var fix: String?

    public init(_ status: Status, _ area: String, _ message: String, fix: String? = nil) {
        self.status = status
        self.area = area
        self.message = message
        self.fix = fix
    }

    public var glyph: String {
        switch status {
        case .ok: return "✓"
        case .warn: return "!"
        case .fail: return "✗"
        case .skip: return "–"
        }
    }

    /// "  ✓ Claude Desktop   connected → /opt/homebrew/bin/engram-mcp" — area padded to 16, no colors.
    public var line: String {
        let padded = area.count >= 16 ? area : area + String(repeating: " ", count: 16 - area.count)
        return "  \(glyph) \(padded) \(message)" + (fix.map { " Fix: \($0)" } ?? "")
    }
}

public struct Doctor {
    public static let desktopArea = "Claude Desktop"
    public static let codeArea = "Claude Code"
    public static let storeArea = "Memory store"
    public static let embeddingsArea = "Embeddings"

    public let env: HostEnvironment
    public let fs: FileSystemProbe
    public let now: () -> Date
    public let embeddingsAvailable: () -> Bool

    public init(env: HostEnvironment,
                fs: FileSystemProbe = LocalFileSystem(),
                now: @escaping () -> Date = Date.init,
                embeddingsAvailable: @escaping () -> Bool = { NLContextualEmbeddingProvider.contextualAvailable }) {
        self.env = env
        self.fs = fs
        self.now = now
        self.embeddingsAvailable = embeddingsAvailable
    }

    public static func run(env: HostEnvironment) -> [DoctorCheck] { Doctor(env: env).run() }

    public func run() -> [DoctorCheck] {
        [claudeDesktop(), claudeCode(), memoryStore(), embeddings()]
    }

    // MARK: Output

    public static func render(_ checks: [DoctorCheck], version: String = EngramVersion.current) -> String {
        let problems = checks.filter { $0.status == .fail }.count
        let summary: String
        switch problems {
        case 0: summary = "All good."
        case 1: summary = "1 problem found."
        default: summary = "\(problems) problems found."
        }
        return (["Engram doctor (\(version))"] + checks.map(\.line) + ["", summary]).joined(separator: "\n")
    }

    /// 0 when there are no ✗ lines, 1 otherwise.
    public static func exitCode(_ checks: [DoctorCheck]) -> Int32 {
        checks.contains { $0.status == .fail } ? 1 : 0
    }

    // MARK: Claude Desktop

    func claudeDesktop() -> DoctorCheck {
        let area = Self.desktopArea
        let fix = "engram-mcp --connect claude-desktop"
        let configURL = env.desktopConfigURL
        let data = FileManager.default.contents(atPath: configURL.path)
        guard env.desktopDetected || data != nil else { return DoctorCheck(.skip, area, "not installed") }

        var entry: [String: Any]?
        if let data {
            guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                return DoctorCheck(.fail, area, "its config isn't valid JSON (\(configURL.path)).",
                                   fix: "repair that file, then run engram-mcp --connect claude-desktop")
            }
            entry = (root["mcpServers"] as? [String: Any])?["engram"] as? [String: Any]
        }
        guard let entry else {
            let recorded = ConnectionStore.load(memoriesRoot: env.memoriesRoot).contains { $0.client == ConnectClient.claudeDesktop.rawValue }
            let logged = FileManager.default.fileExists(atPath: env.claudeLogsDir.appendingPathComponent("mcp-server-engram.log").path)
            if recorded || logged {
                return DoctorCheck(.fail, area, "Engram was connected before but is missing from Claude Desktop's config now. Claude Desktop may have dropped it during an update.", fix: fix)
            }
            return DoctorCheck(.warn, area, "not connected.", fix: fix)
        }
        return commandCheck(area: area, command: entry["command"] as? String, fix: fix, okMessage: { "connected → \($0)" })
    }

    // MARK: Claude Code

    func claudeCode() -> DoctorCheck {
        let area = Self.codeArea
        let fix = "engram-mcp --connect claude-code"
        let configURL = env.claudeCodeConfigURL
        switch ClaudeCodeConfig.userEngramEntry(at: configURL) {
        case .noFile:
            if env.findExecutable("claude", fs: fs) == nil { return DoctorCheck(.skip, area, "not installed") }
            return DoctorCheck(.warn, area, "not connected.", fix: fix)
        case .unreadable:
            return DoctorCheck(.warn, area, "can't read \(configURL.path) (not valid JSON), so the connection can't be checked.")
        case .noEntry:
            return DoctorCheck(.warn, area, "not connected.", fix: fix)
        case .entry(let e):
            return commandCheck(area: area, command: e.command, fix: fix, okMessage: { "connected (user scope) → \($0)" })
        }
    }

    /// The shared part: does the configured command exist, run, and stay put?
    private func commandCheck(area: String, command: String?, fix: String, okMessage: (String) -> String) -> DoctorCheck {
        guard let command, !command.isEmpty else {
            return DoctorCheck(.fail, area, "has an engram entry with no command.", fix: fix)
        }
        guard fs.fileExists(command) else {
            return DoctorCheck(.fail, area, "points at \(command), which doesn't exist.", fix: fix)
        }
        guard fs.isExecutableFile(command) else {
            return DoctorCheck(.fail, area, "points at \(command), which isn't a runnable program.", fix: fix)
        }
        if StableBinaryPath.isMovable(command, homes: [env.home.path] + [fs.realPath(env.home.path)].compactMap { $0 }) {
            return DoctorCheck(.warn, area, "points at \(command), which can move or be deleted by brew upgrade.", fix: fix)
        }
        return DoctorCheck(.ok, area, okMessage(command))
    }

    // MARK: Memory store

    func memoryStore() -> DoctorCheck {
        let area = Self.storeArea
        let root = env.memoriesRoot
        let path = root.path
        var isDir: ObjCBool = false

        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
            // Not created yet — Engram makes it on first use, if the nearest existing folder is writable.
            var ancestor = root.deletingLastPathComponent()
            while !FileManager.default.fileExists(atPath: ancestor.path), ancestor.path != "/" {
                ancestor = ancestor.deletingLastPathComponent()
            }
            if let error = Self.accessError(ancestor.path, W_OK) {
                return DoctorCheck(.fail, area, "can't write \(path): \(error)")
            }
            return DoctorCheck(.ok, area, "0 files, 0 memories · \(path)")
        }
        guard isDir.boolValue else { return DoctorCheck(.fail, area, "can't read \(path): it isn't a folder") }
        if let error = Self.accessError(path, R_OK | X_OK) {
            return DoctorCheck(.fail, area, "can't read \(path): \(error)")
        }
        if let error = Self.accessError(path, W_OK) {
            return DoctorCheck(.fail, area, "can't write \(path): \(error)")
        }

        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])
                .filter { $0.pathExtension == "md" }
        } catch {
            return DoctorCheck(.fail, area, "can't read \(path): \(error.localizedDescription)")
        }
        guard !files.isEmpty else { return DoctorCheck(.ok, area, "0 files, 0 memories · \(path)") }

        // The folder exists, so MarkdownStore's createDirectory is a no-op — this only reads.
        let memories = ((try? MarkdownStore(root: root))?.allMemories() ?? []).filter { !$0.deleted }.count
        let newest = files.compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }.max()
        let fileWord = files.count == 1 ? "file" : "files"
        let memoryWord = memories == 1 ? "memory" : "memories"
        var message = "\(files.count) \(fileWord), \(memories) \(memoryWord)"
        if let newest { message += ", last change \(Self.relative(newest, to: now()))" }
        return DoctorCheck(.ok, area, message + " · \(path)")
    }

    /// nil when access(2) allows `mode`, else the system's reason ("Permission denied").
    static func accessError(_ path: String, _ mode: Int32) -> String? {
        guard access(path, mode) != 0 else { return nil }
        let code = errno   // read before anything else can overwrite it
        return String(cString: strerror(code))
    }

    static func relative(_ date: Date, to now: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: now)
    }

    // MARK: Embeddings

    func embeddings() -> DoctorCheck {
        if embeddingsAvailable() { return DoctorCheck(.ok, Self.embeddingsArea, "on-device transformer model") }
        return DoctorCheck(.warn, Self.embeddingsArea,
                           "basic word model (the better on-device model isn't downloaded). Optional: engram-mcp --prepare-embeddings")
    }
}
