# Contributing

Build Larynx first: see [README.md](README.md). `swift build` makes a debug build at `.build/debug/larynx`.

Set `LARYNX_SIGN_IDENTITY` to the name of a code-signing identity in your keychain. Then `scripts/build.sh` signs with it, and macOS keeps the permissions after a rebuild. If the identity is missing, the script signs ad-hoc and prints a WARNING. You can put `LARYNX_SIGN_IDENTITY` and `LARYNX_BUNDLE_ID` (default `local.larynx`) in `local/build.env`.

## Protect the signing key

Any process that can sign with the identity can make a binary that macOS treats as Larynx. That binary gets the permissions of Larynx with no prompt. Make the private key ask before each use:

1. Open Keychain Access. Select the **login** keychain, then the **Keys** tab.
2. Double-click the private key of the identity. Select the **Access Control** tab.
3. Select **Confirm before allowing access**.
4. Remove each application from the list "Always allow access by these applications".
5. Select **Save Changes**.

Each build then shows one prompt. Select **Allow** only for a build that you started. Do not select **Always Allow**.

For more protection, keep the identity in a separate keychain. Unlock it with `security unlock-keychain` before a build, and lock it with `security lock-keychain` after the build.

## Test

1. Run `./scripts/test.sh`.
2. Make sure that each line starts with `PASS`.

The test uses a temporary history. The test saves the clipboard text and puts it back at the end.

## Test the app without a microphone

1. Quit the normal Larynx. Two copies both listen to fn.
2. Build the debug app: `swift build --product LarynxApp`. The release app in `dist/` ignores the debug variables.
3. Start the debug app with a short temporary home (socket paths have a length limit): `LARYNX_DEBUG=1 LARYNX_HOME=~/.lxp .build/debug/LarynxApp &`. Link `~/.larynx/models` into it.
4. Run `LARYNX_HOME=~/.lxp dist/larynx debug feed <file.wav>`. Add `--app <bundle id>` to test a style. Add `--paste` to post Cmd+V.
5. Read the JSON reply. It shows the text, `landed`, the style and the times.
6. Stop the debug app. Start the normal app: `open dist/Larynx.app`.

Debug mode opens a local socket, `~/.larynx/debug.sock`. It is not a network port. Add `--stream` to feed the audio at real speed. Use it to test a crash with `kill -9`.
