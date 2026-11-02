#!/bin/zsh
# Breaks a hidden test copy of Larynx in each way below, then proves the next dictation lands.
# A cleared error or a live process does not pass. Only a fresh dictation in history passes.
# launchd restarts the test copy, as it does the real app. It has no key tap, no pill, no menu bar
# item and no clipboard, and it uses a temporary home, so you can run this while you dictate.
# It feeds a spoken WAV, not the mic. `larynx recovery` reads the real log for the mic, sleep and wake.
set -uo pipefail
cd "${0:A:h:h}"

[[ -d "$HOME/.larynx/models" ]] || { echo "Run 'larynx models fetch' first."; exit 1; }
swift build -q 2>/dev/null || { echo "The build failed."; exit 1; }

bin=.build/debug/larynx
label=local.larynx.recovery-probe
domain="gui/$(id -u)"
home=$(mktemp -d)
config="$home/config"
export LARYNX_HOME="$home" LARYNX_CONFIG_DIR="$config"
failed=0

mkdir -p "$config" "$home/inflight"
cp larynx.toml words.toml styles.toml "$config/"
ln -s "$HOME/.larynx/models" "$home/models"

stop_job() {
    launchctl bootout "$domain/$label" 2>/dev/null
    for _ in {1..50}; do launchctl print "$domain/$label" >/dev/null 2>&1 || break; sleep 0.1; done
}
trap 'stop_job; rm -rf "$home"' EXIT
stop_job

plist="$home/$label.plist"
cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key><array><string>$PWD/.build/debug/LarynxApp</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>EnvironmentVariables</key><dict>
    <key>LARYNX_DEBUG</key><string>1</string>
    <key>LARYNX_QUIET</key><string>1</string>
    <key>LARYNX_HOME</key><string>$home</string>
    <key>LARYNX_CONFIG_DIR</key><string>$config</string>
  </dict>
  <key>StandardErrorPath</key><string>$home/larynx.log</string>
</dict></plist>
PLIST

pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; failed=1; }
state() { "$bin" debug state 2>/dev/null; }
pid() { state | jq -r '.pid // empty'; }
count() { "$bin" history --json | jq 'if type == "array" then length else (.dictations // .rows | length) end'; }

# Waits for a running, loaded app that is not the process in $1.
ready() {
    local s
    for _ in {1..600}; do
        s=$(state) || true
        if [[ -n "$s" ]] && [[ "$(jq -r .pid <<<"$s")" != "${1:-none}" ]] && [[ "$(jq -r .model_loaded <<<"$s")" == true ]]; then return 0; fi
        sleep 0.1
    done
    return 1
}

# The rule: the next fresh dictation lands in history and leaves no audio behind.
fresh() {
    local r id
    r=$("$bin" debug feed "$wav" 2>&1) || { fail "$1: $r"; return; }
    id=$(jq -r '.dictation.id // empty' <<<"$r" 2>/dev/null)
    if jq -e '.error == null and .inflight_left == false and (.dictation.text_final | test("demo"; "i"))' <<<"$r" >/dev/null 2>&1 \
        && [[ "$("$bin" last --json | jq -r .id)" == "$id" ]]; then pass "$1"; else fail "$1: $r"; fi
}

restart() { local old; old=$(pid); kill -9 "$old"; ready "$old" || fail "launchd did not bring Larynx back"; }
caf_count() { ls "$home/inflight" | grep -c '\.caf$'; }

wav="$home/short.wav"
long="$home/long.wav"
say -o "$wav" --data-format=LEI16@16000 "ask Claude to fix the demo on Friday at three"
say -o "$long" --data-format=LEI16@16000 "this is a long recording that keeps going for a while, so that the app can be killed in the middle of it, and every word said before that moment must come back after the restart"

launchctl bootstrap "$domain" "$plist" || { echo "launchd refused the test job."; exit 1; }
ready || { echo "The test copy did not start. Log:"; tail -5 "$home/larynx.log"; exit 1; }
fresh "start: a plain dictation lands"

# The app dies in the middle of a dictation.
before=$(count); old=$(pid)
"$bin" debug feed "$long" --stream >/dev/null 2>&1 &
sleep 3
kill -9 "$old"; wait 2>/dev/null
if ready "$old"; then pass "crash: launchd starts Larynx again"; else fail "crash: launchd did not start Larynx"; fi
for _ in {1..200}; do [[ $(caf_count) == 0 ]] && break; sleep 0.1; done
if [[ $(count) == $((before + 1)) && $(caf_count) == 0 ]]; then pass "crash: the words so far are recovered into history"
else fail "crash: history $before -> $(count), audio files left $(caf_count)"; fi
fresh "crash: the next dictation lands"

# The main thread stops answering.
old=$(pid)
"$bin" debug hang >/dev/null 2>&1
if ready "$old"; then pass "freeze: the stall guard ends it and launchd starts it again"; else fail "freeze: Larynx did not come back"; fi
if ls "$home"/hang-*.txt >/dev/null 2>&1; then pass "freeze: a sample is written"; else fail "freeze: no sample file"; fi
fresh "freeze: the next dictation lands"

# A damaged audio file waits at launch.
head -c 2048 /dev/urandom > "$home/inflight/junk.caf"
: > "$home/inflight/empty.caf"
restart
fresh "damaged audio: the next dictation lands"
rm -f "$home"/inflight/*.caf

# Settings files turn to garbage, with and without a restart.
for f in larynx.toml words.toml styles.toml; do head -c 4096 /dev/urandom > "$config/$f"; done
fresh "broken settings: the next dictation lands, no restart"
restart
fresh "broken settings: the next dictation lands after a restart"
cp larynx.toml words.toml styles.toml "$config/"

# A typo in the model name.
sed -i '' 's/^model = .*/model = "parakeet-typo"/' "$config/larynx.toml"
restart
fresh "bad model name: the next dictation lands on the default model"
cp larynx.toml "$config/"
restart

# The history database is locked for longer than the 2 s busy timeout, so the save fails.
before=$(count)
{ print "BEGIN EXCLUSIVE;"; sleep 5; print "COMMIT;"; } | sqlite3 "$home/history.db" >/dev/null &
sleep 0.5
r=$("$bin" debug feed "$wav" 2>&1)
if [[ "$r" == *locked* && $(caf_count) == 1 ]]; then pass "locked history: the failure is reported and the audio is kept"
else fail "locked history: $r, audio files left $(caf_count)"; fi
wait 2>/dev/null
fresh "locked history: the next dictation lands"
after=$(count)
restart
for _ in {1..200}; do [[ $(caf_count) == 0 ]] && break; sleep 0.1; done
if [[ $(count) == $((after + 1)) && $(caf_count) == 0 ]]; then pass "locked history: the kept audio reaches history at the next launch"
else fail "locked history: history $after -> $(count), audio files left $(caf_count)"; fi

echo
if [[ $failed == 0 ]]; then echo "all passed"; else echo "some failed"; fi
exit $failed
