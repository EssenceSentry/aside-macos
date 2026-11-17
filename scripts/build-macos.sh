#!/bin/bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"
npm run build
swift build --package-path native -c release --product Aside
BIN_DIR="$(swift build --package-path native -c release --show-bin-path)"
APP="$REPO_ROOT/build/Aside.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/web"
cp "$BIN_DIR/Aside" "$APP/Contents/MacOS/Aside"
rsync -a --delete dist/ "$APP/Contents/Resources/web/"
cp scripts/narration_backend.py "$APP/Contents/Resources/narration_backend.py"
for resource in "$BIN_DIR"/*.bundle; do
  if [ -d "$resource" ]; then cp -R "$resource" "$APP/Contents/Resources/"; fi
done
swift scripts/create-icon.swift build/Aside.iconset
iconutil -c icns build/Aside.iconset -o "$APP/Contents/Resources/Aside.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Aside</string>
<key>CFBundleDisplayName</key><string>Aside</string>
<key>CFBundleIdentifier</key><string>local.aside.meeting</string>
<key>CFBundleExecutable</key><string>Aside</string>
<key>CFBundleIconFile</key><string>Aside.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSMicrophoneUsageDescription</key><string>Aside records your microphone only when you start a meeting. Audio and speech recognition stay on this Mac.</string>
<key>NSScreenCaptureUsageDescription</key><string>Aside captures meeting audio from other apps when system audio is enabled. It does not save screen video.</string>
<key>NSAudioCaptureUsageDescription</key><string>Aside captures meeting audio from other apps when you start recording with system audio enabled.</string>
</dict></plist>
PLIST
codesign --force --deep --sign - "$APP"
printf 'Built %s\n' "$APP"
