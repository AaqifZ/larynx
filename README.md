# Larynx

Private dictation for macOS: hold fn, talk, and let go. The text lands in the text box you are in.

<!-- Demo GIF slot (10 seconds): add packaging/demo.gif, then replace this comment with ![Larynx demo](packaging/demo.gif) -->

Paste this to your coding agent:

```text
Download Larynx from GitHub at this exact version, read the code, build it, and set it up: https://github.com/AaqifZ/larynx/tree/PINNED_COMMIT
```

<!-- Proof numbers slot: refresh these on launch day, and show only measured numbers. -->

Speech becomes text on your Mac with NVIDIA Parakeet, run on the Apple Neural Engine by FluidAudio. No audio or text goes to a server.

There are two parts: the menu bar app (`Larynx.app`) and the command line tool (`larynx`).

The mic stays open for 5 minutes after a dictation by default, so the next dictation keeps its first word. The orange mic dot shows during that time. Larynx keeps only the last 0.5 seconds in memory and writes nothing to disk until you press the key. Set `warm_mic_minutes = 0` in `~/.larynx/larynx.toml` to close the mic after each dictation.

## Install

You need an Apple Silicon Mac with macOS 14 or later and the Xcode command line tools (`xcode-select --install`). Larynx is tested on macOS 26.7 on one M4 Mac. macOS 14 and 15 are untested.

1. Get the source at the commit in the prompt above, and go to that folder.
2. Run `./scripts/build.sh`. The first build takes about 6 minutes. A WARNING about ad-hoc signing is normal.
3. Run `dist/larynx models fetch`. It downloads about 480 MB, one time, from Hugging Face.
4. Run `./scripts/install.sh`. Larynx starts now and at each login.

A person must do these steps. No script or agent can do them.

1. Open System Settings, Privacy & Security, Accessibility. Turn on Larynx.
2. Open Privacy & Security, Input Monitoring. Turn on Larynx.
3. Hold fn and say a sentence. Click Allow for the microphone.
4. Hold fn, talk, and release fn. The text goes into the text box.

If fn opens the emoji picker, open System Settings, Keyboard, and set "Press 🌐 key to" to "Do Nothing". If fn does nothing, quit Larynx from its menu and open it again.

After a rebuild, macOS asks for the permissions again. To keep them, set a signing identity: see [CONTRIBUTING.md](CONTRIBUTING.md).

### Uninstall

1. Run `launchctl bootout gui/$(id -u)/local.larynx` to stop Larynx.
2. Delete this folder, `~/Applications/Larynx.app` and `~/Library/LaunchAgents/local.larynx.plist`.
3. Delete `~/.larynx` to remove your history, settings and the speech model.

## Use the app

- Hold fn and talk. Release fn to stop. The text goes into the text box.
- Tap fn two times to talk hands-free. Tap fn one more time to stop.
- Press fn and control together to talk hands-free. Press fn again to stop.
- On a keyboard with no fn key, tap control and shift together (press, then release). Do the same again to stop.
- Hold fn and shift to get raw text.
- If no text box has focus, the text stays on the clipboard. Press Cmd+V to paste it.
- Larynx saves each dictation in history before it pastes.

## The speech model

`larynx models fetch` is the only command that uses the network. It downloads each model at a fixed Hugging Face commit. It then checks the sha256 of every file against `models.sha256`. If one file differs, the command deletes the new download and stops with an error.

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

Larynx keeps history in `~/.larynx/history.db`. It deletes rows older than 30 days. The `larynx` tool uses the folder in `LARYNX_HOME` if you set it. The app ignores `LARYNX_HOME`.

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

## Test recovery

Larynx counts a failure as recovered only when the next dictation lands.

1. Run `scripts/recovery.sh`. It breaks a hidden test copy of Larynx in 6 ways, then feeds it a new dictation. You can dictate while it runs.
2. Run `larynx recovery` to read your own `larynx.log`. For each restart, freeze, mic error, sleep and mic change, it shows if the next recording landed. Add `--since 2026-11-01` to skip older lines.

## Contribute

Read [CONTRIBUTING.md](CONTRIBUTING.md) to protect a signing key, run the tests, and test the app with no microphone. Read [SECURITY.md](SECURITY.md) to report a security problem. Read [CHANGELOG.md](CHANGELOG.md) for the changes in each release.
