#!/bin/bash
# Builds LinkedMgr (Release) and installs it to /Applications.
# The background publisher notices the new binary and restarts itself within 30 s.
set -euo pipefail
cd "$(dirname "$0")"

xcodegen generate -q
xcodebuild -project LinkedMgr.xcodeproj -scheme LinkedMgr -configuration Release \
  -derivedDataPath build build -quiet

# Quit the app window if open; the agent is left to restart itself.
osascript -e 'tell application id "com.ideahelix.linkedmgr" to quit' 2>/dev/null || true
rm -rf /Applications/LinkedMgr.app
cp -R build/Build/Products/Release/LinkedMgr.app /Applications/
echo "Installed /Applications/LinkedMgr.app"
open /Applications/LinkedMgr.app
