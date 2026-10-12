#!/usr/bin/env bash
# Build Polyglot.app (release, ad-hoc signed) into ./build.
# Set UNIVERSAL=1 for an Apple Silicon + Intel binary, VERSION=x.y.z to stamp the version.
set -euo pipefail
cd "$(dirname "$0")/.."

flags=(-c release)
[[ ${UNIVERSAL:-} == 1 ]] && flags+=(--arch arm64 --arch x86_64)
version=${VERSION:-0.1.0}

swift build "${flags[@]}"
app=build/Polyglot.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$(swift build "${flags[@]}" --show-bin-path)/Polyglot" "$app/Contents/MacOS/Polyglot"

# App icon: Resources/AppIcon.png (1024x1024) -> AppIcon.icns
iconset=$(mktemp -d)/AppIcon.iconset
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
  sips -z $size $size Resources/AppIcon.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) Resources/AppIcon.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Polyglot</string>
    <key>CFBundleDisplayName</key><string>Polyglot</string>
    <key>CFBundleIdentifier</key><string>io.github.jcsrb.polyglot</string>
    <key>CFBundleExecutable</key><string>Polyglot</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleShortVersionString</key><string>$version</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Movie</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array><string>public.movie</string></array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key><string>Matroska Video</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>CFBundleTypeExtensions</key>
            <array><string>mkv</string><string>webm</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

codesign --force --sign - "$app"
echo "Built $app"
