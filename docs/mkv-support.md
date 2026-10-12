# MKV support: notes for later

Status: **parked**. For now, MKV files are repackaged as MP4 with `scripts/to-mp4.sh` (a stream copy, ~3 s for a 2 GB film).

AVFoundation has no Matroska demuxer. On macOS 26, `AVURLAsset` on an `.mkv` fails with `AVFoundationErrorDomain -11828` "This media format is not supported". The codecs usually inside MKV files (H.264/HEVC video, AAC/AC-3/E-AC-3 audio) are ones AVFoundation decodes fine. Only the container is the problem.

## Options considered

| Option | Effort | Notes |
|---|---|---|
| A. Auto-remux on open (ffmpeg → cached MP4) | small | Same as `to-mp4.sh`, run by the app. Needs ffmpeg installed and disk space for the cache. Easiest path if we want "just open the MKV". |
| B. MediaExtension format reader (below) | large | Native MKV in AVFoundation, no copy, no ffmpeg. The "hardcore" route. |
| C. Switch engine to libVLC / libmpv | large | Plays everything, but no host-time scheduling (`setRate(_:time:atHostTime:)`), so multi-device sync gets worse. Rejected. |

## Option B: an MKV MediaExtension format reader

Since macOS 15, the [MediaExtension](https://developer.apple.com/documentation/mediaextension) framework lets an app ship **format reader** extensions that teach Media Toolbox (and so AVFoundation, `AVPlayer`, QuickTime Player) to read new container formats. With an MKV reader, Polyglot would open `.mkv` with the `AVURLAsset` code it already has.

### How it fits together

- The reader is an **ExtensionKit app extension** inside the host app (`Polyglot.app/Contents/Extensions/…`), not a library linked into the player.
- The system instantiates it, never the app directly. Media Toolbox makes an `MEByteSource` for the file, creates the extension's `MEFormatReaderExtension`, and calls `formatReader(with:options:)` ([docs](https://developer.apple.com/documentation/mediaextension/meformatreader)).
- The user must enable it once in **System Settings → General → Login Items & Extensions → Media Extensions**.
- Client apps must explicitly opt in to using media extensions. *To verify:* the opt-in call. Likely `MTRegisterProfessionalVideoWorkflowFormatReaders()` from MediaToolbox at launch.
- Building one needs the format-reader entitlement, a provisioning profile, and a specific Info.plist dictionary declaring the file types/extensions ([docs](https://developer.apple.com/documentation/mediaextension/format-reader-property-list-dictionaries)). That means moving from SwiftPM-only to an **Xcode project** with an app + extension target, and a real signing identity (ad-hoc probably won't do).

### What we'd implement (protocol → MKV concept)

| MediaExtension | Job | Matroska source |
|---|---|---|
| `MEFormatReaderExtension` | factory, checks the file looks like MKV | EBML header, DocType `matroska` / `webm` |
| `MEFormatReader` | file-level: duration, list of tracks, metadata | `Segment` → `Info` (Duration, TimestampScale), `Tracks` |
| `METrackReader` | per track: media type, `CMFormatDescription`, language, enabled | `TrackEntry`: CodecID, CodecPrivate, Language, Name, FlagDefault/FlagForced |
| `MESampleCursor` | step through samples, seek, give sample timing and byte location | `Cluster` / `SimpleBlock` / `BlockGroup` timestamps; `Cues` for seeking |

Format descriptions from `CodecPrivate`:
- **HEVC** (`V_MPEGH/ISO/HEVC`): CodecPrivate is an `hvcC` record, so `CMVideoFormatDescriptionCreate` with the `hvcC` atom in the extensions dictionary.
- **H.264** (`V_MPEG4/ISO/AVC`): CodecPrivate is `avcC`, same approach.
- **AAC** (`A_AAC`): CodecPrivate is the AudioSpecificConfig, which becomes the magic cookie.
- **AC-3 / E-AC-3** (`A_AC3`, `A_EAC3`): no CodecPrivate; sample rate and channels come from `TrackEntry.Audio`, or from parsing the first syncframe.

### Hard parts / risks

- **Sample location.** Cursors report where each sample's bytes are. MKV *lacing* (several frames in one block, mostly audio) and header stripping (`ContentCompression` with algo 3) mean samples aren't always one contiguous byte range. The cursor may have to hand back loaded sample buffers instead of byte ranges for those.
- **Seeking and sync samples.** Keyframe flags and `Cues` are needed so `AVPlayer` can seek. Files without `Cues` need a scan of all clusters on open.
- **Decode order vs presentation order.** HEVC with B-frames: Matroska stores presentation timestamps, and decode timestamps have to be reconstructed. Apple's forums have threads about getting GOP sample vending right ([example](https://developer.apple.com/forums/thread/760765)).
- **Subtitles.** PGS (Blu-ray) and VobSub (DVD) are bitmaps that AVFoundation can't render, even if the reader exposes them as tracks. They'd need a separate rendering path in Polyglot. Text subtitles (SRT/ASS) could map to `kCMMediaType_Subtitle` / `mov_text`.
- **Distribution.** Extension + entitlement + user toggle is a lot of setup for a small personal tool.

### Prior art to read first

- [GMPlayer](https://gitblind.noratr.app/gastonmorixe/GMPlayer): an AVFoundation player that demuxes MKV itself and feeds AVFoundation through a local loopback HTTP server (HLS), falling back to a temporary MP4 remux. A middle ground between options A and B, without the extension setup. Licence not checked.
- Apple: [MediaExtension](https://developer.apple.com/documentation/mediaextension), [MEFormatReader](https://developer.apple.com/documentation/mediaextension/meformatreader), [MEFormatReaderExtension](https://developer.apple.com/documentation/mediaextension/meformatreaderextension).
- Matroska spec: [matroska.org/technical/elements.html](https://www.matroska.org/technical/elements.html) (EBML element IDs, block structure, lacing).

### Suggested first spike

1. Xcode project: Polyglot app + format reader extension target. Get the extension to appear in System Settings.
2. Reader that handles only: one HEVC video + AC-3 audio tracks, `SimpleBlock` without lacing, `Cues` present (true for most remuxed disc rips).
3. Success = `AVURLAsset(url: mkv)` reports `isPlayable == true` and plays in Polyglot. Then widen codec and lacing support.
