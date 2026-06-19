import SwiftUI
import AppKit
import Combine
import Sparkle

// The window is built by hand in AppKit so it can be TRULY frameless — a borderless, transparent,
// shadowless panel. Only the circles show over the desktop; no window edge, no corner, no chrome.
// (A standard SwiftUI WindowGroup always leaves a faint frame/rounded corner; borderless removes it.)
@main
struct EngramApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        Settings { EmptyView() }   // no auto window — the delegate owns the real frameless window
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private let model = AppModel()
    private let updater = UpdaterViewModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let hosting = NSHostingView(rootView: RootView().environmentObject(model).environmentObject(updater))
        hosting.autoresizingMask = [.width, .height]

        let win = KeyableWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.titleVisibility = .hidden            // no title text — just the traffic-light buttons
        win.titlebarAppearsTransparent = true    // content (glass) runs full-height under the controls
        win.isMovableByWindowBackground = false  // dragging is restricted to the top bar (see WindowDragArea)
        win.standardWindowButton(.closeButton)?.isHidden = true       // hidden — we draw our own dots in the bar
        win.standardWindowButton(.miniaturizeButton)?.isHidden = true
        win.standardWindowButton(.zoomButton)?.isHidden = true
        win.contentView = hosting
        win.center()
        win.makeKeyAndOrderFront(nil)

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        self.window = win
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Borderless windows refuse key/main focus by default, which would kill the search field. Allow it.
final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Wraps Sparkle for MANUAL-ONLY in-app updates. Automatic background checks are off, so the app
/// stays silent on the network until the user explicitly taps "Check for Updates" (see PRIVACY.md).
@MainActor
final class UpdaterViewModel: ObservableObject {
    private let controller: SPUStandardUpdaterController
    @Published var canCheckForUpdates = false

    init() {
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        controller.updater.automaticallyChecksForUpdates = false   // no background polling — manual only
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() { controller.updater.checkForUpdates() }
}

private struct RootView: View {
    var body: some View {
        ContentView()
            .frame(minWidth: 560, minHeight: 640)
            .contextMenu { Button("Quit Engram") { NSApp.terminate(nil) } }
    }
}
