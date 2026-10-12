import AVKit
import SwiftUI

struct ContentView: View {
    @Environment(PlaybackEngine.self) private var engine
    @State private var showsRouting = true

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                if engine.hasMedia {
                    PlayerView(player: engine.video)
                } else {
                    EmptyState()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if showsRouting && engine.hasMedia {
                Divider()
                RoutingPanel()
                    .frame(width: 300)
            }
        }
        .navigationTitle(engine.title.isEmpty ? "Polyglot" : engine.title)
        .toolbar {
            Button {
                showsRouting.toggle()
            } label: {
                Label("Audio Routing", systemImage: "sidebar.right")
            }
            .help("Show or hide audio routing")
            .disabled(!engine.hasMedia)
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in await engine.load(url) }
            }
            return true
        }
    }
}

private struct EmptyState: View {
    @Environment(PlaybackEngine.self) private var engine

    var body: some View {
        VStack(spacing: 12) {
            if let progress = engine.conversionProgress {
                Text("Converting for playback…")
                    .font(.title3)
                ProgressView(value: progress)
                    .frame(width: 260)
                Text("Video is copied, not re-encoded. Converted files are cached, so this only happens once.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else if engine.isLoading {
                ProgressView()
            } else {
                Image(systemName: "film.stack")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("Drop a video here or press ⌘O")
                    .font(.title3)
                Text("Each audio track can play on its own output device.")
                    .foregroundStyle(.secondary)
                if let message = engine.errorMessage {
                    Text(message)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.top, 8)
                }
            }
        }
        .padding()
    }
}

private struct RoutingPanel: View {
    @Environment(PlaybackEngine.self) private var engine

    var body: some View {
        Form {
            Section {
                ForEach(engine.routes) { route in
                    RouteRow(route: route)
                }
            } header: {
                Text("Audio Tracks")
            } footer: {
                Text("Match each device to the picture: play it early if it lags (Bluetooth headphones usually need 150–250 ms), late if it runs ahead.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct RouteRow: View {
    @Environment(PlaybackEngine.self) private var engine
    @Environment(AudioDevices.self) private var devices
    let route: PlaybackEngine.Route

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(route.title).font(.headline)
                if !route.detail.isEmpty {
                    Text(route.detail).font(.caption).foregroundStyle(.secondary)
                }
            }

            Picker("Output", selection: Binding(
                get: { route.output },
                set: { engine.setOutput($0, for: route.id) }
            )) {
                Text("Off").tag(Output.off)
                Text("System Default").tag(Output.systemDefault)
                Divider()
                ForEach(devices.outputs) { device in
                    Text(device.name).tag(Output.device(uid: device.uid))
                }
                if case .device(let uid) = route.output, devices.device(uid: uid) == nil {
                    Text("Disconnected device").tag(route.output)
                }
            }

            if route.output != .off {
                HStack {
                    Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                    Slider(value: Binding(
                        get: { route.volume },
                        set: { engine.setVolume($0, for: route.id) }
                    ), in: 0...1)
                    Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                }

                Stepper(value: Binding(
                    get: { engine.offsetMs(for: route.output) },
                    set: { engine.setOffsetMs($0, for: route.output) }
                ), in: -500...1000, step: 10) {
                    Text(Self.offsetLabel(engine.offsetMs(for: route.output)))
                        .monospacedDigit()
                }
            }
        }
        .padding(.vertical, 4)
    }

    private static func offsetLabel(_ ms: Double) -> String {
        switch Int(ms) {
        case 0: "In sync with video"
        case let early where early > 0: "Plays \(early) ms early"
        case let late: "Plays \(-late) ms late"
        }
    }
}

private struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        view.player = player
    }
}
