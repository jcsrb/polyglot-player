# Polyglot on Windows and Linux

Polyglot is a macOS app, but the idea isn't tied to the Mac: **play every audio track of a video on its own output device, in sync**. Both Windows and Linux have what it takes, and in some ways make it easier.

**Neither port exists yet. If you'd like to build one, please do!** This page has what you need to get started: the platform APIs that map onto Polyglot's design, starting sketches, and how to check that sync works.

> ⚠️ Everything below is a **design sketch, not tested code**. The API names and approach are believed correct, but nobody has run these yet. Expect to fix details, and please send corrections.

## What a port should do

The macOS app sets the bar. A port is feature-complete when it can:

- Open a local video with several audio tracks
- Let the user pick an output for each track: off, system default, or any connected device
- Play all chosen tracks at once, staying in sync with the video and each other
- Pause, seek and resume all tracks together
- Shift each device earlier or later (latency compensation; Bluetooth headphones need ~150–250 ms)
- Ideally: remember which language goes to which device, and each device's latency

**How to test sync:** `scripts/make-test-video.sh` (needs ffmpeg) creates a 60 s clip with three language-tagged tracks. Each beeps once per second at a different pitch, in time with the on-screen timer. Route two tracks to two devices: the beeps should land together and on the timer tick, and stay that way after pausing and seeking.

## Windows

Windows' modern media API, [`Windows.Media.Playback.MediaPlayer`](https://learn.microsoft.com/uwp/api/windows.media.playback.mediaplayer), maps onto Polyglot's design almost one to one, and does the hardest part (sync) for you.

| Polyglot (macOS, AVFoundation) | Windows |
|---|---|
| One `AVPlayer` per audio track | One `MediaPlayer` per audio track |
| `audioOutputDeviceUniqueID` | [`MediaPlayer.AudioDevice`](https://learn.microsoft.com/uwp/api/windows.media.playback.mediaplayer.audiodevice) |
| Host-clock scheduling + drift correction (hand-written) | [`MediaTimelineController`](https://learn.microsoft.com/uwp/api/windows.media.mediatimelinecontroller): attach every player to one controller, and play/pause/seek on the controller |
| Per-device latency offset | [`MediaPlayer.TimelineControllerPositionOffset`](https://learn.microsoft.com/uwp/api/windows.media.playback.mediaplayer.timelinecontrollerpositionoffset) |
| Pick a track with a composition | `MediaPlaybackItem.AudioTracks.SelectedIndex` |
| Device list from CoreAudio | `DeviceInformation.FindAllAsync(MediaDevice.GetAudioRenderSelector())` |
| MKV needs converting to MP4 | **MKV plays natively** on Windows 10 and later |

### Sketch (C#, WinUI 3 or WPF)

```csharp
using Windows.Devices.Enumeration;
using Windows.Media;
using Windows.Media.Core;
using Windows.Media.Devices;
using Windows.Media.Playback;
using Windows.Storage;

var file = await StorageFile.GetFileFromPathAsync(path);
var timeline = new MediaTimelineController();
var outputs = await DeviceInformation.FindAllAsync(MediaDevice.GetAudioRenderSelector());

// Silent video player, shown in a MediaPlayerElement via SetMediaPlayer(video).
var video = new MediaPlayer
{
    Source = MediaSource.CreateFromStorageFile(file),
    IsMuted = true,
    TimelineController = timeline,
};

// One player per routed audio track.
MediaPlayer AudioPlayer(int track, DeviceInformation device, TimeSpan playEarlyBy)
{
    var item = new MediaPlaybackItem(MediaSource.CreateFromStorageFile(file));
    item.AudioTracksChanged += (sender, _) => sender.AudioTracks.SelectedIndex = track;
    return new MediaPlayer
    {
        Source = item,
        AudioDevice = device,
        TimelineController = timeline,
        TimelineControllerPositionOffset = playEarlyBy,  // positive = play ahead of the video
    };
}

var german = AudioPlayer(0, tv, TimeSpan.Zero);
var english = AudioPlayer(1, headphones, TimeSpan.FromMilliseconds(200));

timeline.Start();                          // play
timeline.Pause();                          // pause
timeline.Position = TimeSpan.FromMinutes(42);  // seek
```

### Things to watch out for

- Players attached to a `MediaTimelineController` ignore their own transport controls, so the UI needs its own play/pause/seek bar that drives the controller.
- The audio-only players may still decode video. Check CPU use, and look for a way to disable the video stream on those items.
- Codecs: HEVC needs Microsoft's "HEVC Video Extensions" from the Store, and DTS isn't supported. Check AC-3 support on your Windows edition.
- Packaging: an MSIX package or a plain zip on GitHub Releases are both fine.

## Linux

On Linux with **PipeWire** (the default audio system on most current distributions), you may not need an app at all. PipeWire can route individual channels of one stream to different devices. That means one player, one clock, and no drift:

1. **mpv** merges two language tracks into one 4-channel stream: track 1 on front left/right, track 2 on rear left/right.
2. A **PipeWire combine-stream sink** sends the front pair to the TV and the rear pair to the headphones, optionally compensating each device's latency.

### Sketch: PipeWire virtual sink

Find your devices' sink names with `pw-cli ls Node` or `wpctl status`, then create `~/.config/pipewire/pipewire.conf.d/polyglot.conf`:

```
context.modules = [
  { name = libpipewire-module-combine-stream
    args = {
      combine.mode = sink
      node.name = "polyglot"
      node.description = "Polyglot (TV + headphones)"
      combine.latency-compensate = true
      combine.props = { audio.position = [ FL FR RL RR ] }
      stream.rules = [
        { matches = [ { node.name = "<your TV sink>" } ]
          actions = { create-stream = { combine.audio.position = [ FL FR ] audio.position = [ FL FR ] } } }
        { matches = [ { node.name = "<your headphones sink>" } ]
          actions = { create-stream = { combine.audio.position = [ RL RR ] audio.position = [ FL FR ] } } }
      ]
    }
  }
]
```

Restart PipeWire (`systemctl --user restart pipewire`). See the [combine-stream docs](https://docs.pipewire.org/page_module_combine_stream.html) for the options your version supports.

### Sketch: mpv

```bash
mpv movie.mkv \
  --audio-device=pipewire/polyglot --audio-channels=quad \
  --lavfi-complex='[aid1]aformat=channel_layouts=stereo[a];[aid2]aformat=channel_layouts=stereo[b];[a][b]amerge=inputs=2,pan=quad|FL=c0|FR=c1|BL=c2|BR=c3[ao];[vid1]null[vo]'
```

- `aid1` and `aid2` are the first and second audio tracks; check which is which with `mpv --list-tracks`.
- Each language is downmixed to stereo, so 5.1 tracks work too.
- If `combine.latency-compensate` isn't enough, fine-tune with mpv's `--audio-delay`.
- Routing video through `--lavfi-complex` may disable hardware decoding. If 4K playback stutters, look into mpv's `--hwdec` options.

A small wrapper script (pick tracks by language, write the PipeWire config, launch mpv) would make this a one-liner. That would be a great contribution.

## Cross-platform: GStreamer

If you'd rather build one app for all platforms, [GStreamer](https://gstreamer.freedesktop.org) is the strongest base. Every sink in one pipeline follows a single pipeline clock. It reads MKV and decodes nearly everything (including DTS and TrueHD), handles Blu-ray subtitles, and every sink has a `ts-offset` for latency. The core of Polyglot as a single command on Linux:

```bash
gst-launch-1.0 filesrc location=movie.mkv ! matroskademux name=d \
  d.video_0 ! queue ! decodebin ! videoconvert ! autovideosink \
  d.audio_0 ! queue ! decodebin ! audioconvert ! audioresample ! pulsesink device="<TV sink>" \
  d.audio_1 ! queue ! decodebin ! audioconvert ! audioresample ! pulsesink device="<headphones sink>" ts-offset=-200000000
```

`ts-offset` is in nanoseconds; negative plays that device early. On macOS the sink is `osxaudiosink`, and on Windows `wasapi2sink`, each with a device property. A GStreamer app (Rust with gtk4-rs, or C/Python) could run on all three platforms. The cost: shipping GStreamer with the app, and a less native feel than AVFoundation on the Mac.

## Contributing a port

- **Open an issue first** saying which platform you're taking on, so efforts don't overlap and we can link it from the README.
- A separate repository is fine (e.g. `polyglot-windows`), as is a folder in this one. Either way, **MIT licence** please, to match.
- The same ground rules apply as here: local files only, and no links to copyrighted downloads in issues, docs or screenshots. Use `scripts/make-test-video.sh` for demos.
- Finished ports get a prominent link in the main README.

Even partial results help: a tested Linux recipe, or a corrected Windows sketch, is a good contribution on its own.
