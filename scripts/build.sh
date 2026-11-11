#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
# Native Sign in with Apple requires a provisioned Apple Development build.
# Use SOUNDBOUND_SIGNED=0 only for an offline, ad-hoc build without Apple login.
if [[ "${SOUNDBOUND_SIGNED:-1}" == "1" ]]; then
  python3 scripts/generate-ios-project.py
  CONFIGURATION=Debug
  if [[ "${SOUNDBOUND_PRODUCTION:-0}" == "1" ]]; then CONFIGURATION=Release; fi
  xcodebuild -project Apps/macOS/Soundbound.xcodeproj -scheme SoundboundApp \
    -configuration "$CONFIGURATION" -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath .build/mac-signed -allowProvisioningUpdates \
    DEVELOPMENT_TEAM="${SOUNDBOUND_DEVELOPMENT_TEAM:-3QX8AT4S7W}" ONLY_ACTIVE_ARCH=YES build
  mkdir -p dist
  ditto ".build/mac-signed/Build/Products/$CONFIGURATION/Soundbound.app" dist/Soundbound.app
  printf 'Built signed %s\n' "$PWD/dist/Soundbound.app"
  exit 0
fi
# Optimized development builds use a stable local JSON identity. Opt into
# production Keychain storage with SOUNDBOUND_PRODUCTION=1.
IDENTITY_FLAGS=()
if [[ "${SOUNDBOUND_PRODUCTION:-0}" != "1" ]]; then
  IDENTITY_FLAGS=(-Xswiftc -DSOUNDBOUND_DEVELOPMENT)
fi
swift build --disable-sandbox --build-system native -c release "${IDENTITY_FLAGS[@]}"
APP="$PWD/dist/Soundbound.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Sources/SoundboundKit/Resources/SoundboundMark.png "$APP/Contents/Resources/SoundboundMark.png"
cp .build/release/Soundbound "$APP/Contents/MacOS/Soundbound"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>SoundboundAppleSignInConfigured</key><false/>
<key>CFBundleExecutable</key><string>Soundbound</string>
<key>CFBundleIdentifier</key><string>app.soundbound.mac</string>
<key>CFBundleName</key><string>Soundbound</string>
<key>CFBundleDisplayName</key><string>Soundbound</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><false/>
<key>NSLocalNetworkUsageDescription</key><string>Find nearby Soundbound devices and send pairing requests when you turn on Discover.</string>
<key>NSBonjourServices</key><array><string>_soundbound._tcp</string></array>
<key>NSMicrophoneUsageDescription</key><string>Share your microphone with a paired device only after you choose Share microphone and it approves playback.</string>
<key>NSBluetoothAlwaysUsageDescription</key><string>Soundbound connects to the headphones you choose.</string>
<key>NSBluetoothPeripheralUsageDescription</key><string>Soundbound connects to the headphones you choose.</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
python3 - "$APP/Contents/Info.plist" <<'PY'
import plistlib, sys
from pathlib import Path
version, build = Path('VERSION').read_text().split()
path = Path(sys.argv[1])
with path.open('rb') as f:
    info = plistlib.load(f)
info['CFBundleShortVersionString'] = version
info['CFBundleVersion'] = build
with path.open('wb') as f:
    plistlib.dump(info, f)
PY
codesign --force --deep --sign - "$APP"
printf 'Built %s\n' "$APP"
