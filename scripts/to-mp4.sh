#!/usr/bin/env bash
# Repackage a video (e.g. MKV) as MP4 so macOS / Polyglot can play it, keeping every audio track.
#
# The video stream is copied, not re-encoded. Audio tracks are copied when macOS can play them
# (AAC, AC-3, E-AC-3, ALAC, MP3) and converted to AAC otherwise (e.g. DTS, TrueHD, Opus).
# Language tags and track titles are kept. Subtitles are dropped.
#
# Usage: scripts/to-mp4.sh input.mkv [output.mp4]
set -euo pipefail

in=${1:?usage: scripts/to-mp4.sh input.mkv [output.mp4]}
out=${2:-"${in%.*}.mp4"}
[[ $out == "$in" ]] && out="${in%.*}.polyglot.mp4"

probe() { ffprobe -v error -select_streams "$1" -show_entries stream=codec_name -of csv=p=0 "$in"; }

vcodec=$(probe v:0)
args=(-map 0:v:0 -map 0:a -map_metadata 0 -c:v copy)
case $vcodec in
  hevc) args+=(-tag:v hvc1) ;;  # macOS only plays HEVC in MP4 when tagged hvc1
  h264) ;;
  *) echo "warning: video codec '$vcodec' may not play on macOS; re-encode with -c:v libx264 if it doesn't" >&2 ;;
esac

i=0
while read -r codec; do
  case $codec in
    aac | ac3 | eac3 | alac | mp3) args+=("-c:a:$i" copy) ;;
    *) args+=("-c:a:$i" aac "-b:a:$i" 384k) ;;
  esac
  i=$((i + 1))
done < <(probe a)

ffmpeg -hide_banner -i "$in" "${args[@]}" -movflags +faststart "$out"
echo "Wrote $out"
