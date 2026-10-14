#!/usr/bin/env bash
# One test/build produces the universal app; no second archive or clean build.
set -euo pipefail
cd "$(dirname "$0")/.."
xcodebuild -version
Scripts/check.sh
Scripts/setup.sh
mkdir -p Artifacts
rm -rf Artifacts/MacDown.xcresult
work=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/macdown-build.XXXXXX")
trap 'rm -rf "$work"' EXIT
xcodebuild test -workspace MacDown.xcworkspace -scheme MacDown \
  -configuration Release -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath "$work/DerivedData" -resultBundlePath "$PWD/Artifacts/MacDown.xcresult" \
  ONLY_ACTIVE_ARCH=NO 'ARCHS=arm64 x86_64' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=''
app="$work/DerivedData/Build/Products/Release/MacDown.app"
# Sign nested executable bundles first, then the app. This local signature
# requires no Apple account and does not claim notarization.
while IFS= read -r -d '' item; do
  codesign --force --sign - "$item"
done < <(find "$app/Contents/Frameworks" -depth \( -name '*.xpc' -o -name '*.app' -o -name '*.framework' \) -print0)
codesign --force --sign - "$app/Contents/SharedSupport/bin/macdown"
codesign --force --sign "${CODESIGN_IDENTITY:--}" "$app"
codesign --verify --deep --strict --verbose=2 "$app"
lipo -verify_arch arm64 x86_64 "$app/Contents/MacOS/MacDown"
python3 Scripts/verify-app.py "$app"
# Replace only this generated app, preserving other artifacts.
rm -rf Artifacts/MacDown.app
ditto "$app" Artifacts/MacDown.app
ditto -c -k --keepParent Artifacts/MacDown.app Artifacts/MacDown-macOS.zip
printf 'Built: %s/Artifacts/MacDown.app\n' "$PWD"
