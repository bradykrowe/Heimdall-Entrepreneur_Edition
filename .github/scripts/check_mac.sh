#!/usr/bin/env bash
# Checks a Heimdall Entrepreneur vault installed on a Mac runner.
#
#   check_mac.sh <vault> <first|second|scaffold> <console.txt>
#
# first     after the one-line install with the software step on
# second    after the same line a second time: the member's edit must survive
# scaffold  after Install.command with --skip-software (no software checks)
#
# Prints PASS or FAIL per check and exits 1 if any check failed.

set -uo pipefail
VAULT="$1"; PHASE="$2"; CONSOLE="$3"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fails=0
ok()   { echo "PASS $*"; }
bad()  { echo "FAIL $*"; echo "::error::$*"; fails=$((fails + 1)); }
check() { local what="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$what"; else bad "$what"; fi; }

echo "== $PHASE: $VAULT on macOS $(sw_vers -productVersion), $(uname -m)"

# ------------------------------------------------------------------ vault ----
for rel in CLAUDE.md START_HERE.md Ledger.md Reference/README.md Work/README.md Inbox/README.md Archive/README.md \
           System/privacy_floor.md System/bin/organize.py System/plans System/heimdall_install.json \
           System/bin/onboard/server.py System/bin/onboard/static/index.html System/bin/onboard/static/app.js \
           System/bin/onboard/static/app.css System/bin/onboard/static/tokens.css \
           .claude/settings.json .claude/commands/setup.md .claude/commands/organize.md \
           .claude/commands/inbox.md .claude/commands/ledger.md; do
  check "vault has $rel" test -e "$VAULT/$rel"
done
check "start_heimdall.command exists" test -f "$VAULT/start_heimdall.command"
check "start_heimdall.command is executable" test -x "$VAULT/start_heimdall.command"
check "start file says Starting Heimdall" grep -q "Starting Heimdall" "$VAULT/start_heimdall.command"
check "start file has no Windows .cmd beside it" test ! -e "$VAULT/Start_Heimdall.cmd"
check "install record says entrepreneur" grep -q '"edition": "entrepreneur"' "$VAULT/System/heimdall_install.json"
check "carrier heading uses the brand" grep -q "# Heimdall vault" "$HOME/.claude/CLAUDE.md"
check "carrier has no identity step" bash -c "! grep -q sync-identity '$HOME/.claude/CLAUDE.md'"
check "no connector key step printed" bash -c "! grep -q 'Give the connector its key' '$CONSOLE'"
check "next step names /organize" grep -q "/organize" "$CONSOLE"
check "no Life_Compass or bootstrap in the vault" bash -c "test ! -e '$VAULT/Life_Compass' && test ! -e '$VAULT/System/bootstrap'"

# --------------------------------------------------------------- software ----
if [ "$PHASE" != "scaffold" ]; then
  export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"; hash -r
  check "Homebrew installed" command -v brew
  check "Obsidian.app installed" test -d /Applications/Obsidian.app
  check "node installed" command -v node
  check "claude installed" command -v claude
  check "vault registered with Obsidian" grep -q "$(basename "$VAULT")" "$HOME/Library/Application Support/obsidian/obsidian.json"
fi

if [ "$PHASE" = "second" ]; then
  check "member edit to START_HERE.md survived the second run" grep -q "CI_MEMBER_EDIT_4417" "$VAULT/START_HERE.md"
  check "second run did not leave a Windows start file" test ! -e "$VAULT/Start_Heimdall.cmd"
fi

# ---------------------------------------------------- window and organize ----
# Every usable python3 on this Mac, Apple's 3.9 included: the window and organize.py promise 3.8+.
pys=()
for c in /usr/bin/python3 /opt/homebrew/bin/python3 /usr/local/bin/python3 python3.13 python3.12 python3.11; do
  p="$(command -v "$c" 2>/dev/null)" || continue
  "$p" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' 2>/dev/null || continue
  real="$(cd "$(dirname "$p")" && pwd -P)/$(basename "$p")"
  case " ${pys[*]:-} " in *" $real "*) continue ;; esac
  pys+=("$real")
done
[ "${#pys[@]}" -gt 0 ] && ok "found ${#pys[@]} python3 (${pys[*]})" || bad "no python3 >= 3.8 on this Mac"
for py in "${pys[@]}"; do
  ver="$("$py" -c 'import platform; print(platform.python_version())')"
  state="$("$py" "$VAULT/System/bin/onboard/server.py" --vault "$VAULT" --state 2>&1)"
  if echo "$state" | "$py" -c 'import json,sys; s=json.load(sys.stdin); d={x["id"]:x["status"] for x in s["steps"]}; sys.exit(0 if d["installed"]=="done" and len(d)==6 else 1)'; then
    ok "window state on python $ver: installed=done, 6 steps"
  else
    bad "window state on python $ver: $state"
  fi
  if ONBOARD_SERVER="$VAULT/System/bin/onboard/server.py" "$py" "$HERE/test_onboard_entrepreneur.py" >"$RUNNER_TEMP/ci/onboard_tests_${PHASE}_${ver}.txt" 2>&1; then
    ok "window and organize tests on python $ver ($(grep -E '^Ran ' "$RUNNER_TEMP/ci/onboard_tests_${PHASE}_${ver}.txt"))"
  else
    bad "window and organize tests on python $ver"; tail -40 "$RUNNER_TEMP/ci/onboard_tests_${PHASE}_${ver}.txt"
  fi
done

echo "== $PHASE: $fails failed"
exit $(( fails > 0 ? 1 : 0 ))
