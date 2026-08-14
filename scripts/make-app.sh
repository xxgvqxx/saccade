#!/bin/bash
# Builds Saccade.app (release) into build/.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP=build/Saccade.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Saccade "$APP/Contents/MacOS/Saccade"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>dev.alexhanvey.saccade</string>
    <key>CFBundleName</key>
    <string>Saccade</string>
    <key>CFBundleExecutable</key>
    <string>Saccade</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSCameraUsageDescription</key>
    <string>Saccade uses the webcam to estimate where on the screen you are looking. Frames are processed locally and never stored or transmitted.</string>
</dict>
</plist>
EOF

# Prefer the stable "Saccade Dev" identity so TCC grants (Accessibility)
# survive rebuilds; fall back to ad-hoc if it is missing/untrusted.
if security find-identity -p codesigning -v | grep -q "Saccade Dev"; then
    codesign --force --sign "Saccade Dev" "$APP"
    echo "Signed with Saccade Dev"
else
    codesign --force --sign - "$APP"
    echo "Signed ad-hoc (Saccade Dev identity not found — TCC grants will not survive rebuilds)"
fi
echo "Built $APP"

# Install to /Applications so Spotlight finds it and no stale copy runs.
pkill -x Saccade 2>/dev/null || true
rm -rf /Applications/Saccade.app
cp -R "$APP" /Applications/Saccade.app
echo "Installed /Applications/Saccade.app"
echo "Run:  open /Applications/Saccade.app"
