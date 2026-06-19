import Foundation

// Claude Code auto-capture. Unlike Claude Desktop (where the model must call the remember tool),
// Claude Code writes every session to disk as JSONL transcripts at ~/.claude/projects/<proj>/<id>.jsonl.
// We read those files directly — no waiting on the model — distill the user's durable statements, and
// store them as memories tagged source = "claude-code". This is the "real automatic" capture path.
//
// Real schema (verified): each line has a "type"; user lines carry message.content as a String,
// assistant lines carry message.content as a list of {type:"text"|"thinking", ...}. We only distill
// USER messages — that's where durable facts/preferences actually come from.

public struct TranscriptMessage {
    public let role: String       // "user" | "assistant"
    public let text: String
    public let sessionID: String
}

public enum ClaudeCodeTranscript {
    public static func parse(fileAt url: URL) -> [TranscriptMessage] {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var out: [TranscriptMessage] = []
        for line in raw.split(separator: "\n") {
            guard let d = line.data(using: .utf8),
                  let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { continue }
            let type = o["type"] as? String ?? ""
            guard type == "user" || type == "assistant" else { continue }
            let sessionID = (o["sessionId"] as? String) ?? url.deletingPathExtension().lastPathComponent
            guard let msg = o["message"] as? [String: Any] else { continue }
            let role = (msg["role"] as? String) ?? type
            let text = extractText(msg["content"])
            if !text.isEmpty {
                out.append(TranscriptMessage(role: role, text: text, sessionID: sessionID))
            }
        }
        return out
    }

    static func extractText(_ content: Any?) -> String {
        if let s = content as? String { return s }
        if let arr = content as? [[String: Any]] {
            return arr.compactMap { ($0["type"] as? String) == "text" ? $0["text"] as? String : nil }
                .joined(separator: "\n")
        }
        return ""
    }
}

/// Decides which of a conversation's user statements are worth remembering.
public protocol Distiller {
    func distill(userMessages: [String]) -> [String]
}

/// No-LLM, no-network default: captures user messages that explicitly state durable facts/preferences
/// via a conservative cue list. Rough but honest and free — the quality upgrade is an LLM distiller
/// (e.g. local Ollama) behind this same protocol. Conservative on purpose: better to miss than to
/// flood the store with transient chatter.
public struct HeuristicDistiller: Distiller {
    public init() {}
    static let cues = [
        // English
        "remember that", "note that", "for future reference", "keep in mind", "fyi",
        "i prefer", "i like", "i don't like", "i hate", "my favorite", "i always", "i never",
        "my name is", "call me", "i'm working on", "i am working on", "i use ", "i'm using",
        "my goal is", "my email is", "i live in", "i work at", "we decided", "i decided",
        // Turkish
        "hatırla", "unutma", "not al", "aklında olsun", "tercih", "her zaman", "asla ",
        "seviyorum", "sevmiyorum", "sevmem", "çalışıyorum", "hedefim", "favori",
        "karar verdik", "karar verdim", "kullanıyorum", "ismim", "benim adım", "adım ",
        "yaşıyorum", "oturuyorum", "doğdum", "mezunum", "öğrenciyim", "amacım", "nefret ediyorum",
    ]
    public func distill(userMessages: [String]) -> [String] {
        var out: [String] = []
        for m in userMessages {
            let lower = m.lowercased()
            guard Self.cues.contains(where: { lower.contains($0) }) else { continue }
            let cleaned = m.trimmingCharacters(in: .whitespacesAndNewlines)
            guard cleaned.count >= 6, cleaned.count <= 500 else { continue }
            out.append(cleaned)
        }
        return out
    }
}

/// The real, language-agnostic distiller: hands the conversation to a LOCAL Ollama model and asks it
/// to extract durable facts (works for Turkish, English, anything). Opt-in (`engram-capture --ollama`)
/// because it needs Ollama running; the call stays on localhost. This is the quality path the
/// heuristic only approximates.
public struct OllamaDistiller: Distiller {
    let model: String
    let host: String
    public init(model: String = "llama3.2", host: String = "http://127.0.0.1:11434") {
        self.model = model
        self.host = host
    }

    public func distill(userMessages: [String]) -> [String] {
        guard !userMessages.isEmpty, let url = URL(string: host + "/api/generate") else { return [] }
        let prompt = """
        From the user's messages below, extract ONLY durable facts, preferences, decisions, or project \
        details worth remembering long-term. Ignore transient chit-chat and one-off task requests. \
        Reply with a JSON array of short self-contained sentences in the user's own language. \
        If nothing is worth remembering, reply [].

        MESSAGES:
        \(userMessages.joined(separator: "\n"))
        """
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": model, "prompt": prompt, "stream": false, "format": "json",
        ])
        req.timeoutInterval = 90   // local generation can be slow; fail (→ heuristic) rather than hang forever

        var facts: [String] = []
        var reached = false
        let sem = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: req) { data, _, _ in
            defer { sem.signal() }
            guard let data,
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let resp = obj["response"] as? String,
                  let rd = resp.data(using: .utf8) else { return }
            reached = true   // Ollama answered and we parsed its response
            if let arr = (try? JSONSerialization.jsonObject(with: rd)) as? [String] {
                facts = arr
            } else if let dict = (try? JSONSerialization.jsonObject(with: rd)) as? [String: Any],
                      let arr = dict.values.first(where: { $0 is [Any] }) as? [String] {
                facts = arr   // some models wrap it like {"facts":[...]}
            }
        }
        task.resume()
        // Hard ceiling on the wait — a connection that stalls mid-stream must not hang the watcher forever.
        if sem.wait(timeout: .now() + 95) == .timedOut {
            task.cancel()
            return HeuristicDistiller().distill(userMessages: userMessages)
        }
        let cleaned = facts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { $0.count >= 6 && $0.count <= 500 }
        // Fall back to the heuristic ONLY when Ollama wasn't reached. If it WAS reached and chose to keep
        // nothing ([]), honor that decision rather than second-guessing it with the heuristic.
        return reached ? cleaned : HeuristicDistiller().distill(userMessages: userMessages)
    }
}

public struct ClaudeCodeImporter {
    let engine: MemoryEngine
    let distiller: Distiller

    public init(engine: MemoryEngine, distiller: Distiller = HeuristicDistiller()) {
        self.engine = engine
        self.distiller = distiller
    }

    /// Import one transcript file. Idempotent: skips memories whose exact content is already stored
    /// for that conversation, so re-running (or polling) never duplicates.
    @discardableResult
    public func importFile(at url: URL) throws -> Int {
        let messages = ClaudeCodeTranscript.parse(fileAt: url)
        guard !messages.isEmpty else { return 0 }
        let conversation = messages.first?.sessionID ?? url.deletingPathExtension().lastPathComponent
        let userMsgs = messages.filter { $0.role == "user" }.map { $0.text }
        let candidates = distiller.distill(userMessages: userMsgs).map(Self.sanitize)
        let active = Set(engine.store.memories(in: conversation).filter { !$0.deleted }.map { $0.content })
        var added = 0, revived = false
        for c in candidates where !c.isEmpty && !active.contains(c) {
            if engine.store.restoreDeleted(content: c, in: conversation) != nil {   // revive a tombstone, don't duplicate
                revived = true
            } else {
                try engine.remember(c, tags: ["auto", "claude-code"], source: "claude-code", conversation: conversation)
            }
            added += 1
        }
        if revived { engine.index.rebuild(from: engine.store.allMemories()) }
        return added
    }

    /// Strip control / non-printable characters from auto-captured text (untrusted user content that
    /// later feeds an AI via recall) — keep \n and \t, drop the rest. It's already tagged "auto" so a
    /// consumer can treat it as lower-trust.
    static func sanitize(_ s: String) -> String {
        let kept = s.unicodeScalars.filter { $0 == "\n" || $0 == "\t" || !CharacterSet.controlCharacters.contains($0) }
        return String(String.UnicodeScalarView(kept)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    public func importAll(transcriptsRoot: URL) throws -> Int {
        guard let walker = FileManager.default.enumerator(at: transcriptsRoot, includingPropertiesForKeys: nil) else { return 0 }
        var total = 0
        for case let f as URL in walker where f.pathExtension == "jsonl" {
            total += (try? importFile(at: f)) ?? 0
        }
        return total
    }
}
