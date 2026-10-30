#!/bin/zsh
# Builds dist/Larynx.app (menu bar app) and dist/larynx (CLI), then signs the app.
# Signing: set LARYNX_SIGN_IDENTITY to a code-signing identity in your keychain so
# permission grants survive rebuilds. Without it, the app is signed ad-hoc.
# Make the identity's private key ask before each use (docs/signing.md).
# local/build.env, if present, sets LARYNX_SIGN_IDENTITY and LARYNX_BUNDLE_ID (git ignores local/).
set -euo pipefail
cd "${0:A:h:h}"
[[ -f local/build.env ]] && source local/build.env
bundle_id="${LARYNX_BUNDLE_ID:-local.larynx}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
swift build -c release --disable-sandbox --product LarynxApp
swift build -c release --disable-sandbox --product larynx

app_path="$PWD/dist/Larynx.app"
rm -rf "$app_path"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp .build/release/LarynxApp "$app_path/Contents/MacOS/Larynx"
cp packaging/Info.plist "$app_path/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string "$bundle_id" "$app_path/Contents/Info.plist"
cp packaging/AppIcon.icns "$app_path/Contents/Resources/AppIcon.icns"
# FluidAudio resource bundles, if the build made any.
for b in .build/release/*.bundle(N); do cp -R "$b" "$app_path/Contents/Resources/"; done
cp .build/release/larynx dist/larynx

identity="${LARYNX_SIGN_IDENTITY:-}"
# Self-signed, so it is not "valid" (-v) to the trust system: look it up without -v.
if [[ -n "$identity" ]] && security find-identity -p codesigning | grep -q "\"$identity\""; then
    codesign --force --options runtime --entitlements packaging/Larynx.entitlements --sign "$identity" --identifier "$bundle_id" "$app_path"
    signed_with="$identity"
else
    codesign --force --options runtime --entitlements packaging/Larynx.entitlements --sign - --identifier "$bundle_id" "$app_path"
    signed_with="ad-hoc"
    echo "WARNING: no LARYNX_SIGN_IDENTITY in the keychain, so Larynx.app is signed ad-hoc."
    echo "WARNING: macOS permissions (Microphone, Input Monitoring, Accessibility) will NOT survive a rebuild."
fi
codesign --verify --strict "$app_path"
echo "Built: $app_path (signed: $signed_with)"
codesign -d -r- "$app_path" 2>&1 | grep designated || true
