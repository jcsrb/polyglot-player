# Polyglot

A small macOS video player that plays several audio tracks of the same video **at the same time, each on its own output device**.

Example: the video and its German audio play on the TV, while the English audio plays on your AirPods, in sync and paused and seeked together.

Typical players (VLC, QuickTime, IINA, mpv) play one audio track at a time, to one device. Polyglot is built for households where people want to watch together in different languages.

## Features

- Pick an output for every audio track: off, system default, or any connected device
- Any number of tracks at once (e.g. three languages on three devices)
- Pause, seek and playback speed apply to all tracks
- Per-device latency compensation (Bluetooth headphones lag ~150–250 ms; defaults to 200 ms for Bluetooth devices)
- Per-track volume; the player's own volume control acts as master volume
- Remembers which language goes to which device, and each device's latency setting

## Requirements

- macOS 14 or later
- Xcode or the Swift toolchain to build
- `ffmpeg` (optional) to repackage MKV files: `brew install ffmpeg`

## Build and run

```bash
swift run Polyglot path/to/video.mp4     # run directly
scripts/build-app.sh                      # or build build/Polyglot.app
open build/Polyglot.app
```

Open a file with ⌘O, by dropping it on the window, or with *Open With → Polyglot* once the app is built. Use the sidebar button in the toolbar to show or hide audio routing.

## File formats

Polyglot plays local files only. It is meant for videos you own or have the rights to watch, such as your own recordings or personal copies of discs you bought.

Polyglot uses Apple's AVFoundation, which plays MP4/MOV files with H.264 or HEVC video and AAC, AC-3, E-AC-3, ALAC or MP3 audio. It cannot open MKV files directly. To repackage one without re-encoding the video:

```bash
scripts/to-mp4.sh movie.mkv     # writes movie.mp4, keeping every audio track and its language
```

Audio formats macOS can't play (DTS, TrueHD, Opus, FLAC) are converted to AAC. Subtitles are not kept.

## How it works

The video plays in a silent `AVPlayer` that acts as the master clock. Each audio track gets its own audio-only `AVPlayer`, routed with `audioOutputDeviceUniqueID`. All players run on the host clock. On play, seek and pause, each audio player is scheduled with `setRate(_:time:atHostTime:)` to start exactly where the video will be, shifted by its device's latency offset. A drift check every 0.5 s resyncs any track that is more than 40 ms off.

Set `POLYGLOT_DEBUG=1` to log the measured drift per track.

To try it without a real movie, `scripts/make-test-video.sh` creates a 60 s clip with three language-tagged tracks that beep once per second at different pitches.

## Limitations

- Bluetooth latency varies by headphones, so tune it with the latency stepper while watching someone speak.
- One file at a time; no playlists or subtitles.
