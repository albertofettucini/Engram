import XCTest
@testable import Engram

/// `engram-mcp --connect`: every test builds a fake machine in a temp folder (fake PATH, fake Homebrew
/// prefix, scratch config) — nothing here reads or writes the user's real Claude configs.
final class ConnectTests: XCTestCase {

    private var tmp: URL!
    private let fsProbe = LocalFileSystem()

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("engram-connect-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
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

    private func env(config: String? = nil, path: String = "/nonexistent") -> HostEnvironment {
        var vars: [String: String] = [:]
        vars["ENGRAM_CLAUDE_CONFIG"] = config ?? tmp.appendingPathComponent("claude_desktop_config.json").path
        return HostEnvironment(home: URL(fileURLWithPath: home), cwd: tmp.path, pathEnv: path,
                               variables: vars, memoriesRoot: tmp.appendingPathComponent("engram/memories"))
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
        let report = Connector(env: env(config: config)).run(argv0: "./not-there/engram-mcp")
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

        let report = Connector(env: env(config: config.path)).run(argv0: binary)
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

        let report = Connector(env: e, now: { at }).run(argv0: binary)
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
        let report = Connector(env: env(config: config.path)).run(argv0: binary)
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

        let report = Connector(env: env(config: config)).run(argv0: binary)
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
}
