import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct PolyglotApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        Window("Polyglot", id: "main") {
            ContentView()
                .environment(appDelegate.engine)
                .environment(appDelegate.devices)
                .frame(minWidth: 720, minHeight: 400)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") { appDelegate.showOpenPanel() }
                    .keyboardShortcut("o")
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let devices: AudioDevices
    let engine: PlaybackEngine

    override init() {
        devices = AudioDevices()
        engine = PlaybackEngine(devices: devices)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when started as a bare executable (`swift run`) rather than from the .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        if let path = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("-") }) {
            open(URL(fileURLWithPath: path))
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if let url = urls.first { open(url) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie]
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    private func open(_ url: URL) {
        Task { await engine.load(url) }
    }
}
