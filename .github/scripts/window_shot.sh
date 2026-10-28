#!/usr/bin/env bash
# Opens the setup window in a real browser engine on the Mac runner and saves
# what a member would see: the page with START_HERE.md unwritten, and again
# after a scripted /setup and /organize. Chrome headless renders the page,
# runs app.js and its /api/state polling against the live server.
#
#   window_shot.sh <vault> <out_dir>

set -uo pipefail
VAULT="$1"; OUT="$2"; mkdir -p "$OUT"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
PY=/usr/bin/python3
export HEIMDALL_ONBOARD_NO_LAUNCH=1
fails=0

shot() {  # shot <name> <url>
  "$CHROME" --headless=new --disable-gpu --no-first-run --hide-scrollbars --window-size=1100,1700 \
    --virtual-time-budget=6000 --screenshot="$OUT/$1.png" "$2" >/dev/null 2>&1
  "$CHROME" --headless=new --disable-gpu --no-first-run --virtual-time-budget=6000 --dump-dom "$2" 2>/dev/null >"$OUT/$1.html"
  if [ -s "$OUT/$1.png" ]; then echo "PASS screenshot $1"; else echo "FAIL screenshot $1"; fails=$((fails + 1)); fi
}
expect() {  # expect <name> <text>
  if grep -q "$2" "$OUT/$1.html"; then echo "PASS $1 shows: $2"; else echo "FAIL $1 does not show: $2"; echo "::error::$1 missing $2"; fails=$((fails + 1)); fi
}

"$PY" "$VAULT/System/bin/onboard/server.py" --vault "$VAULT" --no-browser >"$OUT/server.txt" 2>&1 &
SRV=$!
for _ in $(seq 1 50); do grep -q "http://127.0.0.1" "$OUT/server.txt" && break; sleep 0.2; done
URL="$(grep -o 'http://127\.0\.0\.1:[0-9]*/?t=[^ ]*' "$OUT/server.txt" | head -n1)"
[ -n "$URL" ] || { echo "FAIL window printed no address"; cat "$OUT/server.txt"; kill $SRV; exit 1; }
echo "window at ${URL%%\?*}"

shot 1_fresh "$URL"
expect 1_fresh "Set up your second brain"
expect 1_fresh "Answer /setup in Claude"
# No software step here, so Obsidian has not opened the folder: step 2 is current.
expect 1_fresh "Open in Obsidian"

# What /setup and a first /organize leave behind, done the way the commands do it.
printf '# Start here\n\n## Who I am\nA founder.\n' >"$VAULT/START_HERE.md"
mkdir -p "$VAULT/Work/Clients" && printf '# Clients\n' >"$VAULT/Work/Clients/README.md"
SRC="$RUNNER_TEMP/shot_downloads"; rm -rf "$SRC"; cp -R "$HERE/fixtures/organize" "$SRC"
"$PY" "$VAULT/System/bin/organize.py" --vault "$VAULT" scan "$SRC" >/dev/null
PLAN="$(ls "$VAULT"/System/plans/organize_*.csv | grep -v _result | head -n1)"
"$PY" - "$PLAN" <<'EOF'
import csv, sys
p = sys.argv[1]
with open(p, newline="", encoding="utf-8-sig") as fh:
    r = csv.DictReader(fh); head, rows = r.fieldnames, list(r)
with open(p, "w", newline="", encoding="utf-8") as fh:
    w = csv.DictWriter(fh, fieldnames=head); w.writeheader()
    for row in rows:
        if not row.get("keep_out"):
            row["destination"] = "Archive"
        w.writerow(row)
EOF
"$PY" "$VAULT/System/bin/organize.py" --vault "$VAULT" apply "$PLAN" --yes >/dev/null

shot 2_sorted "$URL"
expect 2_sorted "Your second brain has files in it."
expect 2_sorted "Clients"
expect 2_sorted "Close setup"

kill $SRV 2>/dev/null
echo "== window: $fails failed"
exit $(( fails > 0 ? 1 : 0 ))
