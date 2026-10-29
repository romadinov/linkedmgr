#!/bin/bash
# Builds a Developer ID-signed, notarized LinkedMgr and publishes it as a GitHub release.
#
#   ./release.sh 1.0.0
#
# One-time setup: xcrun notarytool store-credentials linkedmgr-notary --apple-id <email> --team-id <team>
set -euo pipefail
cd "$(dirname "$0")"

VERSION=${1:?usage: ./release.sh <version, e.g. 1.0.0>}
PROFILE=${NOTARY_PROFILE:-linkedmgr-notary}
OUT=build/release
APP=build/Build/Products/Release/LinkedMgr.app

[[ -z $(git status --porcelain) ]] || { echo "Commit your changes first."; exit 1; }
rm -rf "$OUT" && mkdir -p "$OUT"

xcodegen generate -q
xcodebuild -project LinkedMgr.xcodeproj -scheme LinkedMgr -configuration Release -derivedDataPath build \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$(git rev-list --count HEAD)" \
  CODE_SIGN_IDENTITY="Developer ID Application" build -quiet
codesign --verify --strict --deep "$APP"

echo "Notarizing (usually a few minutes)…"
ditto -c -k --keepParent "$APP" "$OUT/notarize.zip"
xcrun notarytool submit "$OUT/notarize.zip" --keychain-profile "$PROFILE" --wait --output-format json > "$OUT/notary.json"
STATUS=$(plutil -extract status raw -o - "$OUT/notary.json")
if [[ $STATUS != Accepted ]]; then
  echo "Notarization $STATUS:"
  xcrun notarytool log "$(plutil -extract id raw -o - "$OUT/notary.json")" --keychain-profile "$PROFILE"
  exit 1
fi
xcrun stapler staple "$APP"
spctl --assess --type execute -vv "$APP"
ditto -c -k --keepParent "$APP" "$OUT/LinkedMgr-$VERSION.zip"

cat > "$OUT/notes.md" <<EOF
**Install:** download \`LinkedMgr-$VERSION.zip\`, unzip, move **LinkedMgr** to /Applications and open it.
Then follow the [setup steps](https://github.com/romadinov/linkedmgr#setup-step-by-step) (LinkedIn developer app,
Connect, turn on the background publisher).

Requires macOS 15 or later. Signed with Developer ID and notarized by Apple.
EOF

git tag -a "v$VERSION" -m "LinkedMgr $VERSION"
git push origin "v$VERSION"
gh release create "v$VERSION" "$OUT/LinkedMgr-$VERSION.zip" --title "LinkedMgr $VERSION" \
  --notes-file "$OUT/notes.md" --generate-notes
