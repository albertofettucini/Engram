import Foundation
import SwiftUI
import AppKit
import Engram

// `CombinedFile` now lives in the Engram library (CombinedFileStore.swift) so the MCP server can read the
// same files and recall WITHIN one (scope "file"). The app just creates/edits them here.

/// View model bridging SwiftUI to the Engram engine. Reads the same on-disk store the MCP server
/// and capture tool write to, so the menubar app shows live memory.
@MainActor
final class AppModel: ObservableObject {
    @Published var memories: [Memory] = []        // all non-deleted, newest first
    @Published var sources: [String] = []          // which AIs have written memories
    @Published var sourceFilter: String? = nil     // nil = all AIs
    @Published var keyword: String = ""            // browse keyword filter
    @Published var recallQuery: String = ""        // collective-mind semantic query
    @Published var recallResults: [RecallHit] = []
    @Published var storePath: String = ""          // shown in the UI ("your data is right here")
    @Published var combinedFiles: [CombinedFile] = []   // the user's named woven files (zero, one, or many)
    @Published var customSources: [CustomSource] = []   // AIs the user added beyond the built-in six

    private var engine: MemoryEngine?

    init() {
        combinedFiles = CombinedFileStore.load(memoriesRoot: storeRoot())
        migrateCombinedFilesIfNeeded()
        customSources = (UserDefaults.standard.data(forKey: "engram.customSources")
            .flatMap { try? JSONDecoder().decode([CustomSource].self, from: $0) }) ?? []
        reload()
    }

    // MARK: Custom AI sources (user-added, beyond the built-in six)

    private func persistCustomSources() {
        if let d = try? JSONEncoder().encode(customSources) { UserDefaults.standard.set(d, forKey: "engram.customSources") }
    }

    /// Add an AI the user named themselves (e.g. "Mistral", "Perplexity"). Returns the source key to tag
    /// memories with. No-ops to the existing key if it already exists (built-in or custom).
    @discardableResult
    func addCustomSource(name: String) -> String? {
        let display = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !display.isEmpty else { return nil }
        let key = display.lowercased()
        if Self.circles.contains(where: { $0.id == key || $0.sources.contains(key) }) { return key }   // already a built-in
        if let existing = customSources.first(where: { $0.id == key }) { return existing.id }
        customSources.append(CustomSource(id: key, name: display, colorIndex: customSources.count))
        persistCustomSources()
        return key
    }
    func removeCustomSource(_ id: String) {
        customSources.removeAll { $0.id == id }
        persistCustomSources()
    }

    /// Built-in AIs + the user's custom ones — what the sidebar and colour lookups iterate.
    var allCircles: [AICircle] {
        Self.circles + customSources.map {
            AICircle(id: $0.id, name: $0.name, sources: [$0.id], x: 0, y: 0,
                     color: Self.customPalette[$0.colorIndex % Self.customPalette.count])
        }
    }

    // MARK: Combined files (the "Collective Mind" is now a set of these — stored in the SHARED json so the
    // MCP can recall within one).

    @discardableResult
    private func persistCombinedFiles() -> Bool {
        CombinedFileStore.save(combinedFiles, memoriesRoot: storeRoot())
    }

    /// One-time bridges to the shared json store, so nobody loses what they wove:
    ///  (a) an earlier build kept the files in UserDefaults — move them into the json;
    ///  (b) an even earlier build kept a single Collective Mind set — fold it into one file.
    /// Each legacy key is dropped ONLY after a confirmed write, so a failed save (disk full / sandbox /
    /// encode error) never wipes the backup — migration just retries next launch.
    private func migrateCombinedFilesIfNeeded() {
        // (a) UserDefaults files → json
        if combinedFiles.isEmpty,
           let data = UserDefaults.standard.data(forKey: "engram.combinedFiles"),
           let udFiles = try? JSONDecoder().decode([CombinedFile].self, from: data), !udFiles.isEmpty {
            combinedFiles = udFiles
            if persistCombinedFiles() { UserDefaults.standard.removeObject(forKey: "engram.combinedFiles") }
        } else {
            UserDefaults.standard.removeObject(forKey: "engram.combinedFiles")   // nothing to migrate (already empty)
        }
        // (b) legacy single Collective Mind set → one file
        if !UserDefaults.standard.bool(forKey: "engram.collectiveMigrated") {
            let legacy = Set(UserDefaults.standard.stringArray(forKey: "engram.collective") ?? [])
            var ok = true
            if combinedFiles.isEmpty && !legacy.isEmpty {
                let name = UserDefaults.standard.string(forKey: "engram.collectiveName") ?? "Collective Mind"
                combinedFiles = [CombinedFile(id: UUID().uuidString, name: name, conversations: legacy)]
                ok = persistCombinedFiles()
            }
            if ok {   // only burn the bridge once the data is safely on disk
                UserDefaults.standard.set(true, forKey: "engram.collectiveMigrated")
                UserDefaults.standard.removeObject(forKey: "engram.collective")
                UserDefaults.standard.removeObject(forKey: "engram.collectiveName")
            }
        }
    }

    /// Make a name unique against existing files (case-insensitive), so two files can't share a name and
    /// make the MCP's "file" scope ambiguous. "Work" → "Work 2" → "Work 3" …
    private func uniqueName(_ desired: String) -> String {
        let base = desired.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled" : desired.trimmingCharacters(in: .whitespacesAndNewlines)
        func taken(_ n: String) -> Bool { combinedFiles.contains { $0.name.lowercased() == n.lowercased() } }
        if !taken(base) { return base }
        var i = 2
        while taken("\(base) \(i)") { i += 1 }
        return "\(base) \(i)"
    }

    func combinedFile(_ id: String) -> CombinedFile? { combinedFiles.first { $0.id == id } }

    /// Merge several combined files into ONE: the new file holds the union of their conversations, and the
    /// originals fold away. Non-destructive — only the file groupings change, no memories are touched.
    @discardableResult
    func combineFiles(_ ids: [String], name: String) -> CombinedFile {
        let union = ids.compactMap { combinedFile($0) }.reduce(into: Set<String>()) { $0.formUnion($1.conversations) }
        combinedFiles.removeAll { ids.contains($0.id) }
        let file = CombinedFile(id: UUID().uuidString, name: uniqueName(name), conversations: union)
        combinedFiles.append(file)
        persistCombinedFiles()
        return file
    }

    @discardableResult
    func createCombinedFile(name: String, conversations: Set<String>) -> CombinedFile {
        let file = CombinedFile(id: UUID().uuidString, name: uniqueName(name), conversations: conversations)
        combinedFiles.append(file)
        persistCombinedFiles()
        return file
    }
    func renameCombinedFile(_ id: String, to name: String) {
        guard let i = combinedFiles.firstIndex(where: { $0.id == id }) else { return }
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }            // ignore empties so a half-cleared field never wipes the name
        combinedFiles[i].name = t
        persistCombinedFiles()
    }
    /// Replace a file's whole membership (used by the edit sheet).
    func setMembers(_ id: String, conversations: Set<String>) {
        guard let i = combinedFiles.firstIndex(where: { $0.id == id }) else { return }
        combinedFiles[i].conversations = conversations
        persistCombinedFiles()
    }
    func removeFromCombinedFile(_ id: String, conversations: [String]) {
        guard let i = combinedFiles.firstIndex(where: { $0.id == id }) else { return }
        for c in conversations { combinedFiles[i].conversations.remove(c) }
        persistCombinedFiles()
    }
    func deleteCombinedFile(_ id: String) {
        combinedFiles.removeAll { $0.id == id }     // only drops the file; the conversations/memories stay
        persistCombinedFiles()
    }
    func memories(inCombinedFile id: String) -> [Memory] {
        guard let f = combinedFiles.first(where: { $0.id == id }) else { return [] }
        return memories.filter { f.conversations.contains($0.conversationID) }
    }

    /// When a whole conversation is forgotten, drop it from every combined file that referenced it.
    private func pruneConversationsFromFiles(_ ids: [String]) {
        var changed = false
        for i in combinedFiles.indices {
            for id in ids where combinedFiles[i].conversations.contains(id) {
                combinedFiles[i].conversations.remove(id); changed = true
            }
        }
        if changed { persistCombinedFiles() }
    }

    // One shared root definition (honors ENGRAM_ROOT) — the SAME path the MCP + capture use, so the app
    // and the MCP always read/write the SAME combined-files.json.
    private func storeRoot() -> URL { CombinedFileStore.defaultMemoriesRoot() }

    func reload() {
        let root = storeRoot()
        storePath = root.path
        // Build the engine + embed the whole store OFF the main actor (it can be hundreds of memories),
        // then publish results back on the main actor — so launch and every mutation don't freeze the UI.
        Task { @MainActor in
            let loaded = await Self.load(root: root)
            self.engine = loaded.engine
            self.memories = loaded.memories
            self.sources = loaded.sources
        }
    }

    /// Conversations a file points at that have no live memory right now (e.g. a chat forgotten by the MCP
    /// side, OR simply not yet loaded). Used for DISPLAY only — we never persist a pruned membership here,
    /// because a partial/slow store read could otherwise permanently delete valid ids. Real whole-chat
    /// deletes prune persistently through `pruneConversationsFromFiles` instead.
    func liveConversationCount(_ f: CombinedFile) -> Int {
        let live = Set(memories.map { $0.conversationID })
        return f.conversations.intersection(live).count
    }

    private nonisolated static func load(root: URL) async -> (engine: MemoryEngine?, memories: [Memory], sources: [String]) {
        await Task.detached(priority: .userInitiated) {
            guard let e = try? MemoryEngine(root: root, embedder: NLContextualEmbeddingProvider()) else {
                return (nil, [], [])
            }
            let all = e.store.allMemories().filter { !$0.deleted }.sorted { $0.updatedAt > $1.updatedAt }
            return (e, all, Array(Set(all.map { $0.source })).sorted())
        }.value
    }

    var filtered: [Memory] {
        memories.filter { m in
            (sourceFilter == nil || m.source == sourceFilter) &&
            (keyword.isEmpty || m.content.localizedCaseInsensitiveContains(keyword))
        }
    }

    func groupedByConversation(_ mems: [Memory]) -> [(conversation: String, items: [Memory])] {
        let groups = Dictionary(grouping: mems, by: { $0.conversationID })
        return groups.keys.sorted().map { (conversation: $0, items: groups[$0] ?? []) }
    }

    // Deletes update the store + index + the published list DIRECTLY — no reload(), so they're instant.
    // (reload() re-embeds the whole store, which froze the UI and left the deleted item on screen for
    // seconds. The index drops entries cheaply with no re-embedding.)

    func delete(_ m: Memory) {
        guard let e = engine else { return }
        try? e.forget(m.id)   // soft-deletes in the store AND drops it from the index (cheap, no re-embed)
        memories.removeAll { $0.id == m.id }
        sources = Array(Set(memories.map { $0.source })).sorted()
    }

    /// Re-read the published list from the on-disk store (file reads only, NO re-embedding). Use after an
    /// import/paste, where the new memories are already embedded into the index by the importer.
    private func refreshFromStore() {
        guard let e = engine else { return }
        let all = e.store.allMemories().filter { !$0.deleted }.sorted { $0.updatedAt > $1.updatedAt }
        memories = all
        sources = Array(Set(all.map { $0.source })).sorted()
    }

    /// Forget an ENTIRE conversation — remove its file outright (so the same content can be re-imported
    /// later instead of being blocked by leftover deleted tombstones).
    func deleteConversation(_ conversationID: String) {
        guard let e = engine else { return }
        try? e.store.deleteConversationFile(conversationID)
        e.index.removeConversation(conversationID)
        pruneConversationsFromFiles([conversationID])
        memories.removeAll { $0.conversationID == conversationID }
        sources = Array(Set(memories.map { $0.source })).sorted()
    }

    /// Bulk: forget several whole conversations at once — all instant, one published update.
    func deleteConversations(_ conversationIDs: [String]) {
        guard let e = engine else { return }
        let set = Set(conversationIDs)
        for c in conversationIDs {
            try? e.store.deleteConversationFile(c)
            e.index.removeConversation(c)
        }
        pruneConversationsFromFiles(conversationIDs)
        memories.removeAll { set.contains($0.conversationID) }
        sources = Array(Set(memories.map { $0.source })).sorted()
    }

    /// Which AI a manual import/paste is from — the six built-ins, plus any custom AIs the user added,
    /// plus the generic catch-all. Shared by the file picker and the paste sheet.
    var importSourceChoices: [(title: String, source: String)] {
        let builtins: [(title: String, source: String)] = [
            ("Claude", "claude"), ("ChatGPT", "chatgpt"), ("Gemini", "gemini"),
            ("Grok", "grok"), ("DeepSeek", "deepseek"), ("Ollama", "ollama"),
        ]
        let customs = customSources.map { (title: $0.name, source: $0.id) }
        return builtins + customs + [("Other / generic notes", "import")]
    }

    /// Paste a conversation/notes directly (no file) → memories, tagged with the chosen AI.
    @discardableResult
    func importPastedText(_ text: String, source: String, title: String, distill: Bool = false) -> Int {
        guard let engine else { return 0 }
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let conversation = t.isEmpty ? "Pasted notes" : t
        let n = (try? MarkdownImporter(engine: engine).importText(text, source: source, conversation: conversation, distill: distill)) ?? 0
        refreshFromStore()   // new memories are already indexed — just refresh the list, no re-embed
        return n
    }

    /// "Import" — pick a folder (or file) of .md/.txt notes and pull them into memory.
    func importMarkdown() {
        guard let engine else { return }

        // The "which AI is this from?" picker lives INSIDE the open panel (its accessory view), so it's
        // one dialog — no flaky second modal that macOS sometimes fails to show.
        let choices = importSourceChoices
        let label = NSTextField(labelWithString: "Import as:")
        label.frame = NSRect(x: 12, y: 44, width: 78, height: 18)
        let popup = NSPopUpButton(frame: NSRect(x: 92, y: 40, width: 240, height: 26))
        popup.addItems(withTitles: choices.map(\.title))
        // "Keep" = how much to pull in: everything, or only durable facts (distilled).
        let modeLabel = NSTextField(labelWithString: "Keep:")
        modeLabel.frame = NSRect(x: 12, y: 12, width: 78, height: 18)
        let modePopup = NSPopUpButton(frame: NSRect(x: 92, y: 8, width: 240, height: 26))
        modePopup.addItems(withTitles: ["Key facts only", "Everything"])   // Key facts = default (first item)
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 78))
        accessory.addSubview(label); accessory.addSubview(popup)
        accessory.addSubview(modeLabel); accessory.addSubview(modePopup)

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        panel.message = "Choose a .md / .txt / .json file (or folder) — and pick which AI it's from below."
        panel.accessoryView = accessory
        if #available(macOS 11.0, *) { panel.isAccessoryViewDisclosed = true }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let source = choices[max(0, popup.indexOfSelectedItem)].source
        let distill = modePopup.indexOfSelectedItem == 0   // "Key facts only" (default)

        let importer = MarkdownImporter(engine: engine)
        if url.hasDirectoryPath {
            _ = try? importer.importFolder(at: url, source: source, distill: distill)
        } else {
            _ = try? importer.importFile(at: url, source: source, distill: distill)
        }
        refreshFromStore()   // imported memories are already indexed — refresh the list, no re-embed
    }

    enum ExportFormat { case markdown, json }

    /// Save the given memories to one file the user picks (Markdown or JSON).
    func export(_ mems: [Memory], as format: ExportFormat, suggestedName: String) {
        let ext = format == .markdown ? "md" : "json"
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(suggestedName).\(ext)"
        panel.message = "Export \(mems.count) memories as .\(ext)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = format == .markdown ? Exporter.markdown(from: mems) : Exporter.json(from: mems)
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    func runRecall() {
        guard let engine, !recallQuery.trimmingCharacters(in: .whitespaces).isEmpty else {
            recallResults = []
            return
        }
        recallResults = engine.recall(recallQuery, scope: .all, k: 10)
    }
}

// MARK: - Constellation model

/// One AI brand in the orbit. `sources` are the memory-source ids that fill this circle: Claude fills
/// automatically (MCP / Code capture); the rest fill via Import. `x`/`y` are 0…1 canvas positions.
struct AICircle: Identifiable, Hashable {
    let id: String
    let name: String
    let sources: [String]
    let x: Double
    let y: Double
    let color: Color   // the circle's own tint (glass still refracts the desktop behind it)
}

/// An AI the user added themselves (not one of the built-in six). `id` is the source key memories are
/// tagged with (the lowercased name); `colorIndex` picks a tint from `AppModel.customPalette`.
struct CustomSource: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var colorIndex: Int
}

extension AppModel {
    static let circles: [AICircle] = [
        .init(id: "claude",   name: "Claude",   sources: ["claude-code", "claude-desktop", "manual", "claude"], x: 0.80, y: 0.22, color: Color(red: 0.85, green: 0.49, blue: 0.30)),
        .init(id: "deepseek", name: "DeepSeek", sources: ["deepseek"], x: 0.50, y: 0.12, color: Color(red: 0.36, green: 0.40, blue: 0.88)),
        .init(id: "gemini",   name: "Gemini",   sources: ["gemini"],   x: 0.22, y: 0.20, color: Color(red: 0.30, green: 0.55, blue: 0.95)),
        .init(id: "grok",     name: "Grok",     sources: ["grok"],     x: 0.24, y: 0.74, color: Color(red: 0.40, green: 0.42, blue: 0.48)),
        .init(id: "chatgpt",  name: "ChatGPT",  sources: ["chatgpt"],  x: 0.78, y: 0.72, color: Color(red: 0.10, green: 0.66, blue: 0.55)),
        .init(id: "ollama",   name: "Ollama",   sources: ["ollama"],   x: 0.52, y: 0.86, color: Color(red: 0.56, green: 0.56, blue: 0.62)),
    ]

    /// Tints for user-added AIs, picked round-robin so multiple customs stay distinguishable.
    static let customPalette: [Color] = [
        Color(red: 0.78, green: 0.45, blue: 0.85),   // violet
        Color(red: 0.95, green: 0.58, blue: 0.25),   // amber
        Color(red: 0.20, green: 0.70, blue: 0.72),   // teal
        Color(red: 0.90, green: 0.38, blue: 0.52),   // rose
        Color(red: 0.46, green: 0.72, blue: 0.38),   // green
        Color(red: 0.58, green: 0.56, blue: 0.92),   // periwinkle
    ]

    func memories(forCircle c: AICircle) -> [Memory] {
        memories.filter { c.sources.contains($0.source) }
    }
    func hasData(_ c: AICircle) -> Bool { !memories(forCircle: c).isEmpty }

    /// Every conversation in the store, with its source + memory count + most-recent timestamp, sorted
    /// newest-first. The combined-file picker filters this by source and shows it in recency order.
    func allConversations() -> [(id: String, source: String, count: Int, updated: Date)] {
        let groups = Dictionary(grouping: memories, by: { $0.conversationID })
        return groups.map { (id, mems) in
            (id, mems.first?.source ?? "", mems.count, mems.map { $0.updatedAt }.max() ?? .distantPast)
        }.sorted { $0.updated > $1.updated }
    }
}
