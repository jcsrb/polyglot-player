import CryptoKit
import Foundation

/// Repackages files AVFoundation can't open (e.g. MKV) as MP4 with ffmpeg. Video is copied, not
/// re-encoded, so this takes seconds. Results are cached, so reopening a file is instant.
/// Same conversion as `scripts/to-mp4.sh`.
enum Remuxer {
    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// Converted files kept in the cache; older ones are deleted.
    private static let cacheLimit = 3
    /// Audio codecs AVFoundation plays; anything else is converted to AAC.
    private static let playableAudio: Set = ["aac", "ac3", "eac3", "alac", "mp3"]

    static func playableCopy(of source: URL, progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        guard let ffmpeg = tool("ffmpeg"), let ffprobe = tool("ffprobe") else {
            throw Failure("Opening .\(source.pathExtension) files needs ffmpeg. Install it with: brew install ffmpeg")
        }
        let output = try cacheURL(for: source)
        if FileManager.default.fileExists(atPath: output.path) {
            markUsed(output)
            return output
        }

        let info = try await probe(source, with: ffprobe)
        guard info.streams.contains(where: { $0.codec_type == "video" }) else {
            throw Failure("\(source.lastPathComponent) has no video track.")
        }

        let partial = output.deletingPathExtension().appendingPathExtension("partial.mp4")
        try? FileManager.default.removeItem(at: partial)
        try await run(ffmpeg, arguments: arguments(source: source, streams: info.streams, output: partial),
                      duration: Double(info.format.duration ?? "") ?? 0, progress: progress)
        try FileManager.default.moveItem(at: partial, to: output)
        pruneCache()
        return output
    }

    // MARK: - ffmpeg

    private static func arguments(source: URL, streams: [Probe.Stream], output: URL) -> [String] {
        var args = ["-hide_banner", "-nostats", "-loglevel", "error", "-y", "-i", source.path,
                    "-map", "0:v:0", "-map", "0:a", "-map_metadata", "0", "-c:v", "copy"]
        if streams.first(where: { $0.codec_type == "video" })?.codec_name == "hevc" {
            args += ["-tag:v", "hvc1"]  // macOS only plays HEVC in MP4 when tagged hvc1
        }
        for (index, audio) in streams.filter({ $0.codec_type == "audio" }).enumerated() {
            if playableAudio.contains(audio.codec_name ?? "") {
                args += ["-c:a:\(index)", "copy"]
            } else {
                args += ["-c:a:\(index)", "aac", "-b:a:\(index)", "384k"]
            }
        }
        return args + ["-progress", "pipe:1", output.path]
    }

    private static func run(_ executable: URL, arguments: [String], duration: Double,
                            progress: @escaping @MainActor (Double) -> Void) async throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try await withTaskCancellationHandler {
            try process.run()
            // ffmpeg -progress writes key=value lines; out_time_us is the position reached so far.
            for try await line in stdout.fileHandleForReading.bytes.lines where line.hasPrefix("out_time_us=") {
                if duration > 0, let micros = Double(line.dropFirst("out_time_us=".count)) {
                    let fraction = min(max(micros / 1_000_000 / duration, 0), 1)
                    await progress(fraction)
                }
            }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let message = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                throw Failure("ffmpeg could not convert the file.\n\(message.suffix(500))")
            }
        } onCancel: {
            process.terminate()
        }
    }

    private struct Probe: Decodable {
        struct Stream: Decodable { let codec_type: String?; let codec_name: String? }
        struct Format: Decodable { let duration: String? }
        let streams: [Stream]
        let format: Format
    }

    private static func probe(_ source: URL, with ffprobe: URL) async throws -> Probe {
        let process = Process()
        process.executableURL = ffprobe
        process.arguments = ["-v", "error", "-print_format", "json",
                             "-show_entries", "stream=codec_type,codec_name:format=duration", source.path]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = await Task.detached { stdout.fileHandleForReading.readDataToEndOfFile() }.value
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure("ffprobe could not read \(source.lastPathComponent).")
        }
        return try JSONDecoder().decode(Probe.self, from: data)
    }

    /// Apps launched from Finder don't get the shell's PATH, so look in the usual install locations too.
    private static func tool(_ name: String) -> URL? {
        let path = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        return (["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"] + path)
            .map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    // MARK: - Cache

    private static var cacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("io.github.jcsrb.polyglot/Converted", isDirectory: true)
    }

    /// One cache entry per source file version: path, size and modification date.
    private static func cacheURL(for source: URL) throws -> URL {
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        let size = attributes[.size] as? Int ?? 0
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let digest = SHA256.hash(data: Data("\(source.path)|\(size)|\(modified)".utf8))
        let hash = digest.prefix(6).map { String(format: "%02x", $0) }.joined()
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        return cacheDirectory.appendingPathComponent("\(source.deletingPathExtension().lastPathComponent)-\(hash).mp4")
    }

    private static func markUsed(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    private static func pruneCache() {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: keys) else { return }
        let byAge = files.sorted {
            let a = (try? $0.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
            return a > b
        }
        byAge.dropFirst(cacheLimit).forEach { try? FileManager.default.removeItem(at: $0) }
    }
}
