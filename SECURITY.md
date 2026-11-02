# Security

## Report a problem

Use **Report a vulnerability** on the Security tab of this repository. Do not open a public issue for a security problem.

## What Larynx does

- The app makes no network connection. It links FluidAudio, which holds download code, but the app calls only the disk loader and turns FluidAudio's download paths off at start. The `larynx` tool does the download.
- If the speech model is missing, the app asks you. If you agree, it runs the `larynx` tool to download the model.
- `larynx models fetch` is the only command that uses the network. It downloads the speech model from Hugging Face. It sends no audio and no text.
- The download uses a pinned Hub commit, and the tool checks the SHA-256 of each file (`models.sha256`). Run `larynx models verify` to check the files again.
- The app needs Accessibility, Input Monitoring and the Microphone. It uses Accessibility to find the text box and to send one Cmd+V. Input Monitoring lets the app see every key press and mouse click. The app acts on fn, Esc and control with shift, and it keeps no key text.
- Larynx keeps dictation text in `~/.larynx/history.db` for 30 days. It removes older rows each time the history opens, so a Larynx that runs for weeks can keep them longer. Daily totals and app names stay with no time limit. The folder is private to your user (mode 0700).
- Larynx keeps a recording when the mic sounds silent, for 30 days, in `~/.larynx/silent/`. If a transcription fails, the audio stays in `~/.larynx/inflight/` until a later run recovers it. Larynx deletes other audio after the text is in history.

## What to check before you install

- Read the code at the commit in the install prompt. A commit SHA cannot move.
- The app is signed ad-hoc on your Mac and is not notarized by Apple.
