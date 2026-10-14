import Foundation

// `engram-mcp --connect` lives here (not in the executable) so every decision it makes is a pure,
// unit-testable function: which binary path to write, how to merge the user's config, and whether the
// write really landed. The executable only gathers the real environment and prints the lines.

// MARK: - Host environment

/// Everything --connect needs to know about the machine, gathered in ONE place so tests can point every
/// path at a temp folder and never see the user's real configs.
public struct HostEnvironment {
    public var home: URL
    public var cwd: String
    /// The PATH used to find executables (never the process's own PATH implicitly).
    public var pathEnv: String
    /// Environment variables: overrides (ENGRAM_CLAUDE_CONFIG, …) are read from here.
    public var variables: [String: String]
    public var memoriesRoot: URL

    public init(home: URL, cwd: String, pathEnv: String, variables: [String: String], memoriesRoot: URL) {
        self.home = home
        self.cwd = cwd
        self.pathEnv = pathEnv
        self.variables = variables
        self.memoriesRoot = memoriesRoot
    }

    /// The real environment of this process. HOME is honored when set (so a scratch HOME keeps a test run
    /// away from the user's files).
    public static func current() -> HostEnvironment {
        let vars = ProcessInfo.processInfo.environment
        let home: URL
        if let h = vars["HOME"], !h.isEmpty {
            home = URL(fileURLWithPath: h, isDirectory: true)
        } else {
            home = FileManager.default.homeDirectoryForCurrentUser
        }
        return HostEnvironment(home: home,
                               cwd: FileManager.default.currentDirectoryPath,
                               pathEnv: vars["PATH"] ?? "",
                               variables: vars,
                               memoriesRoot: CombinedFileStore.defaultMemoriesRoot())
    }

    func override(_ key: String) -> String? {
        guard let v = variables[key], !v.isEmpty else { return nil }
        return v
    }

    /// Claude Desktop's config file (ENGRAM_CLAUDE_CONFIG overrides the location).
    public var desktopConfigURL: URL {
        if let p = override("ENGRAM_CLAUDE_CONFIG") { return URL(fileURLWithPath: p) }
        return home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
    }
}

// MARK: - File-system probe

/// The few file-system questions path resolution asks. Injectable so a test can fake a machine; the
/// default answers from the real disk.
public protocol FileSystemProbe {
    /// Exists, is a regular file (after following symlinks) and is executable by this user.
    func isExecutableFile(_ path: String) -> Bool
    func fileExists(_ path: String) -> Bool
    /// The canonical path with every symlink resolved (realpath), or nil if it doesn't resolve.
    func realPath(_ path: String) -> String?
}

public struct LocalFileSystem: FileSystemProbe {
    public init() {}

    public func isExecutableFile(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else { return false }
        return access(path, X_OK) == 0
    }

    public func fileExists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

    public func realPath(_ path: String) -> String? {
        guard let p = realpath(path, nil) else { return nil }
        defer { free(p) }
        return String(cString: p)
    }
}

// MARK: - Which binary to point Claude at

public enum StableBinaryPath {
    public enum Resolution: Equatable {
        /// Write `path`. `canMove` = it sits in a build folder, the Cellar or ~/Desktop, so it may vanish.
        case runnable(path: String, canMove: Bool)
        /// No runnable binary — write nothing. `lookedAt` names what was checked, for the message.
        case notRunnable(lookedAt: String)
    }

    /// Resolve argv[0] to the absolute path Claude should launch.
    ///
    /// - argv0 with a '/': made absolute against `cwd` (symlinks are NOT resolved — a symlink like
    ///   /opt/homebrew/bin/engram-mcp is exactly the stable thing we want).
    /// - a bare name: the first executable with that name on `pathEnv` (what the shell ran).
    /// - a Homebrew Cellar path (<prefix>/Cellar/engram/<ver>/bin/<name>) maps to <prefix>/bin/<name> when
    ///   that link exists and resolves into Cellar/engram, so `brew upgrade` never breaks the config.
    public static func resolve(argv0: String, cwd: String, pathEnv: String, home: String,
                               fs: FileSystemProbe = LocalFileSystem()) -> Resolution {
        guard !argv0.isEmpty else { return .notRunnable(lookedAt: "(no program name)") }

        let found: String
        if argv0.contains("/") {
            found = absolute(argv0, cwd: cwd)
        } else {
            var hit: String?
            for dir in pathEnv.split(separator: ":", omittingEmptySubsequences: false).map(String.init) {
                let base = dir.isEmpty ? cwd : absolute(dir, cwd: cwd)   // an empty PATH entry means "."
                let candidate = normalize(base + "/" + argv0)
                if fs.isExecutableFile(candidate) { hit = candidate; break }
            }
            guard let hit else { return .notRunnable(lookedAt: "\(argv0) on your PATH") }
            found = hit
        }

        guard fs.isExecutableFile(found), let real = fs.realPath(found) else {
            return .notRunnable(lookedAt: found)
        }

        var final = found
        var mappedToBrewBin = false
        if let prefix = cellarPrefix(of: real) {
            let name = (real as NSString).lastPathComponent
            let link = prefix + "/bin/" + name
            if fs.fileExists(link), fs.isExecutableFile(link),
               let linkReal = fs.realPath(link), linkReal.hasPrefix(prefix + "/Cellar/engram/") {
                final = link
                mappedToBrewBin = true
            }
        }

        let homes = [home] + [fs.realPath(home)].compactMap { $0 }
        let canMove = isMovable(final, homes: homes) || (!mappedToBrewBin && isMovable(real, homes: homes))
        return .runnable(path: final, canMove: canMove)
    }

    /// <prefix> when `path` is <prefix>/Cellar/engram/<version>/bin/<name>, else nil.
    static func cellarPrefix(of path: String) -> String? {
        let parts = path.components(separatedBy: "/")
        // … <prefix> / Cellar / engram / <ver> / bin / <name>
        guard parts.count >= 6 else { return nil }
        let n = parts.count
        guard parts[n - 2] == "bin", parts[n - 4] == "engram", parts[n - 5] == "Cellar",
              !parts[n - 3].isEmpty else { return nil }
        let prefix = parts[0..<(n - 5)].joined(separator: "/")
        return prefix.isEmpty ? nil : prefix
    }

    /// In a build folder, the Homebrew Cellar, or on the Desktop — all places a binary can move or vanish.
    public static func isMovable(_ path: String, home: String) -> Bool {
        isMovable(path, homes: [home])
    }

    static func isMovable(_ path: String, homes: [String]) -> Bool {
        if path.contains("/.build/") || path.contains("/Cellar/") { return true }
        return homes.contains { h in
            let desktop = (h.hasSuffix("/") ? String(h.dropLast()) : h) + "/Desktop/"
            return path.hasPrefix(desktop)
        }
    }

    static func absolute(_ path: String, cwd: String) -> String {
        normalize(path.hasPrefix("/") ? path : cwd + "/" + path)
    }

    /// Lexical cleanup of "." / ".." / "//" — no file-system access, so symlinks stay as written.
    static func normalize(_ path: String) -> String {
        var out: [String] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..": if !out.isEmpty { out.removeLast() }
            default: out.append(String(part))
            }
        }
        return "/" + out.joined(separator: "/")
    }
}

// MARK: - Claude Desktop config

public enum DesktopConfig {
    public enum MergeResult: Equatable {
        case merged(Data)
        /// The file exists but isn't a JSON object we can safely edit — the caller must not overwrite it.
        case invalidJSON
    }

    /// Put `mcpServers.engram = {command}` into the config, keeping everything else the user has (other
    /// servers, Claude Desktop's own preferences, coworkUserFilesPath, …). `existing == nil` = no file yet.
    public static func merge(existing: Data?, command: String) -> MergeResult {
        var root: [String: Any] = [:]
        if let existing {
            guard let obj = (try? JSONSerialization.jsonObject(with: existing)) as? [String: Any] else {
                return .invalidJSON
            }
            root = obj
        }
        var servers: [String: Any] = [:]
        if let existingServers = root["mcpServers"] {
            // A non-object mcpServers would be wiped by an overwrite — treat it like invalid JSON.
            guard let dict = existingServers as? [String: Any] else { return .invalidJSON }
            servers = dict
        }
        servers["engram"] = ["command": command]
        root["mcpServers"] = servers
        guard let out = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) else {
            return .invalidJSON
        }
        return .merged(out)
    }

    /// mcpServers.engram.command, or nil when the file has no engram entry (or isn't valid JSON).
    public static func engramCommand(in data: Data) -> String? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let servers = obj["mcpServers"] as? [String: Any],
              let engram = servers["engram"] as? [String: Any] else { return nil }
        return engram["command"] as? String
    }
}

// MARK: - Connection records

/// "Engram connected <client> to <command> at <time>" — kept next to combined-files.json so a later
/// `--doctor` can tell "never connected" from "connected, then dropped".
public struct ConnectionRecord: Codable, Equatable, Sendable {
    public var client: String
    public var command: String
    public var connectedAt: Date

    public init(client: String, command: String, connectedAt: Date) {
        self.client = client
        self.command = command
        self.connectedAt = connectedAt
    }

    private enum CodingKeys: String, CodingKey { case client, command, connectedAt }

    // Every field decodes with a default, so a file written by an older or newer build never fails to load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        client = try c.decodeIfPresent(String.self, forKey: .client) ?? ""
        command = try c.decodeIfPresent(String.self, forKey: .command) ?? ""
        connectedAt = try c.decodeIfPresent(Date.self, forKey: .connectedAt) ?? .distantPast
    }
}

public enum ConnectionStore {
    /// …/Engram/connections.json — the parent of the memories folder, like combined-files.json.
    public static func url(memoriesRoot: URL) -> URL {
        memoriesRoot.deletingLastPathComponent().appendingPathComponent("connections.json", isDirectory: false)
    }

    public static func load(memoriesRoot: URL) -> [ConnectionRecord] {
        guard let data = try? Data(contentsOf: url(memoriesRoot: memoriesRoot)) else { return [] }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return (try? d.decode([ConnectionRecord].self, from: data)) ?? []
    }

    /// Replace (or add) the record for `record.client`. Returns true only if the file was written.
    @discardableResult
    public static func save(_ record: ConnectionRecord, memoriesRoot: URL) -> Bool {
        var all = load(memoriesRoot: memoriesRoot).filter { $0.client != record.client }
        all.append(record)
        all.sort { $0.client < $1.client }
        let u = url(memoriesRoot: memoriesRoot)
        do {
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            let e = JSONEncoder()
            e.dateEncodingStrategy = .iso8601
            e.outputFormatting = [.prettyPrinted, .sortedKeys]
            try e.encode(all).write(to: u, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}

// MARK: - Connect

/// What a --connect run said and whether it failed. `messages` go to stdout (for people), `logs` to stderr.
public struct ConnectReport: Equatable {
    public var messages: [String] = []
    public var logs: [String] = []
    public var failed = false
    public init() {}
}

public struct Connector {
    public static let desktopClient = "claude-desktop"

    public let env: HostEnvironment
    public let fs: FileSystemProbe
    public let now: () -> Date

    public init(env: HostEnvironment, fs: FileSystemProbe = LocalFileSystem(), now: @escaping () -> Date = Date.init) {
        self.env = env
        self.fs = fs
        self.now = now
    }

    /// Resolve the binary once, then connect Claude Desktop. Writes nothing when no runnable binary exists.
    public func run(argv0: String) -> ConnectReport {
        var report = ConnectReport()
        switch StableBinaryPath.resolve(argv0: argv0, cwd: env.cwd, pathEnv: env.pathEnv, home: env.home.path, fs: fs) {
        case .notRunnable(let lookedAt):
            report.messages.append("Couldn't find a runnable engram-mcp to point Claude at (looked at \(lookedAt)). Nothing was changed.")
            report.logs.append("engram-mcp: connect refused — no runnable binary (looked at \(lookedAt))")
            report.failed = true
            return report
        case .runnable(let path, let canMove):
            if canMove {
                report.messages.append("Heads-up: \(path) is inside a build folder or your Desktop, so it can move. The Homebrew install is the stable choice.")
            }
            connectDesktop(binary: path, into: &report)
            return report
        }
    }

    /// Merge, write atomically, then re-read: success is printed only when the file on disk says so.
    public func connectDesktop(binary: String, into report: inout ConnectReport) {
        let configURL = env.desktopConfigURL
        let configPath = configURL.path
        let existing = FileManager.default.contents(atPath: configPath)

        switch DesktopConfig.merge(existing: existing, command: binary) {
        case .invalidJSON:
            // Present but not editable: overwriting would wipe the user's other servers. Back up and bail.
            let bak = configPath + ".engram-backup"
            if let existing { try? existing.write(to: URL(fileURLWithPath: bak)) }
            report.logs.append("engram-mcp: existing config is not valid JSON — left untouched (backup at \(bak))")
            report.messages.append("Your Claude Desktop config isn't valid JSON, so I didn't touch it (backed it up to \(bak)). Fix it, then re-run --connect.")
            report.failed = true

        case .merged(let data):
            do {
                try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: configURL, options: .atomic)   // atomic — never leave a truncated config
            } catch {
                report.logs.append("engram-mcp: connect FAILED writing \(configPath): \(error)")
                report.messages.append("Couldn't connect Claude Desktop: \(error.localizedDescription)")
                report.failed = true
                return
            }
            guard let back = FileManager.default.contents(atPath: configPath),
                  DesktopConfig.engramCommand(in: back) == binary else {
                report.logs.append("engram-mcp: connect FAILED — \(configPath) doesn't contain the new entry after writing")
                report.messages.append("Couldn't connect Claude Desktop: the config didn't keep the change (\(configPath)).")
                report.failed = true
                return
            }
            if !ConnectionStore.save(ConnectionRecord(client: Self.desktopClient, command: binary, connectedAt: now()),
                                     memoriesRoot: env.memoriesRoot) {
                report.logs.append("engram-mcp: couldn't record the connection in \(ConnectionStore.url(memoriesRoot: env.memoriesRoot).path)")
            }
            report.logs.append("engram-mcp: connected → \(configPath) (command = \(binary))")
            report.messages.append("Engram is connected to Claude Desktop (\(binary)). Quit and reopen Claude Desktop to load it.")
        }
    }
}
