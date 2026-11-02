# Changelog

## Unreleased

- A wrong model name in `larynx.toml` no longer stops dictation. Larynx shows the error and uses the default model.
- Add `scripts/recovery.sh`, which breaks a test copy in 6 ways and proves the next dictation lands.
- Add `larynx recovery`, which shows from your log whether the next recording landed after each failure.
- Install through a coding agent: it builds Larynx from the source at one commit.
- The app asks one time to download the speech model if it is missing, and runs the `larynx` tool inside the app for the download.
- The app turns off the download paths in the speech library.
- `larynx models fetch` uses a pinned commit and checks the SHA-256 of each file.
- The release app ignores the debug environment variables.
