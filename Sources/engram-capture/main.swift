import Foundation
import Engram

// engram-capture — scans Claude Code's on-disk transcripts and auto-imports the user's durable
// statements into the local memory store (source = "claude-code"). One-shot by default; `--watch`
// polls every 15s. No network: uses the HeuristicDistiller (an LLM distiller is a future opt-in).
//
//   engram-capture            # import once
//   engram-capture --watch    # keep importing as you work
//
// Env overrides (for testing): ENGRAM_ROOT, ENGRAM_CC_TRANSCRIPTS.

func err(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

let env = ProcessInfo.processInfo.environment

let root: URL = CombinedFileStore.defaultMemoriesRoot()   // one shared definition (honors ENGRAM_ROOT)

let transcripts: URL = env["ENGRAM_CC_TRANSCRIPTS"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects", isDirectory: true)

do {
    let engine = try MemoryEngine(root: root, embedder: NLContextualEmbeddingProvider())
    // Default = heuristic (no network). --ollama = real language-agnostic LLM distiller (needs Ollama).
    let distiller: Distiller
    if CommandLine.arguments.contains("--ollama") {
        let model = env["ENGRAM_OLLAMA_MODEL"] ?? "llama3.2"
        distiller = OllamaDistiller(model: model)
        err("engram-capture: using Ollama distiller (model \(model)) — needs Ollama running")
    } else {
        distiller = HeuristicDistiller()
    }
    let importer = ClaudeCodeImporter(engine: engine, distiller: distiller)

    func runOnce() {
        let start = Date()
        let n = (try? importer.importAll(transcriptsRoot: transcripts)) ?? 0
        let secs = Date().timeIntervalSince(start)
        err("engram-capture: imported \(n) new memories in \(String(format: "%.1f", secs))s  ·  store = \(root.path)")
        if secs > 15 {   // a scan slower than the poll interval means cycles back up — surface it (distiller is time-bounded)
            err("engram-capture: warning — last scan took \(String(format: "%.0f", secs))s, longer than the 15s poll interval")
        }
    }

    runOnce()
    if CommandLine.arguments.contains("--watch") {
        err("engram-capture: watching \(transcripts.path) (poll 15s) — Ctrl+C to stop")
        while true {
            Thread.sleep(forTimeInterval: 15)
            runOnce()
        }
    }
} catch {
    err("engram-capture: FATAL \(error)")
    exit(1)
}
