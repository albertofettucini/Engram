import XCTest
@testable import Engram

/// `engram-mcp --doctor` against fixture configs, records and logs in a temp folder — never the real
/// machine's Claude configs.
final class DoctorTests: XCTestCase {

    private var tmp: URL!
    private var lockedFolders: [URL] = []

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("engram-doctor-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for url in lockedFolders { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: fixture machine

    private var home: URL { tmp.appendingPathComponent("home") }
    private var memories: URL { tmp.appendingPathComponent("engram/memories") }
    private var desktopConfig: URL { tmp.appendingPathComponent("claude/claude_desktop_config.json") }
    private var codeConfig: URL { tmp.appendingPathComponent("claude/claude.json") }
    private var logs: URL { tmp.appendingPathComponent("claude/logs") }
    private var bin: String { tmp.appendingPathComponent("bin").path }
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// `desktopInstalled` = Claude Desktop's support folder exists under the fixture HOME.
    private func env(desktopInstalled: Bool = true) throws -> HostEnvironment {
        if desktopInstalled {
            try FileManager.default.createDirectory(at: home.appendingPathComponent("Library/Application Support/Claude"),
                                                    withIntermediateDirectories: true)
        }
        return HostEnvironment(home: home, cwd: tmp.path, pathEnv: bin,
                               variables: ["ENGRAM_CLAUDE_CODE_CONFIG": codeConfig.path,
                                           "ENGRAM_CLAUDE_LOGS": logs.path],
                               memoriesRoot: memories,
                               applicationsDirs: [tmp.appendingPathComponent("Applications").path])
    }

    private var defaultDesktopConfig: URL { home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json") }

    @discardableResult
    private func makeExecutable(_ relative: String) throws -> String {
        let url = tmp.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 0\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    private func write(_ json: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try json.write(to: url, atomically: true, encoding: .utf8)
    }

    private func doctor(_ e: HostEnvironment, embeddings: Bool = true) -> Doctor {
        Doctor(env: e, now: { self.now }, embeddingsAvailable: { embeddings })
    }

    private func check(_ checks: [DoctorCheck], _ area: String) -> DoctorCheck? {
        checks.first { $0.area == area }
    }

    /// Every file under the fixture with its size and mtime — to prove the doctor wrote nothing.
    private func snapshot() -> [String: String] {
        var out: [String: String] = [:]
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        let walker = FileManager.default.enumerator(at: tmp, includingPropertiesForKeys: keys)
        while let url = walker?.nextObject() as? URL {
            let v = try? url.resourceValues(forKeys: Set(keys))
            out[url.path] = "\(v?.fileSize ?? -1)@\(v?.contentModificationDate?.timeIntervalSince1970 ?? -1)"
        }
        return out
    }

    // MARK: tests

    func testHealthySetup() throws {
        let binary = try makeExecutable("bin/engram-mcp")
        try makeExecutable("bin/claude")
        let e = try env()
        try write(#"{"mcpServers":{"engram":{"command":"\#(binary)"}},"preferences":{"x":1}}"#, to: defaultDesktopConfig)
        try write(#"{"mcpServers":{"engram":{"type":"stdio","command":"\#(binary)","args":[]}}}"#, to: codeConfig)
        let engine = try MemoryEngine(root: memories)
        try engine.remember("Prefers tabs.", source: "claude-code", conversation: "claude-code")
        try engine.remember("Works on a bakery app.", source: "claude-code", conversation: "claude-code")
        try engine.remember("Lives in Lisbon.", source: "claude-desktop", conversation: "claude-desktop")
        for f in try FileManager.default.contentsOfDirectory(atPath: memories.path) {
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-2 * 3600)],
                                                  ofItemAtPath: memories.appendingPathComponent(f).path)
        }

        let before = snapshot()
        let checks = doctor(e).run()
        XCTAssertEqual(snapshot(), before, "the doctor must never write anything")
        XCTAssertEqual(Doctor.render(checks, version: "0.1.1"), """
        Engram doctor (0.1.1)
          ✓ Claude Desktop   connected → \(binary)
          ✓ Claude Code      connected (user scope) → \(binary)
          ✓ Memory store     2 files, 3 memories, last change 2 hours ago · \(memories.path)
          ✓ Embeddings       on-device transformer model

        All good.
        """)
        XCTAssertEqual(Doctor.exitCode(checks), 0)
    }

    /// Connected before (a record) but the entry is gone now: a problem, worded as a possibility.
    func testDroppedDesktopEntryFromRecord() throws {
        let e = try env()
        try write(#"{"mcpServers":{"other":{"command":"/x"}},"preferences":{}}"#, to: defaultDesktopConfig)
        ConnectionStore.save(ConnectionRecord(client: "claude-desktop", command: "/opt/homebrew/bin/engram-mcp", connectedAt: now),
                             memoriesRoot: memories)

        let c = try XCTUnwrap(check(doctor(e).run(), Doctor.desktopArea))
        XCTAssertEqual(c.line, "  ✗ Claude Desktop   Engram was connected before but is missing from Claude Desktop's config now. Claude Desktop may have dropped it during an update. Fix: engram-mcp --connect claude-desktop")
    }

    func testDroppedDesktopEntryFromLogOnly() throws {
        let e = try env()
        try write(#"{"preferences":{}}"#, to: defaultDesktopConfig)
        try write("2026-10-01 [engram] [info] Server started\n", to: logs.appendingPathComponent("mcp-server-engram.log"))
        XCTAssertEqual(check(doctor(e).run(), Doctor.desktopArea)?.status, .fail)
    }

    func testNeverConnectedDesktopIsAWarning() throws {
        let e = try env()
        try write(#"{"preferences":{}}"#, to: defaultDesktopConfig)
        XCTAssertEqual(check(doctor(e).run(), Doctor.desktopArea)?.line,
                       "  ! Claude Desktop   not connected. Fix: engram-mcp --connect claude-desktop")
    }

    func testCommandThatDoesNotExist() throws {
        let e = try env()
        try write(#"{"mcpServers":{"engram":{"command":"/nowhere/engram-mcp"}}}"#, to: defaultDesktopConfig)
        let checks = doctor(e).run()
        XCTAssertEqual(check(checks, Doctor.desktopArea)?.line,
                       "  ✗ Claude Desktop   points at /nowhere/engram-mcp, which doesn't exist. Fix: engram-mcp --connect claude-desktop")
        XCTAssertEqual(Doctor.exitCode(checks), 1)
        XCTAssertTrue(Doctor.render(checks).hasSuffix("\n\n1 problem found."))
    }

    func testCellarPathIsAWarning() throws {
        let cellar = try makeExecutable("brew/Cellar/engram/0.1.0/bin/engram-mcp")
        let e = try env()
        try write(#"{"mcpServers":{"engram":{"command":"\#(cellar)"}}}"#, to: defaultDesktopConfig)
        let checks = doctor(e).run()
        XCTAssertEqual(check(checks, Doctor.desktopArea)?.line,
                       "  ! Claude Desktop   points at \(cellar), which can move or be deleted by brew upgrade. Fix: engram-mcp --connect claude-desktop")
        XCTAssertEqual(Doctor.exitCode(checks), 0)   // a warning, not a problem
    }

    func testNothingInstalled() throws {
        let e = try env(desktopInstalled: false)
        let checks = doctor(e, embeddings: false).run()
        XCTAssertEqual(Doctor.render(checks, version: "0.1.1"), """
        Engram doctor (0.1.1)
          – Claude Desktop   not installed
          – Claude Code      not installed
          ✓ Memory store     0 files, 0 memories · \(memories.path)
          ! Embeddings       basic word model (the better on-device model isn't downloaded). Optional: engram-mcp --prepare-embeddings

        All good.
        """)
    }

    func testClaudeCodeWithoutEntryIsAWarning() throws {
        try makeExecutable("bin/claude")
        let e = try env()
        try write(#"{"numStartups":4,"projects":{}}"#, to: codeConfig)
        XCTAssertEqual(check(doctor(e).run(), Doctor.codeArea)?.line,
                       "  ! Claude Code      not connected. Fix: engram-mcp --connect claude-code")
    }

    func testClaudeCodeEntryThatDoesNotExist() throws {
        let e = try env()
        try write(#"{"mcpServers":{"engram":{"type":"stdio","command":"/gone/engram-mcp","args":[]}}}"#, to: codeConfig)
        XCTAssertEqual(check(doctor(e).run(), Doctor.codeArea)?.line,
                       "  ✗ Claude Code      points at /gone/engram-mcp, which doesn't exist. Fix: engram-mcp --connect claude-code")
    }

    func testUnreadableStore() throws {
        let e = try env()
        try FileManager.default.createDirectory(at: memories, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: memories.path)
        lockedFolders.append(memories)

        let checks = doctor(e).run()
        XCTAssertEqual(check(checks, Doctor.storeArea)?.line,
                       "  ✗ Memory store     can't read \(memories.path): Permission denied")
        XCTAssertEqual(Doctor.exitCode(checks), 1)
    }

    func testProblemCountWording() {
        let fail = DoctorCheck(.fail, "Memory store", "x")
        let warn = DoctorCheck(.warn, "Embeddings", "y")
        XCTAssertTrue(Doctor.render([warn]).hasSuffix("\n\nAll good."))
        XCTAssertTrue(Doctor.render([fail, warn]).hasSuffix("\n\n1 problem found."))
        XCTAssertTrue(Doctor.render([fail, fail]).hasSuffix("\n\n2 problems found."))
        XCTAssertTrue(Doctor.render([]).hasPrefix("Engram doctor (\(EngramVersion.current))\n"))
    }

    func testDoctorFlagIsParsed() {
        XCTAssertEqual(EngramCommand.parse(["--doctor"]), .doctor)
    }
}
