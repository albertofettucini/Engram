import SwiftUI
import AppKit
import Engram

/// Restrained, native-feeling hover. No border, no glow, no moving spotlight — those read as flashy and
/// childish. Just a quiet fill that fades in, tinted in the row's own color (a source's color, or the
/// app accent) so it's never a plain gray. The premium feel comes from the glass + typography, not from
/// the hover calling attention to itself.
struct HoverGlass: ViewModifier {
    var corner: CGFloat
    var tint: Color? = nil
    @State private var hovering = false

    func body(content: Content) -> some View {
        let fill = tint ?? Color.accentColor
        content
            .background(fill.opacity(hovering ? 0.10 : 0),
                        in: RoundedRectangle(cornerRadius: corner, style: .continuous))
            // Dock-style magnification: the control gently grows and lifts (soft shadow) under the cursor.
            .scaleEffect(hovering ? 1.035 : 1.0)
            .shadow(color: .black.opacity(hovering ? 0.22 : 0), radius: hovering ? 8 : 0, y: hovering ? 3 : 0)
            .zIndex(hovering ? 1 : 0)   // the magnified one rides above its neighbours
            .onHover { h in withAnimation(.spring(response: 0.28, dampingFraction: 0.72)) { hovering = h } }
    }
}
extension View {
    func hoverGlass(corner: CGFloat = 9, tint: Color? = nil) -> some View { modifier(HoverGlass(corner: corner, tint: tint)) }
}

/// Drives the hosting window's light/dark appearance — glass materials follow the window appearance,
/// not SwiftUI's preferredColorScheme, so this is what actually flips the glass.
struct WindowAppearanceSetter: NSViewRepresentable {
    var light: Bool
    func makeNSView(context: Context) -> NSView { NoDragView() }   // also blocks window-drag everywhere behind content
    func updateNSView(_ nsView: NSView, context: Context) {
        let light = self.light
        DispatchQueue.main.async {
            nsView.window?.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        }
    }
}

/// A full-window background that refuses to move the window — so dragging the padding, the panel gaps,
/// or the (transparent) titlebar strip does nothing. Only the top bar's WindowDragArea moves it.
final class NoDragView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
}

/// A transparent region that drags the (borderless) window when you press-drag inside it. Placed
/// behind the top bar's content, so dragging the bar's empty space moves the window — but nothing
/// else does (no drag from the padding or panel gaps).
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragNSView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
    final class DragNSView: NSView {
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
        override var mouseDownCanMoveWindow: Bool { false }   // we drive the drag explicitly
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
}

// Classic dashboard — a calm, spacious, separated 3-column glass layout (sidebar · memory list ·
// detail), inspired by a clean Mac workspace. Panels are Liquid Glass and reflect whatever desktop
// is behind them; the gaps between panels let the background show through.
struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject private var updater: UpdaterViewModel

    enum Nav: Hashable { case all, collective, source(String) }
    @State private var nav: Nav = .all
    @State private var selected: Memory? = nil      // a single memory shown in the detail panel
    @State private var selectedConv: String? = nil  // a whole conversation shown in the detail panel
    @State private var query: String = ""
    @State private var expanded: Set<String> = []   // which conversations are opened (matryoshka)
    @State private var pendingDelete: String? = nil  // single conversation awaiting delete confirmation
    @State private var selecting = false             // multi-select mode
    @State private var picked: Set<String> = []      // conversations checked in multi-select
    @State private var pendingBulkDelete = false     // bulk delete awaiting confirmation
    @State private var collectiveMerged = true       // open file: one woven view vs its conversations
    @State private var openFile: String? = nil       // id of the combined file being viewed (nil = the hub list)
    @State private var fileNameDraft = ""            // live-edited name of the open file
    @State private var combineSheet: CombineSheetConfig? = nil   // drives the +New / Edit-chats picker sheet
    @State private var namingConversations: Set<String>? = nil   // already-picked chats waiting only for a name
    @State private var newFileName = ""
    @State private var pendingFileDelete: String? = nil
    @State private var selectingFiles = false               // hub: multi-select files to merge/delete
    @State private var pickedFiles: Set<String> = []
    @State private var pendingMerge: Set<String>? = nil     // files awaiting a merge name
    @State private var mergeName = ""
    @State private var pendingFilesDelete: Set<String>? = nil
    @State private var showPaste = false
    @State private var showAddSource = false             // sidebar: name a new custom AI
    @State private var newSourceName = ""
    @State private var showSettings = false
    @State private var hoverControls = false
    @AppStorage("engram.lightMode") private var lightMode = false
    @AppStorage("engram.glassFrost") private var glassFrost = 0.35   // 0 = clear droplet, 1 = frosted
    @AppStorage("engram.matte") private var matte = false            // true = solid/matte panels, glass off

    var body: some View {
        VStack(spacing: 14) {
            topBar
            HStack(spacing: 14) {
                sidebar.frame(width: 210)
                mainPanel.frame(maxWidth: .infinity)
                detailPanel.frame(width: 300)
            }
        }
        .padding(16)
        .preferredColorScheme(lightMode ? .light : .dark)
        .background(WindowAppearanceSetter(light: lightMode))   // flips the GLASS (window appearance), not just text
        .onChange(of: model.memories) { _ in pruneStaleSelection() }
        .onChange(of: collectiveMerged) { merged in if merged { selecting = false; picked = []; selected = nil; selectedConv = nil } }   // woven view → show the file's own details
        .onChange(of: nav) { _ in selecting = false; picked = []; selectingFiles = false; pickedFiles = [] }   // (openFile is reset by the nav row itself)
        .onChange(of: model.combinedFiles) { _ in pruneStaleFileSelection() }   // a conversation removed from the open file shouldn't linger selected
        .onChange(of: fileNameDraft) { v in if let f = openFile { model.renameCombinedFile(f, to: v) } }
        .sheet(item: $combineSheet) { cfg in
            CombineSheet(editingFileID: cfg.editingFileID, name: cfg.name, picked: cfg.preselected) { newID in
                combineSheet = nil
                if let id = newID { openCombinedFile(id) }   // jump straight into the file you just made
            }
            .environmentObject(model)
        }
        .sheet(isPresented: $showPaste) {
            PasteSheet { showPaste = false }.environmentObject(model)
        }
        .alert("Add an AI", isPresented: $showAddSource) {
            TextField("AI name (e.g. Mistral)", text: $newSourceName)
            Button("Add") {
                if let key = model.addCustomSource(name: newSourceName) { nav = .source(key); selected = nil }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Adds it to your sources and to the “which AI?” picker when you import or paste.")
        }
        .alert("Name this combined file", isPresented: Binding(get: { namingConversations != nil },
                                                               set: { if !$0 { namingConversations = nil } })) {
            TextField("File name", text: $newFileName)
            Button("Create") {
                if let convs = namingConversations, !convs.isEmpty {
                    let f = model.createCombinedFile(name: newFileName, conversations: convs)
                    namingConversations = nil
                    openCombinedFile(f.id)
                }
            }
            Button("Cancel", role: .cancel) { namingConversations = nil }
        } message: {
            Text("\(namingConversations?.count ?? 0) conversation\((namingConversations?.count ?? 0) == 1 ? "" : "s") will be woven into one file.")
        }
        .alert("Name the merged file", isPresented: Binding(get: { pendingMerge != nil },
                                                           set: { if !$0 { pendingMerge = nil } })) {
            TextField("File name", text: $mergeName)
            Button("Combine") {
                if let ids = pendingMerge, ids.count >= 2 {
                    let f = model.combineFiles(Array(ids), name: mergeName.isEmpty ? "Combined" : mergeName)
                    pendingMerge = nil; selectingFiles = false; pickedFiles = []
                    openCombinedFile(f.id)
                }
            }
            Button("Cancel", role: .cancel) { pendingMerge = nil }
        } message: {
            Text("\(pendingMerge?.count ?? 0) files merge into one (their conversations are pooled). The originals fold away — no memories are lost.")
        }
        .confirmationDialog("Delete \(pendingFilesDelete?.count ?? 0) file\((pendingFilesDelete?.count ?? 0) == 1 ? "" : "s")?",
                            isPresented: Binding(get: { pendingFilesDelete != nil },
                                                 set: { if !$0 { pendingFilesDelete = nil } })) {
            Button("Delete", role: .destructive) {
                if let ids = pendingFilesDelete {
                    if let of = openFile, ids.contains(of) { openFile = nil }
                    ids.forEach { model.deleteCombinedFile($0) }
                }
                pendingFilesDelete = nil; selectingFiles = false; pickedFiles = []
            }
            Button("Cancel", role: .cancel) { pendingFilesDelete = nil }
        } message: {
            Text("Only the file groupings are removed. Your conversations and memories stay.")
        }
    }

    /// Open a combined file in the main panel (seeds the editable name, defaults to the woven view).
    /// Also lands us in the Collective Mind section, so "Combine into file…" from a source view jumps
    /// straight into the file it just made.
    private func openCombinedFile(_ id: String) {
        nav = .collective
        openFile = id
        fileNameDraft = model.combinedFile(id)?.name ?? ""
        collectiveMerged = true
        selecting = false; picked = []; selected = nil; selectedConv = nil
        selectingFiles = false; pickedFiles = []
    }

    /// After any change to the store (delete, reload), drop selections/sets that point at gone data —
    /// so the detail panel can't show a deleted conversation and ghost actions stay dead.
    private func pruneStaleSelection() {
        let convs = Set(model.memories.map { $0.conversationID })
        if let c = selectedConv, !convs.contains(c) { selectedConv = nil }
        if let m = selected, !model.memories.contains(where: { $0.id == m.id }) { selected = nil }
        expanded.formIntersection(convs)
        picked.formIntersection(convs)
    }

    /// When the OPEN file's membership changes (a conversation removed from it), drop any selection that
    /// now points outside the file — otherwise the detail panel shows a row the list no longer has, with
    /// a dead "Remove from this file" button. (Membership changes don't touch model.memories, so the
    /// store-keyed pruner above never fires for them.)
    private func pruneStaleFileSelection() {
        guard nav == .collective, let fid = openFile, let f = model.combinedFile(fid) else { return }
        if let c = selectedConv, !f.conversations.contains(c) { selectedConv = nil }
        if let m = selected, !f.conversations.contains(m.conversationID) { selected = nil }
        picked.formIntersection(f.conversations)
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 12) {
            trafficDots
            Text("Engram").font(.title3.weight(.medium))
                .allowsHitTesting(false)   // pressing the title drags too (caught by the background)
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $query).textFieldStyle(.plain).frame(width: 220)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .liquidPanel(corner: 10, frost: glassFrost, matte: matte)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(WindowDragArea())            // drag handle, sized exactly to the bar (no layout blow-up)
        .liquidPanel(corner: 18, frost: glassFrost, matte: matte)
    }

    // Custom window controls, drawn INSIDE the bar to the left of "Engram".
    private var trafficDots: some View {
        HStack(spacing: 8) {
            dot(Color(red: 1.0, green: 0.37, blue: 0.34), symbol: "xmark") { NSApp.terminate(nil) }              // close
            dot(Color(red: 1.0, green: 0.74, blue: 0.18), symbol: "minus") { NSApp.keyWindow?.miniaturize(nil) } // minimize
            dot(Color(red: 0.16, green: 0.78, blue: 0.25), symbol: "plus") { NSApp.keyWindow?.zoom(nil) }        // zoom
        }
        .onHover { hoverControls = $0 }
        .animation(.easeOut(duration: 0.12), value: hoverControls)
    }

    private func dot(_ color: Color, symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Circle().fill(color).frame(width: 15, height: 15)
                .overlay {
                    Image(systemName: symbol)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.black.opacity(0.55))
                        .opacity(hoverControls ? 1 : 0)   // symbols appear on hover, like macOS
                }
        }
        .buttonStyle(.plain)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            navRow("All Memories", symbol: "tray.full", nav: .all)
            navRow("Collective Mind", symbol: "circle.hexagongrid", nav: .collective,
                   count: model.combinedFiles.count)

            Text("SOURCES").font(.caption2).foregroundStyle(.secondary)
                .padding(.leading, 10).padding(.top, 12).padding(.bottom, 2)
            ForEach(model.allCircles) { c in
                let isCustom = model.customSources.contains { $0.id == c.id }
                SourceRow(circle: c,
                          count: model.memories(forCircle: c).count,
                          hasData: model.hasData(c),
                          selected: nav == .source(c.id),
                          onRemove: isCustom ? {
                              if nav == .source(c.id) { nav = .all }
                              model.removeCustomSource(c.id)
                          } : nil) {
                    nav = .source(c.id); selected = nil
                }
            }
            actionRow("Add AI", symbol: "plus.circle") { newSourceName = ""; showAddSource = true }
                .opacity(0.7)

            Spacer()

            actionRow("Import Notes", symbol: "square.and.arrow.down") { model.importMarkdown() }
            actionRow("Paste Text", symbol: "doc.on.clipboard") { showPaste = true }
            actionRow("Settings", symbol: "gearshape") { showSettings = true }
                .popover(isPresented: $showSettings, arrowEdge: .trailing) { settingsPopover }
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
        .liquidPanel(corner: 18, frost: glassFrost, matte: matte)
    }

    private func navRow(_ title: String, symbol: String? = nil, dot: Color? = nil,
                        nav target: Nav, count: Int? = nil, dim: Bool = false) -> some View {
        Button { nav = target; selected = nil; openFile = nil } label: {   // tapping a section always returns to its top
            HStack(spacing: 10) {
                if let symbol { Image(systemName: symbol).frame(width: 18) }
                if let dot { Circle().fill(dot).frame(width: 10, height: 10) }
                Text(title).font(.system(size: 13))
                Spacer()
                if let count, count > 0 { Text("\(count)").font(.caption2).foregroundStyle(.secondary) }
            }
            .opacity(dim ? 0.5 : 1)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(nav == target ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .hoverGlass(corner: 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func actionRow(_ title: String, symbol: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            HStack(spacing: 10) {
                Image(systemName: symbol).frame(width: 18)
                Text(title).font(.system(size: 13))
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .hoverGlass(corner: 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var settingsPopover: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "sun.max.fill").foregroundStyle(.yellow).font(.system(size: 13))
                Toggle("", isOn: Binding(get: { !lightMode }, set: { lightMode = !$0 }))
                    .labelsHidden().toggleStyle(.switch)
                Image(systemName: "moon.fill").foregroundStyle(.indigo).font(.system(size: 13))
            }
            Divider()
            Toggle(isOn: Binding(get: { !matte }, set: { matte = !$0 })) {
                Label("Liquid Glass", systemImage: "circle.hexagongrid").font(.system(size: 12))
            }
            .toggleStyle(.switch)
            if !matte {   // frost only matters while the glass is on
                HStack(spacing: 8) {
                    Image(systemName: "drop").font(.system(size: 11)).foregroundStyle(.secondary)
                    Slider(value: $glassFrost, in: 0...1).controlSize(.small).tint(.secondary)
                    Image(systemName: "drop.fill").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Divider()
            Button { updater.checkForUpdates() } label: {
                Label("Check for Updates…", systemImage: "arrow.down.circle").font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .disabled(!updater.canCheckForUpdates)
        }
        .padding(16).frame(width: 220)
    }

    // MARK: Main list

    @ViewBuilder private var exportMenu: some View {
        if !selecting && !visibleMemories.isEmpty {
            Menu {
                Button("Markdown (.md)") { model.export(visibleMemories, as: .markdown, suggestedName: exportName) }
                Button("JSON (.json)") { model.export(visibleMemories, as: .json, suggestedName: exportName) }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    .padding(.horizontal, 11).padding(.vertical, 5)
                    .background(Color.primary.opacity(0.06), in: Capsule())
                    .hoverGlass(corner: 12)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
    }

    @ViewBuilder private var selectChip: some View {
        if selecting || !grouped.isEmpty {   // keep "Done" reachable even if the list just emptied out
            chip(selecting ? "Done" : "Select") {
                withAnimation(.easeInOut(duration: 0.15)) { selecting.toggle(); picked.removeAll() }
            }
        }
    }

    // MARK: Collective Mind — a hub of named combined files

    /// The list of combined files (the "Collective Mind" hub). Each card opens its own woven file.
    @ViewBuilder private var combinedFilesHub: some View {
        if model.combinedFiles.isEmpty {
            Spacer()
            VStack(spacing: 12) {
                Image(systemName: "circle.hexagongrid").font(.largeTitle).foregroundStyle(.secondary)
                Text("No combined files yet.\nWeave any conversations you like into a named file.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                chip("+ New combination") { combineSheet = CombineSheetConfig(editingFileID: nil, name: "", preselected: []) }
            }
            .frame(maxWidth: .infinity)
            Spacer()
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(model.combinedFiles) { fileCard($0) }
                }
                .padding(.vertical, 2).padding(.horizontal, 10)   // room for the magnify to grow into (no clip)
            }
        }
    }

    private func fileCard(_ f: CombinedFile) -> some View {
        let mems = model.memories(inCombinedFile: f.id)
        let activeSources = model.allCircles.filter { c in mems.contains { c.sources.contains($0.source) } }
        let isPicked = pickedFiles.contains(f.id)
        return Button {
            if selectingFiles {
                if isPicked { pickedFiles.remove(f.id) } else { pickedFiles.insert(f.id) }
            } else {
                openCombinedFile(f.id)
            }
        } label: {
            HStack(spacing: 12) {
                if selectingFiles {
                    Image(systemName: isPicked ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16))
                        .foregroundStyle(isPicked ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                }
                Image(systemName: "doc.text.fill").font(.system(size: 22)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text(f.name.isEmpty ? "Untitled" : f.name).font(.system(size: 14, weight: .medium)).lineLimit(1)
                    // which AIs this file is woven from — a dot + name per source
                    if activeSources.isEmpty {
                        Text("Empty").font(.caption2).foregroundStyle(.secondary)
                    } else {
                        HStack(spacing: 10) {
                            ForEach(activeSources) { c in
                                HStack(spacing: 4) {
                                    Circle().fill(c.color).frame(width: 7, height: 7)
                                    Text(c.name).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                Spacer()
                if !selectingFiles {
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .background(isPicked ? AnyShapeStyle(Color.accentColor.opacity(0.12)) : AnyShapeStyle(Color.primary.opacity(0.04)),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .hoverGlass(corner: 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { openCombinedFile(f.id) } label: { Label("Open", systemImage: "arrow.up.forward.square") }
            Button { combineSheet = CombineSheetConfig(editingFileID: f.id, name: f.name, preselected: f.conversations) } label: {
                Label("Edit chats", systemImage: "slider.horizontal.3")
            }
            Menu {
                Button { model.export(mems, as: .markdown, suggestedName: f.name) } label: { Label("Markdown (.md)", systemImage: "doc.plaintext") }
                Button { model.export(mems, as: .json, suggestedName: f.name) } label: { Label("JSON (.json)", systemImage: "curlybraces") }
            } label: { Label("Export", systemImage: "square.and.arrow.up") }
            Divider()
            Button(role: .destructive) { pendingFileDelete = f.id } label: { Label("Delete file", systemImage: "trash") }
        }
    }

    /// One combined file shown as a single woven document (icon + fusion + export). The name lives in
    /// the header above, so this is just the file's body.
    private func wovenFileView(_ id: String) -> some View {
        let mems = model.memories(inCombinedFile: id)
        let convCount = Set(mems.map { $0.conversationID }).count
        let activeSources = model.allCircles.filter { c in mems.contains { c.sources.contains($0.source) } }
        let name = model.combinedFile(id)?.name ?? "Untitled"
        return VStack {
            Spacer(minLength: 24)
            VStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.tint.opacity(0.14)).frame(width: 78, height: 94)
                    Image(systemName: "doc.text").font(.system(size: 34, weight: .light)).foregroundStyle(.tint)
                }
                .shadow(color: Color.accentColor.opacity(0.28), radius: 20)

                if mems.isEmpty {
                    Text("This file is empty.\nAdd some conversations to weave them together.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 360)
                    chip("Add chats") { combineSheet = CombineSheetConfig(editingFileID: id, name: name, preselected: model.combinedFile(id)?.conversations ?? []) }
                } else {
                    Text("One file — woven from \(convCount) conversation\(convCount == 1 ? "" : "s") across \(activeSources.count) AI\(activeSources.count == 1 ? "" : "s").")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 360)
                    HStack(spacing: -5) {
                        ForEach(activeSources) { c in
                            Circle().fill(c.color).frame(width: 16, height: 16)
                                .overlay(Circle().strokeBorder(Color(nsColor: .controlBackgroundColor), lineWidth: 2))
                        }
                    }
                    Text("\(mems.count) memories inside").font(.caption).foregroundStyle(.secondary)
                    Menu {
                        Button { model.export(mems, as: .markdown, suggestedName: name) } label: { Label("Markdown (.md)", systemImage: "doc.plaintext") }
                        Button { model.export(mems, as: .json, suggestedName: name) } label: { Label("JSON (.json)", systemImage: "curlybraces") }
                    } label: {
                        Label("Export this file", systemImage: "square.and.arrow.up")
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 16).padding(.vertical, 8)
                            .background(.tint.opacity(0.14), in: Capsule())
                            .hoverGlass(corner: 16)
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().padding(.top, 2)
                }
            }
            .padding(28)
            Spacer(minLength: 24)
        }
        .frame(maxWidth: .infinity)
    }

    /// Are we showing a list of conversations that select/bulk can act on? (the hub of file cards isn't one)
    private var showsConversationList: Bool {
        switch nav {
        case .all, .source: return true
        case .collective:   return openFile != nil && !collectiveMerged
        }
    }

    private var mainPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            mainHeader
            if selecting && showsConversationList { bulkBar }
            mainContent
        }
        .padding(18)
        .frame(maxHeight: .infinity, alignment: .top)
        .liquidPanel(corner: 18, frost: glassFrost, matte: matte)
        .confirmationDialog("Forget this conversation?",
                            isPresented: Binding(get: { pendingDelete != nil },
                                                 set: { if !$0 { pendingDelete = nil } }),
                            presenting: pendingDelete) { conv in
            Button("Forget all of \(conv)", role: .destructive) {
                model.deleteConversation(conv); pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { _ in
            Text("This removes every memory in this conversation. You can re-import it later.")
        }
        .confirmationDialog("Forget \(picked.count) conversations?", isPresented: $pendingBulkDelete) {
            Button("Forget \(picked.count)", role: .destructive) {
                model.deleteConversations(Array(picked)); picked.removeAll(); selecting = false
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes every memory in the selected conversations. You can re-import them later.")
        }
        .confirmationDialog("Delete this combined file?",
                            isPresented: Binding(get: { pendingFileDelete != nil },
                                                 set: { if !$0 { pendingFileDelete = nil } }),
                            presenting: pendingFileDelete) { id in
            Button("Delete file", role: .destructive) {
                if openFile == id { openFile = nil }
                model.deleteCombinedFile(id); pendingFileDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingFileDelete = nil }
        } message: { _ in
            Text("This only deletes the combined file. Your conversations and memories stay untouched.")
        }
    }

    // MARK: Main panel header + content

    @ViewBuilder private var mainHeader: some View {
        if nav == .collective, openFile == nil {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("Collective Mind").font(.title3.weight(.medium))
                    Spacer()
                    if model.combinedFiles.count >= 2 {
                        chip(selectingFiles ? "Done" : "Select") {
                            withAnimation(.easeInOut(duration: 0.15)) { selectingFiles.toggle(); pickedFiles = [] }
                        }
                    }
                    if !selectingFiles {
                        chip("+ New") { combineSheet = CombineSheetConfig(editingFileID: nil, name: "", preselected: []) }
                    }
                }
                if selectingFiles {
                    HStack(spacing: 10) {
                        Text("\(pickedFiles.count) selected").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if pickedFiles.count >= 2 {
                            barAction("Combine", "square.on.square") { mergeName = ""; pendingMerge = pickedFiles }
                        }
                        if !pickedFiles.isEmpty {
                            barAction("Delete", "trash", destructive: true) { pendingFilesDelete = pickedFiles }
                        }
                    }
                }
            }
        } else if nav == .collective, let fid = openFile {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Button { openFile = nil; selecting = false; picked = [] } label: {
                        Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary).frame(width: 24, height: 24)
                            .hoverGlass(corner: 7).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    TextField("Name this file", text: $fileNameDraft)
                        .textFieldStyle(.plain).font(.title3.weight(.medium))
                    Spacer()
                    fileMenu(fid)
                }
                HStack(spacing: 8) {
                    Picker("", selection: $collectiveMerged) {
                        Text("One file").tag(true)
                        Text("By conversation").tag(false)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize().controlSize(.small)
                    Spacer()
                    if !collectiveMerged { exportMenu; selectChip }
                }
            }
        } else {
            HStack(spacing: 8) {
                Text(navTitle).font(.title3.weight(.medium))
                Spacer()
                exportMenu
                selectChip
            }
        }
    }

    /// The "…" menu on an open file: edit its chats or delete the file.
    private func fileMenu(_ id: String) -> some View {
        Menu {
            Button { combineSheet = CombineSheetConfig(editingFileID: id, name: model.combinedFile(id)?.name ?? "", preselected: model.combinedFile(id)?.conversations ?? []) } label: {
                Label("Edit chats", systemImage: "slider.horizontal.3")
            }
            Divider()
            Button(role: .destructive) { pendingFileDelete = id } label: { Label("Delete file", systemImage: "trash") }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                .frame(width: 24, height: 24).hoverGlass(corner: 7).contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    }

    @ViewBuilder private var mainContent: some View {
        if nav == .collective, openFile == nil {
            combinedFilesHub
        } else if nav == .collective, let fid = openFile, collectiveMerged {
            wovenFileView(fid)
        } else if visibleMemories.isEmpty {
            Spacer()
            VStack(spacing: 8) {
                Image(systemName: nav == .collective ? "doc.text" : "tray")
                    .font(.largeTitle).foregroundStyle(.secondary)
                Text(nav == .collective
                     ? "This file has no conversations.\nUse the ⋯ menu → Edit chats to add some."
                     : "No memories here yet")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            Spacer()
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(grouped, id: \.0) { conv, mems in
                        conversationHeader(conv, count: mems.count)
                        if isExpanded(conv) && !selecting {
                            ForEach(mems) { memoryCard($0).padding(.leading, 16) }   // the opened doll
                        }
                    }
                }
                .padding(.horizontal, 10)   // room for the magnify to grow into (no clip)
            }
        }
    }

    // Bulk action bar shown above the list in multi-select mode.
    private var bulkBar: some View {
        let allIDs = grouped.map { $0.0 }
        let allPicked = !allIDs.isEmpty && picked.count == allIDs.count
        return HStack(spacing: 10) {
            chip(allPicked ? "Deselect all" : "Select all") { picked = allPicked ? [] : Set(allIDs) }
            Text("\(picked.count) selected").font(.caption).foregroundStyle(.secondary)
            Spacer()
            if !picked.isEmpty {
                if nav == .collective, let fid = openFile {
                    // Inside an open file → the meaningful move is taking conversations out of it.
                    barAction("Remove from file", "minus.circle") {
                        model.removeFromCombinedFile(fid, conversations: Array(picked)); picked = []
                    }
                } else {
                    // Already chose the chats here → don't reopen a picker, just ask for a name.
                    barAction("Combine into file", "circle.hexagongrid") { startNaming(picked) }
                }
                barAction("Forget", "trash", destructive: true) { pendingBulkDelete = true }
            }
        }
        .padding(.top, 2)
    }

    /// When searching, everything is shown expanded; otherwise a conversation is collapsed until clicked.
    private func isExpanded(_ conv: String) -> Bool { !query.isEmpty || expanded.contains(conv) }

    // A conversation collapses to ONE row (file name + chunk count). Click the row → it opens into its
    // pieces (matryoshka). The Collective Mind toggle lives on the right, separate from the disclosure.
    private func conversationHeader(_ conv: String, count: Int) -> some View {
        let isExp = isExpanded(conv)
        let isPicked = picked.contains(conv)
        let isActive = !selecting && selectedConv == conv && selected == nil
        return HStack(spacing: 8) {
            if selecting {
                Image(systemName: isPicked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(isPicked ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            } else {
                // ONLY this chevron opens/closes the matryoshka — clicking the row never expands.
                Button {
                    guard query.isEmpty else { return }
                    withAnimation(.easeInOut(duration: 0.22)) {
                        if expanded.contains(conv) { expanded.remove(conv) } else { expanded.insert(conv) }
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExp ? 90 : 0))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            // Clicking the row body just SELECTS the conversation (shows it on the right); no expand.
            Button {
                if selecting {
                    if isPicked { picked.remove(conv) } else { picked.insert(conv) }
                } else {
                    selected = nil
                    selectedConv = conv
                }
            } label: {
                HStack(spacing: 8) {
                    Text(conv).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background((isPicked || isActive) ? AnyShapeStyle(Color.accentColor.opacity(0.12)) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .hoverGlass(corner: 10)
        .padding(.top, 4)
        .contextMenu {
            collectiveActionButton(conv)
            Button(role: .destructive) { pendingDelete = conv } label: {
                Label("Forget this conversation", systemImage: "trash")
            }
        }
    }

    private func memoryCard(_ m: Memory) -> some View {
        Button { selected = m } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(m.content).font(.system(size: 13)).lineLimit(2).multilineTextAlignment(.leading)
                HStack(spacing: 5) {
                    Circle().fill(sourceColor(m.source)).frame(width: 7, height: 7)   // which AI — shows the fusion
                    Text("\(label(m.source)) · \(m.updatedAt.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(selected?.id == m.id ? AnyShapeStyle(.tint.opacity(0.16)) : AnyShapeStyle(Color.primary.opacity(0.04)),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected?.id == m.id ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), lineWidth: 1.5))
            .hoverGlass(corner: 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            collectiveActionButton(m.conversationID)
            Button(role: .destructive) { model.delete(m); if selected?.id == m.id { selected = nil } } label: {
                Text("Forget this memory")
            }
        }
    }

    /// The right per-conversation action for the current view: inside an open file → remove it from that
    /// file; anywhere else → weave it into a new combined file.
    @ViewBuilder private func collectiveActionButton(_ conv: String) -> some View {
        if nav == .collective, let fid = openFile {
            Button { model.removeFromCombinedFile(fid, conversations: [conv]) } label: {
                Label("Remove from this file", systemImage: "minus.circle")
            }
        } else {
            Button { startNaming([conv]) } label: {
                Label("Combine into a file…", systemImage: "circle.hexagongrid")
            }
        }
    }

    @ViewBuilder private func collectiveDetailAction(_ conv: String) -> some View {
        if nav == .collective, let fid = openFile {
            detailAction("Remove from this file", "minus.circle") { model.removeFromCombinedFile(fid, conversations: [conv]) }
        } else {
            detailAction("Combine into a file…", "circle.hexagongrid") { startNaming([conv]) }
        }
    }

    /// The chats are already chosen — pop a tiny name prompt (no second selection screen) and make the file.
    private func startNaming(_ conversations: Set<String>) {
        guard !conversations.isEmpty else { return }
        namingConversations = conversations
        newFileName = ""
        selecting = false
    }

    // MARK: Detail

    private var detailPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(detailTitle).font(.headline)
            if let m = selected {
                Text(m.content).font(.system(size: 14)).textSelection(.enabled)
                Divider()
                detailRow("Source", label(m.source))
                detailRow("Conversation", m.conversationID)
                if !m.tags.isEmpty { detailRow("Tags", m.tags.joined(separator: ", ")) }
                detailRow("Created", m.createdAt.formatted(date: .abbreviated, time: .shortened))
                detailRow("Updated", m.updatedAt.formatted(date: .abbreviated, time: .shortened))
                Spacer()
                collectiveDetailAction(m.conversationID)
                detailAction("Forget", "trash", destructive: true) { model.delete(m); selected = nil }
            } else if let conv = selectedConv, let info = conversationInfo(conv) {
                Text(conv).font(.system(size: 14, weight: .medium)).lineLimit(3).textSelection(.enabled)
                Divider()
                detailRow("Memories", "\(info.count)")
                detailRow("Source", label(info.source))
                Spacer()
                collectiveDetailAction(conv)
                detailAction("Forget", "trash", destructive: true) { pendingDelete = conv }
            } else if nav == .collective, let fid = openFile, let f = model.combinedFile(fid) {
                fileDetail(f)
            } else {
                Spacer()
                VStack(spacing: 6) {
                    Image(systemName: "hand.point.up.left").font(.title2).foregroundStyle(.secondary)
                    Text(nav == .collective ? "Open a file to see its details" : "Pick a conversation").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity)
                Spacer()
            }
        }
        .padding(18)
        .frame(maxHeight: .infinity, alignment: .top)
        .liquidPanel(corner: 18, frost: glassFrost, matte: matte)
    }

    private var detailTitle: String {
        if selected != nil { return "Memory" }
        if selectedConv != nil { return "Conversation" }
        if nav == .collective, openFile != nil { return "File" }
        return "Details"
    }

    /// Right-panel details for the open combined file: what it holds + its management actions.
    @ViewBuilder private func fileDetail(_ f: CombinedFile) -> some View {
        let mems = model.memories(inCombinedFile: f.id)
        let activeSources = model.allCircles.filter { c in mems.contains { c.sources.contains($0.source) } }
        Text(f.name.isEmpty ? "Untitled" : f.name).font(.system(size: 14, weight: .medium)).lineLimit(2).textSelection(.enabled)
        Divider()
        detailRow("Memories", "\(mems.count)")
        detailRow("Conversations", "\(model.liveConversationCount(f))")   // live, not raw membership (no phantom ids)
        detailRow("Sources", activeSources.isEmpty ? "—" : activeSources.map { $0.name }.joined(separator: ", "))
        Spacer()
        detailAction("Edit chats", "slider.horizontal.3") {
            combineSheet = CombineSheetConfig(editingFileID: f.id, name: f.name, preselected: f.conversations)
        }
        detailAction("Delete file", "trash", destructive: true) { pendingFileDelete = f.id }
    }

    private func detailRow(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(v).font(.caption).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
    }

    // MARK: Data

    private var visibleMemories: [Memory] {
        var base: [Memory]
        switch nav {
        case .all: base = model.memories
        case .collective: base = openFile.map { model.memories(inCombinedFile: $0) } ?? []   // the open file's chats
        case .source(let id):
            base = model.allCircles.first { $0.id == id }.map { model.memories(forCircle: $0) } ?? []
        }
        if !query.isEmpty { base = base.filter { $0.content.localizedCaseInsensitiveContains(query) } }
        return base.sorted { $0.updatedAt > $1.updatedAt }
    }

    private var grouped: [(String, [Memory])] {
        let g = Dictionary(grouping: visibleMemories, by: { $0.conversationID })
        // newest conversation first (by its most-recent memory), not alphabetical by id
        return g.map { ($0.key, $0.value) }.sorted { a, b in
            (a.1.map { $0.updatedAt }.max() ?? .distantPast) > (b.1.map { $0.updatedAt }.max() ?? .distantPast)
        }
    }

    private var navTitle: String {
        switch nav {
        case .all: return "All Memories"
        case .collective: return "Collective Mind"
        case .source(let id): return model.allCircles.first { $0.id == id }?.name ?? "Memories"
        }
    }

    private var exportName: String {
        if nav == .collective, let fid = openFile, let f = model.combinedFile(fid) { return "Engram - \(f.name)" }
        return "Engram - \(navTitle)"
    }

    private func label(_ source: String) -> String {
        switch source {
        case "claude-code": return "Claude Code"
        case "claude-desktop": return "Claude Desktop"
        case "claude": return "Claude"
        case "chatgpt": return "ChatGPT"
        case "gemini": return "Gemini"
        case "grok": return "Grok"
        case "deepseek": return "DeepSeek"
        case "ollama": return "Ollama"
        case "manual": return "Manual"
        case "import": return "Imported"
        default: return source.capitalized
        }
    }

    /// The brand colour of the AI a memory came from (for the fusion dot). Falls back to grey.
    private func sourceColor(_ source: String) -> Color {
        model.allCircles.first { $0.sources.contains(source) }?.color ?? .secondary
    }

    // MARK: Reusable controls

    /// Neutral text chip (Select / Done / Select all) — a soft capsule, not loud blue text.
    private func chip(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                .padding(.horizontal, 11).padding(.vertical, 5)
                .background(Color.primary.opacity(0.06), in: Capsule())
                .hoverGlass(corner: 12)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// A calm bulk-bar action: neutral icon + label, no loud filled capsule — same restrained language as
    /// the detail panel. Only on hover does a faint wash appear (red for the destructive one).
    private func barAction(_ title: String, _ icon: String, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .hoverGlass(corner: 8, tint: destructive ? .red : nil)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// A minimal, calm detail-panel action: a full-width subtle row (icon + short label), neutral colours
    /// — no loud filled blue/red. "active" tints the label; "destructive" shows a faint red only on hover.
    private func detailAction(_ title: String, _ icon: String, active: Bool = false, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)   // fully neutral — the checkmark icon shows the active state, no blue
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .hoverGlass(corner: 9, tint: destructive ? .red : nil)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func conversationInfo(_ conv: String) -> (count: Int, source: String)? {
        let mems = model.memories.filter { $0.conversationID == conv }
        guard let first = mems.first else { return nil }
        return (mems.count, first.source)
    }
}

/// A source (AI model) row whose own colored light softly BLOOMS in when the cursor hovers it —
/// not an instant on/off, but an eased fade+expand, then fades back out when the cursor leaves.
private struct SourceRow: View {
    let circle: AICircle
    let count: Int
    let hasData: Bool
    let selected: Bool
    var onRemove: (() -> Void)? = nil    // non-nil only for user-added custom AIs
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 10) {
                Circle().fill(circle.color).frame(width: 10, height: 10).frame(width: 18)
                Text(circle.name).font(.system(size: 13))
                Spacer()
                if count > 0 { Text("\(count)").font(.caption2).foregroundStyle(.secondary) }
            }
            .opacity(hasData ? 1 : 0.5)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(selected ? AnyShapeStyle(circle.color.opacity(0.18)) : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
            .hoverGlass(corner: 9, tint: circle.color)   // same liquid-glass hover, in the model's own color
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let onRemove {
                Button(role: .destructive, action: onRemove) { Label("Remove this AI", systemImage: "trash") }
            }
        }
    }
}

/// Drives the create/edit-combined-file sheet. `editingFileID == nil` means "make a new one".
struct CombineSheetConfig: Identifiable {
    let id = UUID()
    var editingFileID: String?
    var name: String
    var preselected: Set<String>
}

/// Pick a name + the conversations to weave together. Used both to create a new combined file and to
/// edit an existing one's membership. Returns the file id (new or edited) so the caller can open it.
private struct CombineSheet: View {
    @EnvironmentObject var model: AppModel
    let editingFileID: String?
    @State private var name: String
    @State private var picked: Set<String>
    @State private var sourceFilter: String? = nil   // nil = All; otherwise an AICircle id
    let onDone: (String?) -> Void

    init(editingFileID: String?, name: String, picked: Set<String>, onDone: @escaping (String?) -> Void) {
        self.editingFileID = editingFileID
        _name = State(initialValue: name)
        _picked = State(initialValue: picked)
        self.onDone = onDone
    }

    var body: some View {
        let all = model.allConversations()   // recency-sorted (newest first)
        let shown = sourceFilter == nil ? all : all.filter { conv in
            model.allCircles.first { $0.id == sourceFilter }?.sources.contains(conv.source) ?? false
        }
        let activeCircles = model.allCircles.filter { model.hasData($0) }
        let allOn = !shown.isEmpty && shown.allSatisfy { picked.contains($0.id) }
        return VStack(alignment: .leading, spacing: 12) {
            Text(editingFileID == nil ? "New combined file" : "Edit combined file").font(.headline)

            TextField("File name", text: $name).textFieldStyle(.roundedBorder)

            // category tabs — All (recency) + one per source that has data
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    sourceTab(nil, "All", color: nil)
                    ForEach(activeCircles) { c in sourceTab(c.id, c.name, color: c.color) }
                }
            }

            HStack {
                Text("Newest first").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(allOn ? "Clear" : "Select all") {
                    if allOn { shown.forEach { picked.remove($0.id) } } else { shown.forEach { picked.insert($0.id) } }
                }
                .buttonStyle(.plain).font(.caption.weight(.medium)).foregroundStyle(.tint)
                .disabled(shown.isEmpty)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(shown, id: \.id) { c in
                        Button { toggle(c.id) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: picked.contains(c.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(picked.contains(c.id) ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                                Circle().fill(sourceColor(c.source)).frame(width: 7, height: 7)
                                Text(c.id).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 8)
                                Text("\(c.count)").font(.caption2).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(picked.contains(c.id) ? AnyShapeStyle(Color.accentColor.opacity(0.10)) : AnyShapeStyle(.clear),
                                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(4)
            }
            .frame(height: 250)
            .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            HStack {
                Text("\(picked.count) selected").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { onDone(nil) }.keyboardShortcut(.cancelAction)
                Button(editingFileID == nil ? "Create" : "Save") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(editingFileID == nil && picked.isEmpty)   // new file needs ≥1 chat; editing may drain to empty
            }
        }
        .padding(18)
        .frame(width: 460)
    }

    private func sourceTab(_ id: String?, _ title: String, color: Color?) -> some View {
        let active = sourceFilter == id
        return Button { sourceFilter = id } label: {
            HStack(spacing: 5) {
                if let color { Circle().fill(color).frame(width: 7, height: 7) }
                Text(title).font(.caption.weight(.medium))
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .foregroundStyle(active ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .background(active ? AnyShapeStyle(Color.accentColor.opacity(0.16)) : AnyShapeStyle(Color.primary.opacity(0.05)), in: Capsule())
            .hoverGlass(corner: 12)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func toggle(_ id: String) { if picked.contains(id) { picked.remove(id) } else { picked.insert(id) } }

    private func commit() {
        if let id = editingFileID {
            model.renameCombinedFile(id, to: name)
            model.setMembers(id, conversations: picked)
            onDone(id)
        } else {
            let file = model.createCombinedFile(name: name, conversations: picked)
            onDone(file.id)
        }
    }

    private func sourceColor(_ s: String) -> Color { model.allCircles.first { $0.sources.contains(s) }?.color ?? .secondary }
}

/// Paste a conversation / notes straight in (no file) — pick which AI it's from, give it a title, and
/// Engram pulls the meaningful lines into memory. The fast path for getting other AIs' content in.
private struct PasteSheet: View {
    @EnvironmentObject var model: AppModel
    @State private var title = ""
    @State private var source = "chatgpt"
    @State private var text = ""
    @State private var distill = true
    let onDone: () -> Void

    private var sourceTitle: String { model.importSourceChoices.first { $0.source == source }?.title ?? "Other" }
    private var canImport: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Paste a conversation").font(.headline)
            Text("Paste text or a JSON export from any AI — Engram keeps the meaningful lines and tags the source. Nothing leaves your Mac.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                TextField("Title (optional)", text: $title).textFieldStyle(.roundedBorder)
                Menu {
                    ForEach(model.importSourceChoices, id: \.source) { c in
                        Button(c.title) { source = c.source }
                    }
                } label: {
                    HStack(spacing: 6) {
                        if let color = model.allCircles.first(where: { $0.sources.contains(source) })?.color {
                            Circle().fill(color).frame(width: 7, height: 7)
                        }
                        Text(sourceTitle).font(.caption.weight(.medium))
                        Image(systemName: "chevron.down").font(.system(size: 9))
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color.primary.opacity(0.06), in: Capsule())
                    .foregroundStyle(.secondary)
                    .hoverGlass(corner: 13)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }

            Picker("Keep", selection: $distill) {
                Text("Key facts").tag(true)
                Text("Everything").tag(false)
            }
            .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 300)
            Text(distill ? "Keeps only the durable things you said — preferences, facts, decisions."
                         : "⚠️ Imports every line — a long chat can become hundreds of entries.")
                .font(.caption).foregroundStyle(distill ? Color.secondary : Color.orange)
                .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $text)
                .font(.system(size: 12))
                .scrollContentBackground(.hidden)
                .frame(height: 240)
                .padding(6)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Paste here…").font(.system(size: 12)).foregroundStyle(.secondary)
                            .padding(.horizontal, 12).padding(.vertical, 14).allowsHitTesting(false)
                    }
                }

            HStack {
                Text(canImport ? "\(text.count) characters" : "").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { onDone() }.keyboardShortcut(.cancelAction)
                Button("Import") {
                    _ = model.importPastedText(text, source: source, title: title, distill: distill)
                    onDone()
                }
                .keyboardShortcut(.defaultAction).disabled(!canImport)
            }
        }
        .padding(18).frame(width: 480)
    }
}
