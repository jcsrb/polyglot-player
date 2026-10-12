import AVFoundation
import Observation

enum Output: Hashable {
    case off
    case systemDefault
    case device(uid: String)
}

/// Plays one video and any number of its audio tracks, each on its own output device.
///
/// The video plays in a silent `AVPlayer` that acts as the master clock. Every audio track gets
/// its own audio-only `AVPlayer` routed to a device, and follows the master: it pauses, seeks and
/// starts with it, and is nudged back when it drifts. Each device can play its audio early by a
/// latency offset to make up for Bluetooth delay.
@MainActor @Observable
final class PlaybackEngine {
    struct Route: Identifiable {
        let id: Int
        let title: String
        let detail: String
        let language: String?
        var output: Output
        var volume: Float = 1
    }

    private(set) var routes: [Route] = []
    private(set) var title = ""
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var offsetsMs: [String: Double]

    @ObservationIgnored let video = AVPlayer()
    @ObservationIgnored private let devices: AudioDevices
    @ObservationIgnored private var audioPlayers: [Int: AVPlayer] = [:]
    @ObservationIgnored private var currentURL: URL?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var jumpObserver: NSObjectProtocol?
    @ObservationIgnored private var driftTimer: Timer?
    @ObservationIgnored private var followPending = false
    @ObservationIgnored private let hostClock = CMClockGetHostTimeClock()
    @ObservationIgnored private let debug = ProcessInfo.processInfo.environment["POLYGLOT_DEBUG"] != nil

    /// Audio is resynced when it is further than this from where the video says it should be.
    private static let driftTolerance = 0.04
    /// How far ahead a synchronized start is scheduled, so every player can be ready in time.
    private static let startLead = CMTime(seconds: 0.12, preferredTimescale: 1_000_000_000)
    private static let defaultBluetoothOffsetMs = 200.0

    init(devices: AudioDevices) {
        self.devices = devices
        offsetsMs = UserDefaults.standard.dictionary(forKey: "offsetsMs") as? [String: Double] ?? [:]
        configure(video)
    }

    var hasMedia: Bool { !routes.isEmpty }

    // MARK: - Loading

    func load(_ url: URL) async {
        guard url != currentURL, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        unload()
        errorMessage = nil

        do {
            let asset = AVURLAsset(url: url)
            guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
                throw LoadError("\(url.lastPathComponent) has no video track macOS can play.")
            }
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            guard !audioTracks.isEmpty else {
                throw LoadError("\(url.lastPathComponent) has no audio tracks macOS can play.")
            }

            video.replaceCurrentItem(with: AVPlayerItem(asset: try await Self.composition(of: videoTrack)))

            var loaded: [Route] = []
            for (index, track) in audioTracks.enumerated() {
                let player = AVPlayer(playerItem: AVPlayerItem(asset: try await Self.composition(of: track)))
                configure(player)
                audioPlayers[index] = player

                let info = try await TrackInfo(track, index: index)
                let output = rememberedOutput(for: info.language) ?? (index == 0 ? .systemDefault : .off)
                loaded.append(Route(id: index, title: info.title, detail: info.detail, language: info.language, output: output))
            }
            routes = loaded
            currentURL = url
            title = url.lastPathComponent
            startFollowing()
            routes.forEach(apply)
            video.play()
        } catch {
            unload()
            errorMessage = (error as? LoadError)?.message ?? error.localizedDescription
        }
    }

    private func unload() {
        video.pause()
        video.replaceCurrentItem(with: nil)
        audioPlayers.values.forEach { $0.pause() }
        audioPlayers = [:]
        routes = []
        title = ""
        currentURL = nil
        observations = []
        if let jumpObserver { NotificationCenter.default.removeObserver(jumpObserver) }
        jumpObserver = nil
        driftTimer?.invalidate()
        driftTimer = nil
    }

    /// A composition holding just one track, so each player decodes only what it needs.
    private static func composition(of track: AVAssetTrack) async throws -> AVComposition {
        let composition = AVMutableComposition()
        let range = try await track.load(.timeRange)
        guard let copy = composition.addMutableTrack(withMediaType: track.mediaType, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw LoadError("Could not read a \(track.mediaType.rawValue) track.")
        }
        try copy.insertTimeRange(range, of: track, at: range.start)
        if track.mediaType == .video {
            copy.preferredTransform = try await track.load(.preferredTransform)
        }
        return composition
    }

    private func configure(_ player: AVPlayer) {
        // Required for setRate(_:time:atHostTime:); local files don't need stall protection.
        player.automaticallyWaitsToMinimizeStalling = false
        player.sourceClock = hostClock
    }

    // MARK: - Routing

    func setOutput(_ output: Output, for id: Int) {
        guard let index = routes.firstIndex(where: { $0.id == id }) else { return }
        routes[index].output = output
        remember(output, for: routes[index].language)
        apply(routes[index])
    }

    func setVolume(_ volume: Float, for id: Int) {
        guard let index = routes.firstIndex(where: { $0.id == id }) else { return }
        routes[index].volume = volume
        applyVolume(routes[index])
    }

    func offsetMs(for output: Output) -> Double {
        guard let key = Self.offsetKey(output) else { return 0 }
        if let stored = offsetsMs[key] { return stored }
        if case .device(let uid) = output, devices.device(uid: uid)?.isBluetooth == true {
            return Self.defaultBluetoothOffsetMs
        }
        return 0
    }

    func setOffsetMs(_ ms: Double, for output: Output) {
        guard let key = Self.offsetKey(output) else { return }
        offsetsMs[key] = ms
        UserDefaults.standard.set(offsetsMs, forKey: "offsetsMs")
        routes.filter { $0.output == output }.forEach(follow)
    }

    private func apply(_ route: Route) {
        guard let player = audioPlayers[route.id] else { return }
        switch route.output {
        case .off:
            player.pause()
            return
        case .systemDefault:
            player.audioOutputDeviceUniqueID = nil
        case .device(let uid):
            player.audioOutputDeviceUniqueID = uid
        }
        applyVolume(route)
        follow(route)
    }

    /// The video player's volume and mute (driven by its on-screen controls) act as a master volume.
    private func applyVolume(_ route: Route) {
        guard let player = audioPlayers[route.id] else { return }
        player.volume = video.volume * route.volume
        player.isMuted = video.isMuted
    }

    private static func offsetKey(_ output: Output) -> String? {
        switch output {
        case .off: nil
        case .systemDefault: "default"
        case .device(let uid): uid
        }
    }

    private func rememberedOutput(for language: String?) -> Output? {
        guard let language, let stored = UserDefaults.standard.string(forKey: "output.\(language)") else { return nil }
        switch stored {
        case "off": return .off
        case "default": return .systemDefault
        default: return devices.device(uid: stored) != nil ? .device(uid: stored) : nil
        }
    }

    private func remember(_ output: Output, for language: String?) {
        guard let language else { return }
        UserDefaults.standard.set(Self.offsetKey(output) ?? "off", forKey: "output.\(language)")
    }

    // MARK: - Sync

    private func startFollowing() {
        observations = [
            video.observe(\.rate) { [weak self] _, _ in
                Task { @MainActor in self?.scheduleFollow() }
            },
            video.observe(\.volume) { [weak self] _, _ in
                Task { @MainActor in self?.routes.forEach { self?.applyVolume($0) } }
            },
            video.observe(\.isMuted) { [weak self] _, _ in
                Task { @MainActor in self?.routes.forEach { self?.applyVolume($0) } }
            },
        ]
        jumpObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.timeJumpedNotification, object: video.currentItem, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleFollow() }
        }
        driftTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.correctDrift() }
        }
    }

    /// Rate changes and seeks often arrive together; handle them once.
    private func scheduleFollow() {
        guard !followPending else { return }
        followPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            MainActor.assumeIsolated {
                self?.followPending = false
                self?.routes.forEach { self?.follow($0) }
            }
        }
    }

    private func follow(_ route: Route) {
        guard route.output != .off, let player = audioPlayers[route.id] else { return }
        if video.rate == 0 {
            player.pause()
            player.seek(to: video.currentTime() + offset(route), toleranceBefore: .zero, toleranceAfter: .zero)
        } else {
            start(route)
        }
    }

    /// Starts an audio player at a host time slightly in the future, at the position the video
    /// will have reached by then (plus the device's latency offset).
    private func start(_ route: Route) {
        guard let player = audioPlayers[route.id], let master = video.currentItem?.timebase else { return }
        let hostTime = CMClockGetTime(hostClock) + Self.startLead
        let videoTime = CMSyncConvertTime(hostTime, from: hostClock, to: master)
        player.setRate(video.rate, time: videoTime + offset(route), atHostTime: hostTime)
    }

    private func correctDrift() {
        guard video.rate != 0, let master = video.currentItem?.timebase else { return }
        let now = CMClockGetTime(hostClock)
        let videoNow = CMSyncConvertTime(now, from: hostClock, to: master)
        for route in routes where route.output != .off {
            guard let player = audioPlayers[route.id], let timebase = player.currentItem?.timebase else { continue }
            let drift = (CMSyncConvertTime(now, from: hostClock, to: timebase) - videoNow - offset(route)).seconds
            log(String(format: "track %d drift %+.1f ms", route.id, drift * 1000))
            if player.rate == 0 || abs(drift) > Self.driftTolerance {
                log("track \(route.id) resync")
                start(route)
            }
        }
    }

    private func log(_ message: String) {
        guard debug else { return }
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    private func offset(_ route: Route) -> CMTime {
        CMTime(seconds: offsetMs(for: route.output) / 1000, preferredTimescale: 1_000_000)
    }
}

private struct LoadError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

/// Human-readable description of an audio track: language, title, codec, channels.
private struct TrackInfo {
    let title: String
    let detail: String
    let language: String?

    init(_ track: AVAssetTrack, index: Int) async throws {
        let (extendedTag, languageCode) = try await track.load(.extendedLanguageTag, .languageCode)
        let tag = extendedTag ?? languageCode
        let code = tag.flatMap { $0 == "und" ? nil : Locale.Language(identifier: $0).languageCode?.identifier(.alpha2) ?? $0 }
        language = code
        title = code.flatMap { Locale.current.localizedString(forLanguageCode: $0) } ?? "Track \(index + 1)"

        var parts: [String] = []
        let titleItems = AVMetadataItem.metadataItems(from: try await track.load(.commonMetadata), filteredByIdentifier: .commonIdentifierTitle)
        if let name = try await titleItems.first?.load(.stringValue), !name.isEmpty {
            parts.append(name)
        }
        if let format = try await track.load(.formatDescriptions).first,
           let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee {
            parts.append(Self.codecName(description.mFormatID))
            parts.append(Self.channelName(Int(description.mChannelsPerFrame)))
        }
        detail = parts.joined(separator: " · ")
    }

    private static func codecName(_ id: AudioFormatID) -> String {
        switch id {
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2: "AAC"
        case kAudioFormatAC3: "AC-3"
        case kAudioFormatEnhancedAC3: "E-AC-3"
        case kAudioFormatMPEGLayer3: "MP3"
        case kAudioFormatAppleLossless: "ALAC"
        case kAudioFormatFLAC: "FLAC"
        case kAudioFormatOpus: "Opus"
        case kAudioFormatLinearPCM: "PCM"
        default: "Audio"
        }
    }

    private static func channelName(_ count: Int) -> String {
        switch count {
        case 1: "Mono"
        case 2: "Stereo"
        case 6: "5.1"
        case 8: "7.1"
        default: "\(count) ch"
        }
    }
}
