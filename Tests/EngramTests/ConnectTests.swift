import XCTest
@testable import Engram

/// `engram-mcp --connect`: every test builds a fake machine in a temp folder (fake PATH, fake Homebrew
/// prefix, scratch config) — nothing here reads or writes the user's real Claude configs.
final class ConnectTests: XCTestCase {

    private var tmp: URL!
    private let fsProbe = LocalFileSystem()

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("engram-connect-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: claudeJSON.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: helpers

    private var home: String { tmp.appendingPathComponent("home").path }

    @discardableResult
    private func makeFile(_ relative: String, executable: Bool = true) throws -> String {
        let url = tmp.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 0\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: url.path)
        return url.path
    }

    /// A fake Homebrew prefix: <prefix>/Cellar/engram/0.1.1/bin/engram-mcp plus the <prefix>/bin link.
    private func makeBrewPrefix(linked: Bool = true) throws -> (prefix: String, cellarBinary: String) {
        let cellar = try makeFile("brew/Cellar/engram/0.1.1/bin/engram-mcp")
        let prefix = tmp.appendingPathComponent("brew").path
        if linked {
            try FileManager.default.createDirectory(atPath: prefix + "/bin", withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: prefix + "/bin/engram-mcp",
                                                       withDestinationPath: "../Cellar/engram/0.1.1/bin/engram-mcp")
        }
        return (prefix, cellar)
    }

    /// A hermetic environment: scratch HOME, scratch configs, a PATH of temp folders only, and an empty
    /// Applications folder (so the real /Applications/Claude.app never counts as "installed").
    private func env(config: String? = nil, path: String = "/nonexistent", desktopOverride: Bool = true) -> HostEnvironment {
        var vars: [String: String] = [:]
        if desktopOverride {
            vars["ENGRAM_CLAUDE_CONFIG"] = config ?? tmp.appendingPathComponent("claude_desktop_config.json").path
        }
        vars["ENGRAM_CLAUDE_CODE_CONFIG"] = claudeJSON.path
        return HostEnvironment(home: URL(fileURLWithPath: home), cwd: tmp.path, pathEnv: path,
                               variables: vars, memoriesRoot: tmp.appendingPathComponent("engram/memories"),
                               applicationsDirs: [tmp.appendingPathComponent("Applications").path])
    }

    /// Named .claude.json like the real file: --connect points the CLI here through CLAUDE_CONFIG_DIR.
    private var claudeJSON: URL { tmp.appendingPathComponent("code-config/.claude.json") }
    private var claudeLog: URL { tmp.appendingPathComponent("fake-claude-argv.log") }
    private var fakeBin: String { tmp.appendingPathComponent("fakebin").path }

    /// A fake `claude` on a temp PATH: logs "<cwd>|<argv>" and edits $CLAUDE_CONFIG_DIR/.claude.json the
    /// way the real CLI would (so a test fails if --connect doesn't point the CLI at the scratch config).
    /// `behavior` swaps in a failing, lying or hanging CLI. CI never calls a real `claude`.
    private func installFakeClaude(_ behavior: String = "ok") throws {
        let config = "$CLAUDE_CONFIG_DIR/.claude.json", log = claudeLog.path
        let body: String
        switch behavior {
        case "fail":  body = "echo 'MCP server engram already exists in user config.' >&2; exit 1"
        case "lie":   body = "exit 0"
        case "hang":  body = "exec /bin/sleep 30"
        default:
            body = """
            case "$1 $2" in
              "mcp add") printf '{"mcpServers":{"engram":{"type":"stdio","command":"%s","args":[],"env":{}}},"numStartups":3}' "$7" > "\(config)" ;;
              "mcp remove") printf '{"mcpServers":{},"numStartups":3}' > "\(config)" ;;
              *) echo "unexpected: $*" >&2; exit 3 ;;
            esac
            """
        }
        let script = "#!/bin/sh\nprintf '%s|%s\\n' \"$PWD\" \"$*\" >> '\(log)'\n\(body)\n"
        try FileManager.default.createDirectory(atPath: fakeBin, withIntermediateDirectories: true)
        let url = URL(fileURLWithPath: fakeBin + "/claude")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// Each fake-claude call as (cwd, argv).
    private func claudeCalls() -> [(cwd: String, argv: String)] {
        guard let text = try? String(contentsOf: claudeLog, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map { line in
            let parts = line.split(separator: "|", maxSplits: 1).map(String.init)
            return (parts[0], parts.count > 1 ? parts[1] : "")
        }
    }

    private func resolve(_ argv0: String, cwd: String? = nil, path: String = "") -> StableBinaryPath.Resolution {
        StableBinaryPath.resolve(argv0: argv0, cwd: cwd ?? tmp.path, pathEnv: path, home: home, fs: fsProbe)
    }

    // MARK: binary path

    /// The shell runs `engram-mcp` by bare name: find it on PATH (the old code wrote cwd + "/engram-mcp").
    func testBareNameFoundViaPATH() throws {
        let binary = try makeFile("bin2/engram-mcp")
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("bin1"), withIntermediateDirectories: true)
        let path = tmp.appendingPathComponent("bin1").path + ":" + tmp.appendingPathComponent("bin2").path
        let cwd = tmp.appendingPathComponent("somewhere-else").path
        XCTAssertEqual(resolve("engram-mcp", cwd: cwd, path: path), .runnable(path: binary, canMove: false))
    }

    func testRelativeDotSlashIsMadeAbsolute() throws {
        let binary = try makeFile("tools/engram-mcp")
        let cwd = tmp.appendingPathComponent("tools").path
        XCTAssertEqual(resolve("./engram-mcp", cwd: cwd), .runnable(path: binary, canMove: false))
        XCTAssertEqual(resolve("../tools/./engram-mcp", cwd: cwd), .runnable(path: binary, canMove: false))
    }

    /// A Cellar path survives `brew upgrade` only through the <prefix>/bin link — write that instead.
    func testCellarPathMapsToBinSymlink() throws {
        let (prefix, cellarBinary) = try makeBrewPrefix()
        let canonicalPrefix = try XCTUnwrap(fsProbe.realPath(prefix))
        let expected = StableBinaryPath.Resolution.runnable(path: canonicalPrefix + "/bin/engram-mcp", canMove: false)

        XCTAssertEqual(resolve(cellarBinary), expected)
        XCTAssertEqual(resolve("engram-mcp", path: prefix + "/bin"), expected)   // ran via the brew link on PATH
    }

    func testUnlinkedCellarPathIsWrittenButWarned() throws {
        let (_, cellarBinary) = try makeBrewPrefix(linked: false)
        XCTAssertEqual(resolve(cellarBinary), .runnable(path: cellarBinary, canMove: true))
    }

    func testBuildFolderAndDesktopPathsWarn() throws {
        let build = try makeFile("repo/.build/debug/engram-mcp")
        XCTAssertEqual(resolve(build), .runnable(path: build, canMove: true))
        let desktop = try makeFile("home/Desktop/Engram/engram-mcp")
        XCTAssertEqual(resolve(desktop), .runnable(path: desktop, canMove: true))
    }

    func testNonExecutableOrMissingIsRefused() throws {
        let plain = try makeFile("bin/engram-mcp", executable: false)
        XCTAssertEqual(resolve(plain), .notRunnable(lookedAt: plain))
        XCTAssertEqual(resolve("engram-mcp", path: tmp.appendingPathComponent("bin").path),
                       .notRunnable(lookedAt: "engram-mcp on your PATH"))
        let dir = tmp.appendingPathComponent("adir/engram-mcp")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        XCTAssertEqual(resolve(dir.path), .notRunnable(lookedAt: dir.path))   // a directory isn't runnable
    }

    /// A non-runnable argv0 exits 1 and never creates the config.
    func testConnectWithNoRunnableBinaryWritesNothing() throws {
        let config = tmp.appendingPathComponent("c.json").path
        let report = Connector(env: env(config: config)).run(argv0: "./not-there/engram-mcp", clients: nil)
        XCTAssertTrue(report.failed)
        XCTAssertEqual(report.messages, [
            "Couldn't find a runnable engram-mcp to point Claude at (looked at \(tmp.path)/not-there/engram-mcp). Nothing was changed.",
        ])
        XCTAssertFalse(FileManager.default.fileExists(atPath: config))
        XCTAssertTrue(ConnectionStore.load(memoriesRoot: env().memoriesRoot).isEmpty)
    }

    // MARK: config merge

    func testMergeKeepsOtherServersAndPreferences() throws {
        let existing = """
        {"mcpServers":{"other":{"command":"/usr/local/bin/other","args":["--x"]},"engram":{"command":"/old/path"}},
         "preferences":{"menuBarEnabled":true,"sidebarMode":"chat"},
         "coworkUserFilesPath":"/Users/someone/Cowork"}
        """
        guard case .merged(let data) = DesktopConfig.merge(existing: Data(existing.utf8), command: "/opt/x/bin/engram-mcp") else {
            return XCTFail("valid config should merge")
        }
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let servers = try XCTUnwrap(obj["mcpServers"] as? [String: Any])
        XCTAssertEqual((servers["other"] as? [String: Any])?["command"] as? String, "/usr/local/bin/other")
        XCTAssertEqual((servers["other"] as? [String: Any])?["args"] as? [String], ["--x"])
        XCTAssertEqual((servers["engram"] as? [String: Any])?["command"] as? String, "/opt/x/bin/engram-mcp")
        XCTAssertEqual((obj["preferences"] as? [String: Any])?["sidebarMode"] as? String, "chat")
        XCTAssertEqual((obj["preferences"] as? [String: Any])?["menuBarEnabled"] as? Bool, true)
        XCTAssertEqual(obj["coworkUserFilesPath"] as? String, "/Users/someone/Cowork")
        XCTAssertEqual(DesktopConfig.engramCommand(in: data), "/opt/x/bin/engram-mcp")

        // No file yet → a fresh config with just the engram entry.
        guard case .merged(let fresh) = DesktopConfig.merge(existing: nil, command: "/a/engram-mcp") else {
            return XCTFail("missing config should merge")
        }
        XCTAssertEqual(DesktopConfig.engramCommand(in: fresh), "/a/engram-mcp")
    }

    func testMergeRefusesNonObjectJSON() {
        XCTAssertEqual(DesktopConfig.merge(existing: Data("{oops".utf8), command: "/a"), .invalidJSON)
        XCTAssertEqual(DesktopConfig.merge(existing: Data("[1,2]".utf8), command: "/a"), .invalidJSON)
        XCTAssertEqual(DesktopConfig.merge(existing: Data(#"{"mcpServers":[1]}"#.utf8), command: "/a"), .invalidJSON)
    }

    func testInvalidJSONIsBackedUpAndLeftUntouched() throws {
        let binary = try makeFile("bin/engram-mcp")
        let config = tmp.appendingPathComponent("c.json")
        let broken = "{\"mcpServers\": {\"other\": {\"command\": \"/x\"}},, }"
        try broken.write(to: config, atomically: true, encoding: .utf8)

        let report = Connector(env: env(config: config.path)).run(argv0: binary, clients: [.claudeDesktop])
        XCTAssertTrue(report.failed)
        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), broken)   // untouched
        let backup = config.path + ".engram-backup"
        XCTAssertEqual(try String(contentsOfFile: backup, encoding: .utf8), broken)
        XCTAssertEqual(report.messages, [
            "Your Claude Desktop config isn't valid JSON, so I didn't touch it (backed it up to \(backup)). Fix it, then re-run --connect.",
        ])
    }

    // MARK: end to end

    func testConnectWritesVerifiesAndRecords() throws {
        let binary = try makeFile("bin/engram-mcp")
        let config = tmp.appendingPathComponent("Claude/claude_desktop_config.json")
        let e = env(config: config.path)
        let at = Date(timeIntervalSince1970: 1_800_000_000)

        let report = Connector(env: e, now: { at }).run(argv0: binary, clients: [.claudeDesktop])
        XCTAssertFalse(report.failed)
        XCTAssertEqual(report.messages, [
            "Engram is connected to Claude Desktop (\(binary)). Quit and reopen Claude Desktop to load it.",
        ])
        XCTAssertEqual(DesktopConfig.engramCommand(in: try Data(contentsOf: config)), binary)
        XCTAssertEqual(ConnectionStore.load(memoriesRoot: e.memoriesRoot),
                       [ConnectionRecord(client: "claude-desktop", command: binary, connectedAt: at)])
        // connections.json sits next to the memories folder, like combined-files.json.
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("engram/connections.json").path))
    }

    func testBuildFolderBinaryPrintsHeadsUpButStillConnects() throws {
        let binary = try makeFile("repo/.build/debug/engram-mcp")
        let config = tmp.appendingPathComponent("c.json")
        let report = Connector(env: env(config: config.path)).run(argv0: binary, clients: [.claudeDesktop])
        XCTAssertFalse(report.failed)
        XCTAssertEqual(report.messages.first,
                       "Heads-up: \(binary) is inside a build folder or your Desktop, so it can move. The Homebrew install is the stable choice.")
        XCTAssertEqual(DesktopConfig.engramCommand(in: try Data(contentsOf: config)), binary)
    }

    /// A write that fails must never print success (the old code could).
    func testWriteFailureNeverPrintsSuccess() throws {
        let binary = try makeFile("bin/engram-mcp")
        try "not a folder".write(to: tmp.appendingPathComponent("blocker"), atomically: true, encoding: .utf8)
        let config = tmp.appendingPathComponent("blocker/claude_desktop_config.json").path   // parent is a file

        let report = Connector(env: env(config: config)).run(argv0: binary, clients: [.claudeDesktop])
        XCTAssertTrue(report.failed)
        XCTAssertFalse(report.messages.contains { $0.hasPrefix("Engram is connected") })
        XCTAssertTrue(report.messages.last?.hasPrefix("Couldn't connect Claude Desktop:") ?? false)
    }

    // MARK: records

    func testConnectionRecordDecodesMissingAndExtraFields() throws {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        let old = try d.decode([ConnectionRecord].self, from: Data(#"[{"client":"claude-desktop","future":1}]"#.utf8))
        XCTAssertEqual(old, [ConnectionRecord(client: "claude-desktop", command: "", connectedAt: .distantPast)])
    }

    func testConnectionStoreReplacesSameClient() {
        let root = tmp.appendingPathComponent("engram/memories")
        XCTAssertTrue(ConnectionStore.save(ConnectionRecord(client: "claude-desktop", command: "/a", connectedAt: Date(timeIntervalSince1970: 1)), memoriesRoot: root))
        XCTAssertTrue(ConnectionStore.save(ConnectionRecord(client: "claude-desktop", command: "/b", connectedAt: Date(timeIntervalSince1970: 2)), memoriesRoot: root))
        XCTAssertEqual(ConnectionStore.load(memoriesRoot: root).map(\.command), ["/b"])
    }

    // MARK: Claude Code (011-2)

    private let codeSuccess = "Engram is connected to Claude Code (user scope). New Claude Code sessions will see it."

    func testClaudeCodeIsAddedAtUserScopeFromATempFolder() throws {
        let binary = try makeFile("bin/engram-mcp")
        try installFakeClaude()
        // A project .mcp.json in the user's current folder must never be seen by the CLI run.
        try "{}".write(to: tmp.appendingPathComponent(".mcp.json"), atomically: true, encoding: .utf8)
        let e = env(path: fakeBin)

        let report = Connector(env: e).run(argv0: binary, clients: [.claudeCode])
        XCTAssertFalse(report.failed, report.messages.joined(separator: "\n"))
        XCTAssertEqual(report.messages, [codeSuccess])
        let calls = claudeCalls()
        XCTAssertEqual(calls.map { $0.argv }, ["mcp add -s user engram -- \(binary)"])
        XCTAssertNotEqual(calls.first?.cwd, tmp.path)
        XCTAssertTrue(calls.first?.cwd.contains("engram-connect-") ?? false)
        XCTAssertFalse(calls.contains { $0.argv.contains("get") })   // never `claude mcp get`
        XCTAssertEqual(ConnectionStore.load(memoriesRoot: e.memoriesRoot).map(\.client), ["claude-code"])
    }

    func testDifferentExistingEntryIsRemovedThenAdded() throws {
        let binary = try makeFile("bin/engram-mcp")
        try installFakeClaude()
        try #"{"mcpServers":{"engram":{"type":"stdio","command":"/old/Cellar/engram/0.1.0/bin/engram-mcp","args":[]}}}"#
            .write(to: claudeJSON, atomically: true, encoding: .utf8)

        let report = Connector(env: env(path: fakeBin)).run(argv0: binary, clients: [.claudeCode])
        XCTAssertFalse(report.failed)
        XCTAssertEqual(claudeCalls().map { $0.argv }, ["mcp remove engram -s user", "mcp add -s user engram -- \(binary)"])
        XCTAssertEqual(report.messages, [codeSuccess])
    }

    /// Scratch-config runs must never reach the user's real Claude Code config: the CLI is pointed at
    /// the override through CLAUDE_CONFIG_DIR (even over a CLAUDE_CONFIG_DIR already set), and an
    /// override the CLI can't be pointed at means the CLI isn't run at all.
    func testOverrideConfigIsWhereTheCLIWrites() throws {
        let binary = try makeFile("bin/engram-mcp")
        try installFakeClaude()
        let realDir = tmp.appendingPathComponent("real-claude-dir")
        var e = env(path: fakeBin)
        e.variables["CLAUDE_CONFIG_DIR"] = realDir.path
        let report = Connector(env: e).run(argv0: binary, clients: [.claudeCode])
        XCTAssertFalse(report.failed)
        XCTAssertEqual(report.messages, [codeSuccess])
        XCTAssertFalse(FileManager.default.fileExists(atPath: realDir.appendingPathComponent(".claude.json").path))
        guard case .entry(let entry) = ClaudeCodeConfig.userEngramEntry(at: claudeJSON) else {
            return XCTFail("the scratch config should hold the new entry")
        }
        XCTAssertEqual(entry.command, binary)
    }

    func testOverrideNotNamedClaudeJSONRunsNoCLI() throws {
        let binary = try makeFile("bin/engram-mcp")
        try installFakeClaude()
        let other = tmp.appendingPathComponent("claude.json")
        var e = env(path: fakeBin)
        e.variables["ENGRAM_CLAUDE_CODE_CONFIG"] = other.path
        let report = Connector(env: e).run(argv0: binary, clients: [.claudeCode])
        XCTAssertTrue(report.failed)
        XCTAssertTrue(claudeCalls().isEmpty)
        XCTAssertEqual(report.messages, [
            "Couldn't connect Claude Code: ENGRAM_CLAUDE_CODE_CONFIG points at \(other.path), and `claude` only writes a file named .claude.json, so I didn't run it. Run this yourself: claude mcp add -s user engram -- \(binary)",
        ])
    }

    func testMatchingEntryNeedsNoCLICall() throws {
        let binary = try makeFile("bin/engram-mcp")
        try installFakeClaude()
        try #"{"mcpServers":{"engram":{"type":"stdio","command":"\#(binary)","args":[],"env":{}}}}"#
            .write(to: claudeJSON, atomically: true, encoding: .utf8)

        let report = Connector(env: env(path: fakeBin)).run(argv0: binary, clients: [.claudeCode])
        XCTAssertFalse(report.failed)
        XCTAssertEqual(report.messages, [codeSuccess])
        XCTAssertTrue(claudeCalls().isEmpty)
    }

    func testMissingClaudePrintsTheCommandInstead() throws {
        let binary = try makeFile("bin/engram-mcp")
        let skipped = "Claude Code isn't installed here (no `claude` on PATH) — skipped. To add it later: claude mcp add -s user engram -- \(binary)"

        // Plain --connect: Claude Code wasn't detected, so it's skipped without failing the run.
        let all = Connector(env: env(path: fakeBin)).run(argv0: binary, clients: nil)
        XCTAssertFalse(all.failed)
        XCTAssertEqual(all.messages.last, skipped)

        // --connect claude-code: asked for by name and not done → exit 1.
        let named = Connector(env: env(path: fakeBin)).run(argv0: binary, clients: [.claudeCode])
        XCTAssertTrue(named.failed)
        XCTAssertEqual(named.messages, [skipped])
    }

    func testCLIErrorIsReportedWithTheCommandToRun() throws {
        let binary = try makeFile("bin/engram-mcp")
        try installFakeClaude("fail")
        let report = Connector(env: env(path: fakeBin)).run(argv0: binary, clients: [.claudeCode])
        XCTAssertTrue(report.failed)
        XCTAssertEqual(report.messages, [
            "Couldn't connect Claude Code: `claude mcp add` said \"MCP server engram already exists in user config.\". Run this yourself: claude mcp add -s user engram -- \(binary)",
        ])
    }

    /// The CLI says it worked but the config doesn't show it: never print success.
    func testCLISuccessWithoutTheEntryIsAFailure() throws {
        let binary = try makeFile("bin/engram-mcp")
        try installFakeClaude("lie")
        let report = Connector(env: env(path: fakeBin)).run(argv0: binary, clients: [.claudeCode])
        XCTAssertTrue(report.failed)
        XCTAssertFalse(report.messages.contains(codeSuccess))
        XCTAssertTrue(report.messages.first?.hasPrefix("Couldn't connect Claude Code: `claude mcp add` finished, but ") ?? false)
        XCTAssertTrue(ConnectionStore.load(memoriesRoot: env().memoriesRoot).isEmpty)
    }

    func testHangingCLITimesOut() throws {
        let binary = try makeFile("bin/engram-mcp")
        try installFakeClaude("hang")
        let start = Date()
        let report = Connector(env: env(path: fakeBin), processTimeout: 1).run(argv0: binary, clients: [.claudeCode])
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
        XCTAssertTrue(report.failed)
        XCTAssertEqual(report.messages, [
            "Couldn't connect Claude Code: `claude mcp add` didn't finish within 1 seconds. Run this yourself: claude mcp add -s user engram -- \(binary)",
        ])
    }

    /// Plain --connect connects every detected client: Desktop (its support folder exists) and Code.
    func testPlainConnectConnectsEveryDetectedClient() throws {
        let binary = try makeFile("bin/engram-mcp")
        try installFakeClaude()
        let e = env(path: fakeBin, desktopOverride: false)
        try FileManager.default.createDirectory(at: e.desktopSupportDir, withIntermediateDirectories: true)

        let report = Connector(env: e).run(argv0: binary, clients: nil)
        XCTAssertFalse(report.failed)
        XCTAssertEqual(report.messages, [
            "Engram is connected to Claude Desktop (\(binary)). Quit and reopen Claude Desktop to load it.",
            codeSuccess,
        ])
        XCTAssertEqual(DesktopConfig.engramCommand(in: try Data(contentsOf: e.desktopConfigURL)), binary)
        XCTAssertEqual(ConnectionStore.load(memoriesRoot: e.memoriesRoot).map(\.client), ["claude-code", "claude-desktop"])
    }

    func testUndetectedDesktopIsSkippedAndNotWritten() throws {
        let binary = try makeFile("bin/engram-mcp")
        try installFakeClaude()
        let e = env(path: fakeBin, desktopOverride: false)

        let report = Connector(env: e).run(argv0: binary, clients: nil)
        XCTAssertFalse(report.failed)
        XCTAssertEqual(report.messages, ["Claude Desktop isn't installed here — skipped.", codeSuccess])
        XCTAssertFalse(FileManager.default.fileExists(atPath: e.desktopConfigURL.path))
    }

    func testClaudeCodeConfigLocation() {
        let h = URL(fileURLWithPath: "/h")
        func url(_ vars: [String: String]) -> String {
            HostEnvironment(home: h, cwd: "/", pathEnv: "", variables: vars, memoriesRoot: h).claudeCodeConfigURL.path
        }
        XCTAssertEqual(url([:]), "/h/.claude.json")
        XCTAssertEqual(url(["CLAUDE_CONFIG_DIR": "/cfg"]), "/cfg/.claude.json")
        XCTAssertEqual(url(["CLAUDE_CONFIG_DIR": "/cfg", "ENGRAM_CLAUDE_CODE_CONFIG": "/x/c.json"]), "/x/c.json")
    }

    func testShellQuotingOfThePrintedCommand() {
        XCTAssertEqual(Connector.shellQuoted("/opt/homebrew/bin/engram-mcp"), "/opt/homebrew/bin/engram-mcp")
        XCTAssertEqual(Connector.shellQuoted("/Users/a b/engram-mcp"), "'/Users/a b/engram-mcp'")
        XCTAssertEqual(Connector.shellQuoted("/it's/engram-mcp"), #"'/it'\''s/engram-mcp'"#)
    }

    // MARK: argument parsing

    func testArgumentParsing() {
        XCTAssertEqual(EngramCommand.parse([]), .serve)
        XCTAssertEqual(EngramCommand.parse(["--connect"]), .connect(nil))
        XCTAssertEqual(EngramCommand.parse(["--connect", "claude-code"]), .connect([.claudeCode]))
        XCTAssertEqual(EngramCommand.parse(["--connect", "claude-desktop", "claude-code"]), .connect([.claudeDesktop, .claudeCode]))
        XCTAssertEqual(EngramCommand.parse(["--connect", "--verbose"]), .connect(nil))
        XCTAssertEqual(EngramCommand.parse(["--prepare-embeddings"]), .prepareEmbeddings)
        if case .usageError = EngramCommand.parse(["--connect", "cursor"]) {} else { XCTFail("unknown client must be a usage error") }
    }
}
