#!/bin/zsh
# Starts Larynx at login: installs ~/Library/LaunchAgents/<bundle id>.plist pointing at
# the app (dist/Larynx.app, or the path you give), then loads it.
#   scripts/install.sh [path/to/Larynx.app]
set -euo pipefail
app="${1:-${0:A:h:h}/dist/Larynx.app}"
app="${app:A}"
[[ -d "$app" ]] || { echo "Run scripts/build.sh first."; exit 1; }
label=$(plutil -extract CFBundleIdentifier raw "$app/Contents/Info.plist")
plist="$HOME/Library/LaunchAgents/$label.plist"
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/.larynx"
cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key><array><string>$app/Contents/MacOS/Larynx</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardErrorPath</key><string>$HOME/.larynx/larynx.log</string>
</dict></plist>
PLIST
# A link in ~/Applications lets Spotlight find "Larynx" (not needed for an app already in an Applications folder).
if [[ "${app:h:t}" != Applications ]]; then
    mkdir -p "$HOME/Applications"
    ln -sfn "$app" "$HOME/Applications/Larynx.app"
fi
launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
# bootout returns before the job is gone; a bootstrap too soon fails with error 5 and leaves Larynx down.
for _ in {1..50}; do launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1 || break; sleep 0.1; done
launchctl bootstrap "gui/$(id -u)" "$plist"
echo "Installed and loaded: $plist"
echo "Stop it with: launchctl bootout gui/$(id -u)/$label"
