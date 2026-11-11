#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
PROBE="$PWD/dist/OwnershipProbe.app"
mkdir -p "$PROBE/Contents/MacOS" .build/ModuleCache
xcrun swiftc -module-cache-path "$PWD/.build/ModuleCache" -O Tools/OwnershipProbe.swift -o "$PROBE/Contents/MacOS/OwnershipProbe"
cat > "$PROBE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>OwnershipProbe</string>
<key>CFBundleIdentifier</key><string>app.soundbound.ownership-probe</string>
<key>CFBundleName</key><string>Soundbound Ownership Probe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$PROBE"
printf 'Built %s\n' "$PROBE"
