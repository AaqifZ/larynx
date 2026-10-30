#!/bin/sh
# Runs the self-test, then pipes every command's --json output to jq.
# Uses a temporary LARYNX_HOME, so your history is untouched. The transcribe check
# writes to the clipboard; the clipboard's text is saved first and put back at the end.
set -eu
cd "$(dirname "$0")/.."

swift build -q
swift run -q LarynxSelfTest

home=$(mktemp -d)
pbpaste > "$home/clipboard.saved" 2>/dev/null || true
trap 'pbcopy < "$home/clipboard.saved"; rm -rf "$home"' EXIT
export LARYNX_HOME="$home"
if [ -d "$HOME/.larynx/models" ]; then ln -s "$HOME/.larynx/models" "$home/models"; fi

bin=.build/debug/larynx
wav="$home/check.wav"
say -o "$wav" --data-format=LEI16@16000 "ask Claude to fix the demo on Friday at three"

echo
fail=0
check() {
    if "$bin" "$@" --json 2>/dev/null | jq . >/dev/null; then echo "PASS  json: larynx $*"; else echo "FAIL  json: larynx $*"; fail=1; fi
}
check help
check status
check last
check history
check debug state   # app not running in the test: still a JSON error
check stats
check words
check clean "Um, so ask clawed to fix the demo." --app com.tinyspeck.slackmacgap

# words add writes to a copy of words.toml, never the repo's own file.
cfg="$home/config"; mkdir -p "$cfg"; cp words.toml styles.toml "$cfg/"
if LARYNX_CONFIG_DIR="$cfg" "$bin" words add Zorblax --sounds-like "zorblacks" --json | jq . >/dev/null; then
    echo "PASS  json: larynx words add (on a copy)"; else echo "FAIL  json: larynx words add"; fail=1; fi
got=$(LARYNX_CONFIG_DIR="$cfg" "$bin" clean "ask zorblacks" --app dev.zed.Zed)
if [ "$got" = "ask Zorblax" ]; then echo "PASS  words add: the next clean uses the new word"; else echo "FAIL  words add: got '$got'"; fail=1; fi
got=$("$bin" clean "the cat clawed the sofa" --app dev.zed.Zed)
if [ "$got" = "the cat clawed the sofa" ]; then echo "PASS  clean: the cat clawed the sofa stays"; else echo "FAIL  clean: got '$got'"; fail=1; fi
if [ -L "$home/models" ]; then
    check transcribe "$wav"
    if "$bin" last --json | jq -e '.cleanup == "rules" and (.clean_ms | type == "number") and (.transcribe_ms | type == "number")' >/dev/null; then
        echo "PASS  last: cleanup rules with transcribe_ms and clean_ms"; else echo "FAIL  last: cleanup or timings missing"; fail=1; fi
    check transcribe "$wav" --raw
    if "$bin" last --json | jq -e '.cleanup == "none" and .text_final == .text_raw and .clean_ms == null' >/dev/null; then
        echo "PASS  transcribe --raw: cleanup none, text_final = text_raw"; else echo "FAIL  transcribe --raw"; fail=1; fi
    check stats
    check models fetch   # models are present, so this does not download
    check last
    check history
else
    echo "SKIP  transcribe and models fetch: run 'larynx models fetch' first"
fi
exit $fail
