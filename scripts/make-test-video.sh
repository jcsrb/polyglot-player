#!/usr/bin/env bash
# Generate a 60 s test MP4 with three language-tagged audio tracks, for trying out routing and sync.
# Each track beeps once per second at a different pitch (English 440 Hz, German 660 Hz,
# French 880 Hz), in time with the on-screen timer, so drift between devices is easy to hear.
#
# Usage: scripts/make-test-video.sh [output.mp4]
set -euo pipefail

out=${1:-test-3-languages.mp4}
beep() { echo "sine=f=$1:d=60,volume='if(lt(mod(t,1),0.1),1,0)':eval=frame"; }

ffmpeg -hide_banner -v error -y \
  -f lavfi -i "testsrc2=d=60:s=1280x720:r=30" \
  -f lavfi -i "$(beep 440)" -f lavfi -i "$(beep 660)" -f lavfi -i "$(beep 880)" \
  -map 0 -map 1 -map 2 -map 3 -c:v libx264 -pix_fmt yuv420p -c:a aac -ac 2 \
  -metadata:s:a:0 language=eng -metadata:s:a:0 title="English beeps" \
  -metadata:s:a:1 language=deu -metadata:s:a:1 title="German beeps" \
  -metadata:s:a:2 language=fra -metadata:s:a:2 title="French beeps" \
  "$out"
echo "Wrote $out"
