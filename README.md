# Larynx

Larynx is a private dictation tool for macOS. Hold fn, talk, and let go: the text lands in the text box you are in. Speech becomes text on your Mac with NVIDIA Parakeet, run on the Apple Neural Engine by FluidAudio. No audio or text goes to a server.

There are two parts: the menu bar app (`Larynx.app`) and the command line tool (`larynx`).

## Requirements

- An Apple Silicon Mac with macOS 14 or later.
- The Swift command line tools (Swift 5.9 or later).

## Build

1. Open a terminal in this folder.
2. Run `swift build`.
3. Find the tool at `.build/debug/larynx`.

## Build the app

1. Run `./scripts/build.sh`.
2. Find the app at `dist/Larynx.app` and the tool at `dist/larynx`.
3. Read the last line of the output. It shows the signing identity.

Set `LARYNX_SIGN_IDENTITY` to the name of a code-signing identity in your keychain. Then the script signs with it, and macOS keeps the permissions after a rebuild. If the identity is missing, the script signs ad-hoc and prints a WARNING. Then you must allow the permissions again after each rebuild.

You can put `LARYNX_SIGN_IDENTITY` and `LARYNX_BUNDLE_ID` (default `local.larynx`) in `local/build.env`. Both scripts read that file.

### Protect the signing key

Any process that can sign with the identity can make a binary that macOS treats as Larynx. That binary gets the permissions of Larynx with no prompt. Make the private key ask before each use:

1. Open Keychain Access. Select the **login** keychain, then the **Keys** tab.
2. Double-click the private key of the identity. Select the **Access Control** tab.
3. Select **Confirm before allowing access**.
4. Remove each application from the list "Always allow access by these applications".
5. Select **Save Changes**.

Each build then shows one prompt. Select **Allow** only for a build that you started. Do not select **Always Allow**.

For more protection, keep the identity in a separate keychain. Unlock it with `security unlock-keychain` before a build, and lock it with `security lock-keychain` after the build.

## Allow the permissions

Do this one time, in System Settings, Privacy & Security.

1. Open `dist/Larynx.app`.
2. Add Larynx to Input Monitoring. Larynx uses it to see the fn key.
3. Add Larynx to Accessibility. Larynx uses it to find the text box and to send one Cmd+V.
4. Hold fn one time. Click Allow for the microphone.
5. Quit Larynx from its menu, then open it again.

## Start Larynx at login

1. Run `./scripts/install.sh`.
2. To stop it, run `launchctl bootout gui/$(id -u)/local.larynx`.

## Use the app

- Hold fn and talk. Release fn to stop. The text goes into the text box.
- Tap fn two times to talk hands-free. Tap fn one more time to stop.
- Press fn and control together to talk hands-free. Press fn again to stop.
- On a keyboard with no fn key, tap control and shift together (press, then release). Do the same again to stop.
- Hold fn and shift to get raw text.
- If no text box has focus, the text stays on the clipboard. Press Cmd+V to paste it.
- Larynx saves each dictation in history before it pastes.

## Get the speech model

Do this one time. This is the only command that uses the network.

1. Run `.build/debug/larynx models fetch`.
2. Wait for the download to finish. It is about 480 MB.
3. Find the model in `~/.larynx/models/`.

The command downloads each model at a fixed Hugging Face commit. It then checks the sha256 of every file against `models.sha256`. If one file differs, the command deletes the new download and stops with an error.

To check the model files again later, run `larynx models verify`. This command does not use the network.

## Run

- Run `larynx transcribe <audio-file>` to change speech to text. Larynx saves the text in history first. Then it puts the text on the clipboard.
- Run `larynx last` to show the last dictation.
- Run `larynx history` to show the last 30 days.
- Run `larynx status` to show the model, the files and the counts.
- Run `larynx clean "<text>" --app <bundle id>` to test the cleanup rules on text. Nothing is saved.
- Run `larynx words add <Word> --sounds-like "<a>" "<b>"` to add a word to `words.toml`.
- Run `larynx stats` to show the median and p95 times for today and the last 7 days.
- Add `--json` to any command to get JSON.

Larynx keeps history in `~/.larynx/history.db`. It deletes rows older than 30 days. Set `LARYNX_HOME` to use a different folder.

## Change a setting

Your settings are in `~/.larynx/`: `larynx.toml`, `words.toml` and `styles.toml`. On the first run, Larynx copies the defaults from this folder into `~/.larynx/`. It never replaces a file that is already there, so a `git pull` does not change your settings. Larynx skips a `words.toml` entry that holds a control character, such as `\n` or `\t`, and writes the entry to `~/.larynx/larynx.log`.

Larynx reads `words.toml` and `styles.toml` again at the next dictation after you save them. You do not restart Larynx.

The cleanup uses rules only. It removes fillers (um, uh, erm, hmm), fixes the spellings in `words.toml`, and applies the style for the front app from `styles.toml`. Hold fn and shift to skip the cleanup.

1. Open `~/.larynx/larynx.toml`.
2. Change the line you need. For example, set `model = "parakeet-ultra"`.
3. Run `larynx models fetch` if you changed the model.

To keep your settings in this folder instead (for development):

1. Make a folder named `local` in this folder.
2. Copy `larynx.toml`, `words.toml` and `styles.toml` into `local/`.
3. Edit the copies. Larynx reads `local/` in place of `~/.larynx/` when `local/` holds a `larynx.toml`. Git ignores `local/`.

By default the mic stays open for 5 minutes after a dictation, so the next dictation keeps its first word. The orange mic dot shows during that time. Set `warm_mic_minutes = 0` in `larynx.toml` to close the mic after each dictation.

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
6. Stop the debug app. Start the normal app from a clean environment: `env -u LARYNX_HOME -u LARYNX_CONFIG_DIR open dist/Larynx.app`.

WARNING: Clear `LARYNX_HOME` and `LARYNX_CONFIG_DIR` before you use `open`. `open` gives your shell environment to the app, and the app then writes to the wrong folder.

Debug mode opens a local socket, `~/.larynx/debug.sock`. It is not a network port. Add `--stream` to feed the audio at real speed. Use it to test a crash with `kill -9`.
