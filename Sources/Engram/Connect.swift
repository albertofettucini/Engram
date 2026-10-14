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
    /// Where apps are installed (Claude.app is looked for here).
    public var applicationsDirs: [String]

    public init(home: URL, cwd: String, pathEnv: String, variables: [String: String], memoriesRoot: URL,
                applicationsDirs: [String] = ["/Applications"]) {
        self.home = home
        self.cwd = cwd
        self.pathEnv = pathEnv
        self.variables = variables
        self.memoriesRoot = memoriesRoot
        self.applicationsDirs = applicationsDirs
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
        return desktopSupportDir.appendingPathComponent("claude_desktop_config.json")
    }

    /// ~/Library/Application Support/Claude — exists once Claude Desktop has run.
    public var desktopSupportDir: URL {
        home.appendingPathComponent("Library/Application Support/Claude", isDirectory: true)
    }

    /// Claude Desktop counts as installed when its support folder or Claude.app exists (or a config
    /// location was given explicitly with ENGRAM_CLAUDE_CONFIG).
    public var desktopDetected: Bool {
        if override("ENGRAM_CLAUDE_CONFIG") != nil { return true }
        if FileManager.default.fileExists(atPath: desktopSupportDir.path) { return true }
        return applicationsDirs.contains { FileManager.default.fileExists(atPath: $0 + "/Claude.app") }
    }

    /// Claude Code's user-scope config, read-only for Engram (only the `claude` CLI writes it).
    /// ENGRAM_CLAUDE_CODE_CONFIG overrides (and --connect then points the `claude` CLI at it through
    /// CLAUDE_CONFIG_DIR, so it must name a .claude.json file); CLAUDE_CONFIG_DIR moves it the same way
    /// it moves it for Claude Code.
    public var claudeCodeConfigURL: URL {
        if let p = override("ENGRAM_CLAUDE_CODE_CONFIG") { return URL(fileURLWithPath: p) }
        if let dir = override("CLAUDE_CONFIG_DIR") { return URL(fileURLWithPath: dir).appendingPathComponent(".claude.json") }
        return home.appendingPathComponent(".claude.json")
    }

    /// Claude Desktop's log folder (ENGRAM_CLAUDE_LOGS overrides) — mcp-server-engram.log there means
    /// Claude Desktop has launched Engram before.
    public var claudeLogsDir: URL {
        if let p = override("ENGRAM_CLAUDE_LOGS") { return URL(fileURLWithPath: p, isDirectory: true) }
        return home.appendingPathComponent("Library/Logs/Claude", isDirectory: true)
    }

    /// The first `name` executable on this environment's PATH.
    public func findExecutable(_ name: String, fs: FileSystemProbe = LocalFileSystem()) -> String? {
        StableBinaryPath.findOnPath(name, pathEnv: pathEnv, cwd: cwd, fs: fs)
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
            guard let hit = findOnPath(argv0, pathEnv: pathEnv, cwd: cwd, fs: fs) else {
                return .notRunnable(lookedAt: "\(argv0) on your PATH")
            }
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

    /// The first executable called `name` on `pathEnv`, as the shell would find it.
    public static func findOnPath(_ name: String, pathEnv: String, cwd: String,
                                  fs: FileSystemProbe = LocalFileSystem()) -> String? {
        for dir in pathEnv.split(separator: ":", omittingEmptySubsequences: false).map(String.init) {
            let base = dir.isEmpty ? cwd : absolute(dir, cwd: cwd)   // an empty PATH entry means "."
            let candidate = normalize(base + "/" + name)
            if fs.isExecutableFile(candidate) { return candidate }
        }
        return nil
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

// MARK: - Claude Code config (read-only)

/// Engram never edits ~/.claude.json itself — the `claude` CLI does. This only reads the user-scope entry,
/// so --connect can tell whether a change is needed (and verify it landed) WITHOUT `claude mcp get`, which
/// launches stdio servers (including the current folder's .mcp.json) to health-check them.
public enum ClaudeCodeConfig {
    public struct Entry: Equatable {
        public var command: String?
        public var args: [String]
        public var type: String?
    }

    public enum Read: Equatable {
        case noFile
        case unreadable
        case noEntry
        case entry(Entry)
    }

    /// Top-level mcpServers.engram (= user scope).
    public static func userEngramEntry(in data: Data) -> Read {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return .unreadable }
        guard let servers = obj["mcpServers"] as? [String: Any],
              let engram = servers["engram"] as? [String: Any] else { return .noEntry }
        return .entry(Entry(command: engram["command"] as? String,
                            args: engram["args"] as? [String] ?? [],
                            type: engram["type"] as? String))
    }

    public static func userEngramEntry(at url: URL) -> Read {
        guard let data = FileManager.default.contents(atPath: url.path) else { return .noFile }
        return userEngramEntry(in: data)
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

// MARK: - Command line

/// The MCP clients --connect knows how to connect.
public enum ConnectClient: String, CaseIterable, Sendable {
    case claudeDesktop = "claude-desktop"
    case claudeCode = "claude-code"
}

/// What `engram-mcp <args>` should do. Anything it doesn't recognize starts the server, as before.
public enum EngramCommand: Equatable {
    case serve
    /// nil = every detected client.
    case connect([ConnectClient]?)
    case doctor
    case prepareEmbeddings
    case usageError(String)

    /// `arguments` excludes the program name.
    public static func parse(_ arguments: [String]) -> EngramCommand {
        if let i = arguments.firstIndex(of: "--connect") {
            var clients: [ConnectClient] = []
            for token in arguments[(i + 1)...] {
                if token.hasPrefix("-") { break }
                guard let client = ConnectClient(rawValue: token) else {
                    return .usageError("Unknown client \"\(token)\". Use: engram-mcp --connect [claude-desktop | claude-code]")
                }
                if !clients.contains(client) { clients.append(client) }
            }
            return .connect(clients.isEmpty ? nil : clients)
        }
        if arguments.contains("--doctor") { return .doctor }
        if arguments.contains("--prepare-embeddings") { return .prepareEmbeddings }
        return .serve
    }
}

// MARK: - Running the claude CLI

public struct ProcessOutcome: Equatable {
    public var status: Int32
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool
    /// Set when the process couldn't be started at all.
    public var launchError: String?
}

enum ProcessRunner {
    /// Run `executable` with `arguments` in a FRESH, empty temp folder (so nothing the user's current folder
    /// contains — a .mcp.json, say — is ever picked up), stdin closed, output captured, killed after `timeout`.
    static func run(_ executable: String, _ arguments: [String], environment: [String: String],
                    timeout: TimeInterval) -> ProcessOutcome {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("engram-connect-" + UUID().uuidString, isDirectory: true)
        let outURL = work.appendingPathComponent("stdout.txt")
        let errURL = work.appendingPathComponent("stderr.txt")
        defer { try? fm.removeItem(at: work) }
        do {
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            fm.createFile(atPath: outURL.path, contents: nil)
            fm.createFile(atPath: errURL.path, contents: nil)
        } catch {
            return ProcessOutcome(status: -1, stdout: "", stderr: "", timedOut: false, launchError: error.localizedDescription)
        }
        // Files, not pipes: a chatty process can't deadlock on a full pipe buffer.
        guard let outHandle = try? FileHandle(forWritingTo: outURL),
              let errHandle = try? FileHandle(forWritingTo: errURL) else {
            return ProcessOutcome(status: -1, stdout: "", stderr: "", timedOut: false, launchError: "couldn't create output files")
        }
        defer { try? outHandle.close(); try? errHandle.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = work
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outHandle
        process.standardError = errHandle

        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do {
            try process.run()
        } catch {
            return ProcessOutcome(status: -1, stdout: "", stderr: "", timedOut: false, launchError: error.localizedDescription)
        }
        var timedOut = false
        if done.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if done.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = done.wait(timeout: .now() + 2)
            }
        }
        let out = (try? String(contentsOf: outURL, encoding: .utf8)) ?? ""
        let err = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
        return ProcessOutcome(status: timedOut ? -1 : process.terminationStatus, stdout: out, stderr: err,
                              timedOut: timedOut, launchError: nil)
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
    public let env: HostEnvironment
    public let fs: FileSystemProbe
    public let now: () -> Date
    /// How long one `claude mcp …` call may take.
    public let processTimeout: TimeInterval

    public init(env: HostEnvironment, fs: FileSystemProbe = LocalFileSystem(),
                now: @escaping () -> Date = Date.init, processTimeout: TimeInterval = 20) {
        self.env = env
        self.fs = fs
        self.now = now
        self.processTimeout = processTimeout
    }

    /// Resolve the binary once, then connect `clients` (nil = every detected client). Writes nothing when
    /// no runnable binary exists. Fails only when a client it tried to connect couldn't be connected.
    public func run(argv0: String, clients: [ConnectClient]?) -> ConnectReport {
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
            let requested = clients != nil
            for client in clients ?? ConnectClient.allCases {
                switch client {
                case .claudeDesktop:
                    if requested || env.desktopDetected {
                        connectDesktop(binary: path, into: &report)
                    } else {
                        report.messages.append("Claude Desktop isn't installed here — skipped.")
                    }
                case .claudeCode:
                    connectClaudeCode(binary: path, requested: requested, into: &report)
                }
            }
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
            record(.claudeDesktop, binary, into: &report)
            report.logs.append("engram-mcp: connected → \(configPath) (command = \(binary))")
            report.messages.append("Engram is connected to Claude Desktop (\(binary)). Quit and reopen Claude Desktop to load it.")
        }
    }

    /// Register Engram at Claude Code's USER scope through the `claude` CLI (Engram never edits
    /// ~/.claude.json itself). Only `claude mcp remove` / `claude mcp add` are ever run — never
    /// `claude mcp get`, which launches servers to health-check them.
    public func connectClaudeCode(binary: String, requested: Bool, into report: inout ConnectReport) {
        let addCommand = "claude mcp add -s user engram -- \(Self.shellQuoted(binary))"
        guard let claude = env.findExecutable("claude", fs: fs) else {
            report.messages.append("Claude Code isn't installed here (no `claude` on PATH) — skipped. To add it later: \(addCommand)")
            if requested { report.failed = true }   // asked for by name, and it didn't happen
            return
        }
        func fail(_ reason: String) {
            var r = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            while r.hasSuffix(".") { r.removeLast() }
            report.logs.append("engram-mcp: Claude Code connect FAILED: \(r)")
            report.messages.append("Couldn't connect Claude Code: \(r). Run this yourself: \(addCommand)")
            report.failed = true
        }

        let configURL = env.claudeCodeConfigURL
        var needsRemove = false
        if case .entry(let e) = ClaudeCodeConfig.userEngramEntry(at: configURL) {
            let alreadyRight = e.command == binary && e.args.isEmpty && (e.type == nil || e.type == "stdio")
            needsRemove = !alreadyRight
            if alreadyRight {
                record(.claudeCode, binary, into: &report)
                report.messages.append("Engram is connected to Claude Code (user scope). New Claude Code sessions will see it.")
                return
            }
        }

        var processEnv = env.variables
        processEnv["PATH"] = env.pathEnv
        processEnv["HOME"] = env.home.path
        // ENGRAM_CLAUDE_CODE_CONFIG moves where Engram reads; the CLI has to write that same file, or
        // a scratch run would edit the user's real ~/.claude.json. Claude Code only writes
        // <CLAUDE_CONFIG_DIR>/.claude.json, so point it there — or don't run it at all.
        if env.override("ENGRAM_CLAUDE_CODE_CONFIG") != nil {
            guard configURL.lastPathComponent == ".claude.json" else {
                return fail("ENGRAM_CLAUDE_CODE_CONFIG points at \(configURL.path), and `claude` only writes a file named .claude.json, so I didn't run it")
            }
            processEnv["CLAUDE_CONFIG_DIR"] = configURL.deletingLastPathComponent().path
        }

        if needsRemove {
            let out = ProcessRunner.run(claude, ["mcp", "remove", "engram", "-s", "user"],
                                        environment: processEnv, timeout: processTimeout)
            if let reason = failureReason(out, step: "claude mcp remove") { return fail(reason) }
        }
        let out = ProcessRunner.run(claude, ["mcp", "add", "-s", "user", "engram", "--", binary],
                                    environment: processEnv, timeout: processTimeout)
        if let reason = failureReason(out, step: "claude mcp add") { return fail(reason) }

        guard case .entry(let e) = ClaudeCodeConfig.userEngramEntry(at: configURL), e.command == binary else {
            return fail("`claude mcp add` finished, but \(configURL.path) doesn't show the new entry")
        }
        record(.claudeCode, binary, into: &report)
        report.logs.append("engram-mcp: connected Claude Code (user scope, command = \(binary))")
        report.messages.append("Engram is connected to Claude Code (user scope). New Claude Code sessions will see it.")
    }

    // MARK: helpers

    private func record(_ client: ConnectClient, _ binary: String, into report: inout ConnectReport) {
        if !ConnectionStore.save(ConnectionRecord(client: client.rawValue, command: binary, connectedAt: now()),
                                 memoriesRoot: env.memoriesRoot) {
            report.logs.append("engram-mcp: couldn't record the connection in \(ConnectionStore.url(memoriesRoot: env.memoriesRoot).path)")
        }
    }

    /// nil when the step succeeded; otherwise a short reason for the message.
    func failureReason(_ out: ProcessOutcome, step: String) -> String? {
        if let e = out.launchError { return "couldn't run `\(step)` (\(e))" }
        if out.timedOut { return "`\(step)` didn't finish within \(Int(processTimeout)) seconds" }
        guard out.status != 0 else { return nil }
        let firstLine = (out.stderr + "\n" + out.stdout)   // the CLI's own error, stderr first
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        return firstLine.map { "`\(step)` said \"\($0)\"" } ?? "`\(step)` exited with status \(out.status)"
    }

    /// Quote a path for a command the user will paste, only when it needs it.
    static func shellQuoted(_ s: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-+@%:,=")
        if !s.isEmpty, s.unicodeScalars.allSatisfy({ safe.contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
