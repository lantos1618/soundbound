#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
if [[ "${SOUNDBOUND_SIGNED:-1}" != "1" ]]; then
  echo "Matched Mac/iPhone builds require signing." >&2
  exit 1
fi
configuration=Debug
if [[ "${SOUNDBOUND_PRODUCTION:-0}" == "1" ]]; then configuration=Release; fi
bash scripts/build.sh > .build/mac-build.log 2>&1
xcodebuild -project Apps/iOS/Soundbound.xcodeproj -scheme SoundboundApp \
  -configuration "$configuration" -destination 'generic/platform=iOS' \
  -derivedDataPath .build/iphone -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="${SOUNDBOUND_DEVELOPMENT_TEAM:-3QX8AT4S7W}" build > .build/iphone-build.log 2>&1
python3 - "$configuration" <<'PY'
import json, plistlib, sys
from pathlib import Path
version, build = Path('VERSION').read_text().split()
bundles = {
    'macOS': Path('dist/Soundbound.app/Contents/Info.plist'),
    'iOS': Path(f'.build/iphone/Build/Products/{sys.argv[1]}-iphoneos/Soundbound.app/Info.plist'),
}
for platform, path in bundles.items():
    with path.open('rb') as f:
        info = plistlib.load(f)
    if (info.get('CFBundleShortVersionString'), info.get('CFBundleVersion')) != (version, build):
        raise SystemExit(f'{platform} version mismatch: rebuild both apps from the same VERSION file')
Path('.build/matched-build.json').write_text(json.dumps({'version': version, 'build': build, 'platforms': list(bundles)}, indent=2) + '\n')
print(f'Matched macOS + iOS build: {version} ({build})')
PY
