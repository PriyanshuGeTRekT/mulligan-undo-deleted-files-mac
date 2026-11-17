#!/bin/bash
# End-to-end smoke test of the mulligan CLI in a throw-away sandbox (never touches real folders).
set -euo pipefail
M="${1:-.build/debug/mulligan}"
M="$(cd "$(dirname "$M")" && pwd)/$(basename "$M")"; m() { "$M" "$@"; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export MULLIGAN_HOME="$T/support"; mkdir -p "$MULLIGAN_HOME" "$T/work/sub"
W="$(cd "$T/work" && pwd -P)"
printf '{"roots":["%s"],"throttleScale":0,"lowDiskFreeGB":0}' "$W" > "$MULLIGAN_HOME/config.json"
pass() { printf '  \033[32m✓\033[0m %s\n' "$1"; }
die()  { printf '  \033[31m✗ %s\033[0m\n' "$1"; exit 1; }

echo "1. baseline + delete + restore"
echo "my thesis, chapter one" > "$W/a.txt"
dd if=/dev/urandom of="$W/sub/data.bin" bs=1k count=300 2>/dev/null
H1=$(shasum -a 256 "$W/sub/data.bin" | cut -d' ' -f1)
m scan | grep -q "2 files checked, 2 saved" && pass "scan saved 2 files" || die "scan"
rm "$W/a.txt"
sleep 1; m scan | grep -q "1 found deleted" && pass "scan noticed the deletion" || die "delete detection"
m deleted | grep -q "a.txt" && pass "deleted list shows a.txt" || die "deleted list"
m restore "$W/a.txt" | grep -q "restored" && [ "$(cat "$W/a.txt")" = "my thesis, chapter one" ] && pass "restored a.txt byte for byte" || die "restore"

echo "2. run a destructive command, then undo it"
OUT=$(m run --label "overzealous-agent" -- sh -c "rm -rf '$W/sub'; echo 'agent was here' > '$W/a.txt'" 2>&1)
echo "$OUT" | grep -q "deleted   1 file" && pass "run reported the deletion" || { echo "$OUT"; die "run summary (deleted)"; }
echo "$OUT" | grep -q "modified  1 file" && pass "run reported the rewrite" || die "run summary (modified)"
[ ! -e "$W/sub/data.bin" ] && [ "$(cat "$W/a.txt")" = "agent was here" ] && pass "(damage confirmed)" || die "damage not as expected"
m undo-run last --yes | grep -q "restored 2 files" && pass "undo-run restored 2 files" || die "undo-run"
H2=$(shasum -a 256 "$W/sub/data.bin" | cut -d' ' -f1)
[ "$H1" = "$H2" ] && [ "$(cat "$W/a.txt")" = "my thesis, chapter one" ] && pass "everything is back, hashes identical" || die "content mismatch after undo"

echo "3. time travel and history"
m history "$W/a.txt" | grep -q "VERSION" && pass "history lists versions" || die "history"
R=$(m restore "$W/a.txt" --at "1h" 2>&1 || true); echo "$R" | grep -q "nothing was saved" && pass "asking for a time before anything existed is refused politely" || die "--at before history"
mkdir -p "$T/out"; m restore "$W/a.txt" --to "$T/out" | grep -q restored && [ -f "$T/out/a.txt" ] && pass "restore --to writes elsewhere" || die "restore --to"
m find thesis >/dev/null 2>&1 || true
m find "a.txt" | grep -q "a.txt" && pass "find works" || die "find"
m checkpoint "before big refactor" | grep -q "checkpoint #" && pass "checkpoint created" || die "checkpoint"

echo "4. status, doctor, config, agent plist"
m status | grep -q "Protected: 2 files" && pass "status counts" || die "status"
m status --json | python3 -c "import json,sys; d=json.load(sys.stdin); assert d['liveFiles']==2" && pass "status --json is valid JSON" || die "status json"
m doctor | grep -q "APFS" && pass "doctor checks the filesystem" || die "doctor"
m config set keepDeletedDays 7 >/dev/null && m config show | grep -q "keepDeletedDays:    7" && pass "config set/show" || die "config"
m install-agent --print | plutil -lint - >/dev/null && pass "launch agent plist is valid" || die "plist"
m forget "$W/a.txt" --yes | grep -q "erased 1" && pass "forget erases on demand" || die "forget"
R=$(m restore "$W/nonexistent.txt" 2>&1 || true); echo "$R" | grep -q "no saved copy\|no saved\|have no saved" && pass "friendly error for unknown files" || die "error message"
echo "5. the real watcher process vs a real rm -rf"
export MULLIGAN_HOME="$T/support2"; mkdir -p "$MULLIGAN_HOME" "$T/live/proj"
L="$(cd "$T/live" && pwd -P)"
printf '{"roots":["%s"],"throttleScale":0,"lowDiskFreeGB":0,"massDeleteThreshold":20,"notify":false}' "$L" > "$MULLIGAN_HOME/config.json"
for d in 1 2 3 4 5; do mkdir -p "$L/proj/mod$d"; for i in $(seq 1 16); do head -c $((2000 + i * 31)) /dev/urandom > "$L/proj/mod$d/file$i.dat"; done; done
(cd "$L" && find proj -type f | sort | xargs shasum -a 256) > "$T/before.sha"
m watch > "$T/watch.out" 2> "$T/watch.log" &
WPID=$!
for i in $(seq 1 30); do sleep 0.5; [ "$(m status --json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["liveFiles"])' 2>/dev/null)" = "80" ] && break; done
[ "$(m status --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["liveFiles"])')" = "80" ] && pass "watcher saved all 80 files" || { kill $WPID 2>/dev/null; die "baseline"; }
sleep 6   # let the files age past the "short-lived temp file" grace period
rm -rf "$L/proj"
for i in $(seq 1 40); do sleep 0.5; grep -q "just deleted" "$T/watch.log" && break; done
grep -q "just deleted from" "$T/watch.log" && pass "watcher raised the mass-deletion alarm for a real rm -rf" || { cat "$T/watch.log"; kill $WPID 2>/dev/null; die "alarm"; }
grep -o "restore-tree.*--since 10m" "$T/watch.log" | head -1 | sed 's/^/     the alarm tells you exactly what to run: mulligan /'
sleep 2
m restore-tree "$L/proj" --deleted | grep -q "restored 80 files" && pass "restore-tree --deleted brought back 80 files" || die "restore-tree"
kill $WPID 2>/dev/null; wait $WPID 2>/dev/null || true
(cd "$L" && find proj -type f | sort | xargs shasum -a 256) > "$T/after.sha"
diff -q "$T/before.sha" "$T/after.sha" >/dev/null && pass "every one of the 80 files is byte-identical to before" || die "hash mismatch"
echo "ALL CLI CHECKS PASSED"
