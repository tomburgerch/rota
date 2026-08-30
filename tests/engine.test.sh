#!/usr/bin/env bash
# The `[ … ] && ok … || bad …` assertion shape below is deliberate: ok()/bad()
# only printf + bump a counter (always return 0), so the SC2015 "C may run
# when A is true" caveat cannot bite.
# shellcheck disable=SC2015
#
# engine.test.sh: regression test for `switch-all`'s verdict (rota-engine.sh).
#
# Runs the REAL lib/rota-engine.sh against a throwaway $HOME (its
# own ~/.claude, ~/.claude-pool/*, accounts file) with fake `claude` and
# `security` binaries earlier on PATH. Nothing here touches a real credential,
# the Keychain, or the account pool.
#
# What this guards, the false FAIL that cost a session on 2026-07-27, where two
# consecutive `rota switch primary` runs both printed "swap written but auth
# status reports <old>" and returned 1, while the swap had in fact landed and
# every running session was already on the new account:
#   - auth status agrees on the first read           → pass (unchanged happy path)
#   - auth status LAGS, then agrees                  → pass, via the retry loop
#     (a single sample would have failed this)
#   - auth status never agrees but the written bytes are still on disk and no
#     Keychain item exists                           → pass, saying the FILE is
#     what sessions follow, this is the 2026-07-27 case, where auth status on
#     the always-on box disagreed indefinitely yet a session opened after the swap came up
#     on the new account
#   - the shared file was rewritten under us         → FAIL (exit 1), named as a
#     live pinned session clobbering the swap
#   - Keychain item exists and could not be updated  → FAIL (exit 1), named as
#     Keychain shadowing, with the GUI-Terminal next step
# The last two are the only real causes, and they get different next steps,
# that split is the point of the fix.
#
# Scenarios 13-16 guard the 2026-07-30 CORRECTION (PR #433's central claim was
# wrong): `claude auth status` was never untrustworthy, it was being aimed at
# $CLAUDE_CONFIG_DIR/.claude.json = the NESTED ~/.claude/.claude.json instead of the
# ~/.claude.json a real session reads. They cover the probe's environment, the
# nested-file warning, the restored third-opinion cross-check, and the both-polarities
# rendering that stops `usage` from looking like it disagrees with the statusline.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
SCRIPT="$REPO_ROOT/lib/rota-engine.sh"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'ok   - %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL - %s\n' "$1"; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/failover-test.XXXXXX")"
ROOT="$(cd "$ROOT" && pwd)"
cleanup() { rm -rf "$ROOT"; }
trap cleanup EXIT

OLD_EMAIL="old@example.com"
NEW_EMAIL="target@example.com"

STUB_DIR="$ROOT/bin"
mkdir -p "$STUB_DIR"

# --- fake `claude` ------------------------------------------------------------
# Serves `auth status` JSON in the shape shared_email() greps. FAKE_LAG is how
# many of the FIRST calls report the OLD account (99 = never agrees). FAKE_CLOBBER
# makes it rewrite the shared credential on its first call, standing in for a
# live session pinned to the old account rotating its token over the swap.
#
# It also APPENDS the CLAUDE_CONFIG_DIR each `auth status` probe was invoked with to
# $FAKE_STATE/authenv ("UNSET" when the variable is absent). That is what lets a test
# prove the shared-account probe aims at ~/.claude.json rather than the nested
# ~/.claude/.claude.json, the 2026-07-30 root cause. Only `auth` calls are recorded:
# the per-pool-dir `claude -p` usage nudge legitimately DOES set CLAUDE_CONFIG_DIR.
#
# THE NUDGE ARM (2026-08-07). `claude -p …` with CLAUDE_CONFIG_DIR pointed at a pool
# dir is collect_usage's haiku nudge, and it is what gutted the personal seat on the always-on box: the real
# CLI tries to refresh, the server rejects a dead refresh token, and the CLI CLEARS
# the credential it can no longer use. Every nudge is logged to $FAKE_STATE/nudges (so
# a test can prove a nudge did NOT happen twice), and when
# $FAKE_STATE/deadrefresh-<pool-basename> exists the stub reproduces that clearing
# exactly, the 1296-byte husk shape: the refreshToken KEY with no value, expiresAt
# gone, refreshTokenExpiresAt surviving. Nothing outside $HOME is ever written.
cat > "$STUB_DIR/claude" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "auth" ]; then
  printf '%s\n' "${CLAUDE_CONFIG_DIR-UNSET}" >> "$FAKE_STATE/authenv"
fi
if [ "${1:-}" = "-p" ] && [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
  base="$(basename "$CLAUDE_CONFIG_DIR")"
  printf '%s\n' "$base" >> "$FAKE_STATE/nudges"
  if [ -f "$FAKE_STATE/deadrefresh-$base" ]; then
    printf '{"claudeAiOauth":{"accessToken":"","refreshToken":"","refreshTokenExpiresAt":%s000,"scopes":["user:inference"],"subscriptionType":"max"}}' \
      "$(cat "$FAKE_STATE/deadrefresh-$base")" > "$CLAUDE_CONFIG_DIR/.credentials.json"
  fi
fi
n=$(cat "$FAKE_STATE/authcalls" 2>/dev/null || echo 0)
n=$((n + 1))
echo "$n" > "$FAKE_STATE/authcalls"
if [ -n "${FAKE_CLOBBER:-}" ] && [ "$n" -eq 2 ]; then
  printf 'rotated-by-a-live-session' > "$HOME/.claude/.credentials.json"
fi
if [ "$n" -le "${FAKE_LAG:-0}" ]; then email="$FAKE_OLD_EMAIL"; else email="$FAKE_NEW_EMAIL"; fi
printf '{\n  "loggedIn": true,\n  "email": "%s",\n  "subscriptionType": "max"\n}\n' "$email"
STUB
chmod +x "$STUB_DIR/claude"

# --- fake `security` ----------------------------------------------------------
# FAKE_KEYCHAIN: "none" = no item on this box (find-generic-password exits 1, the
# real shape on the always-on box), "locked" = item exists but add-generic-password fails,
# as it does when the login keychain is not writable from tmux/SSH, "welded" =
# item exists and neither add nor delete works (the genuinely stuck case).
#
# delete-generic-password is modelled with a per-service counter rather than a
# blanket exit 0, because the real thing removes ONE item per call and then fails
# once the name is gone. A stub that always succeeded would let an unbounded
# drain loop spin forever, and would hide the bound that stops it.
cat > "$STUB_DIR/security" <<'STUB'
#!/usr/bin/env bash
svc=""; prev=""
for a in "$@"; do [ "$prev" = "-s" ] && svc="$a"; prev="$a"; done
slug="$(printf '%s' "$svc" | tr -c 'A-Za-z0-9' '_')"
gone="${FAKE_STATE:-/tmp}/kc-deleted-$slug"
case "${1:-}" in
  find-generic-password)
    [ "${FAKE_KEYCHAIN:-none}" = "none" ] && exit 1
    [ -f "$gone" ] && exit 1
    exit 0 ;;
  add-generic-password)
    case "${FAKE_KEYCHAIN:-none}" in locked|welded) exit 1 ;; esac
    exit 0 ;;
  delete-generic-password)
    [ "${FAKE_KEYCHAIN:-none}" = "welded" ] && exit 1
    [ -f "$gone" ] && exit 1
    : > "$gone"; exit 0 ;;
esac
exit 0
STUB
chmod +x "$STUB_DIR/security"

# --- fake `curl` ---------------------------------------------------------------
# Stands in for the usage API: reads the Authorization: Bearer token off argv and
# serves $FAKE_STATE/usage-<token>.json + "\n200" (matching usage_fetch's
# `-w $'\n%{http_code}'`) when that fixture exists, else "\n000", the same shape
# a real network failure would hand back. Never touches a real endpoint.
#
# $FAKE_STATE/usage-<token>.code is the third shape, added 2026-08-07: an empty body
# with THAT status code, so a scenario can serve a real 401 (a token that is complete
# but no longer accepted) rather than the 000 of a dead socket. Purely additive,
# every existing fixture still takes the 200 branch or falls through to 000.
cat > "$STUB_DIR/curl" <<'STUB'
#!/usr/bin/env bash
token=""
prev=""
ua=""
for a in "$@"; do
  if [ "$prev" = "-H" ]; then
    case "$a" in
      Authorization:*) token="${a#Authorization: Bearer }" ;;
      User-Agent:*)    ua="${a#User-Agent: }" ;;
    esac
  fi
  prev="$a"
done
# the UA each token was probed with, so a test can prove the header went out
[ -n "$token" ] && printf '%s\n' "${ua:-NONE}" > "$FAKE_STATE/ua-$token"
file="$FAKE_STATE/usage-$token.json"
code="$FAKE_STATE/usage-$token.code"
if [ -n "$token" ] && [ -f "$file" ]; then
  printf '%s\n200' "$(cat "$file")"
elif [ -n "$token" ] && [ -f "$code" ]; then
  printf '\n%s' "$(cat "$code")"
else
  printf '\n000'
fi
STUB
chmod +x "$STUB_DIR/curl"

# --- fake `ssh` ----------------------------------------------------------------
# Stands in for the ONE peer call (peer_ssh): `rota accounts --json --no-refresh`
# on a box that holds a credential this one does not. Stubbed for the WHOLE suite
# and, by default, REFUSING: unstubbed, a scenario that configured a peer would
# dial the real network and every assertion would depend on whose laptop the
# suite happens to run on. Refusing by default is also the exact host-is-down
# behaviour the feature promises to degrade through.
#
# $FAKE_STATE/peer-<host>.json arms it: that file becomes the peer's stdout.
# $FAKE_STATE/peer-slow-<host> makes it hang (the timeout bound), and
# $FAKE_STATE/peer-junk-<host> makes it answer with something that is not JSON.
# Every call APPENDS its host to $FAKE_STATE/ssh-calls, which is what lets a
# scenario prove a round trip did NOT happen (--no-refresh, the 90s TTL and the
# never-ssh-to-yourself rule are all assertions about a call that must be absent).
# No key, no known_hosts, no socket: nothing here can reach a real machine.
cat > "$STUB_DIR/ssh" <<'STUB'
#!/usr/bin/env bash
# rota calls this as: ssh -o … -o … <host> <remote-command>
host="${@: -2:1}"
printf '%s\n' "$host" >> "${FAKE_STATE:-/tmp}/ssh-calls"
[ -f "${FAKE_STATE:-/nonexistent}/peer-slow-$host" ] && { sleep 30; exit 0; }
[ -f "${FAKE_STATE:-/nonexistent}/peer-junk-$host" ] && { printf 'ssh: this is not JSON\n'; exit 0; }
f="${FAKE_STATE:-/nonexistent}/peer-$host.json"
[ -f "$f" ] || exit 255            # ssh's own "could not connect" exit code
cat "$f"
STUB
chmod +x "$STUB_DIR/ssh"

# --- fake `tmux` ---------------------------------------------------------------
# The PANES block (render_panes_summary / restart_idle_panes) asks tmux what is
# open in the configured session. Unstubbed, this suite would read the REAL local
# tmux server, every usage/switch assertion would then depend on how many panes
# happen to be open, and two consecutive runs could disagree. So tmux is stubbed
# for the WHOLE suite and, by default, reports NO session: that is both the
# hermetic default and the exact missing-session behaviour the block promises (a
# silent no-op).
#
# FAKE_TMUX_PANES arms it: a `list-panes -F` listing, one pane per line, already
# in the \x1f-separated shape the script asks for. FAKE_TMUX_WORKING is a
# space-padded list of pane ids whose capture-pane output shows "esc to
# interrupt". FAKE_TMUX_CMD_<id> overrides what a pane's current command reports
# to display-message (used to let a pane fall back to its shell after /quit).
# Every write call (send-keys) is LOGGED, never executed, no real pane, real or
# fake, is ever touched.
TMUX_LOG="$ROOT/tmux.log"
: > "$TMUX_LOG"
cat > "$STUB_DIR/tmux" <<'STUB'
#!/usr/bin/env bash
printf 'tmux %s\n' "$*" >> "${TMUX_LOG:-/dev/null}"
US=$'\037'
case "${1:-}" in
  has-session)
    [ -n "${FAKE_TMUX_PANES:-}" ] && exit 0 || exit 1 ;;
  list-panes)
    printf '%s\n' "${FAKE_TMUX_PANES:-}" ;;
  capture-pane)
    pane=""; prev=""
    for a in "$@"; do [ "$prev" = "-t" ] && pane="$a"; prev="$a"; done
    case " ${FAKE_TMUX_WORKING:-} " in
      *" $pane "*) printf '· Frobnicating… (esc to interrupt · 12s)\n'; exit 0 ;;
    esac
    case " ${FAKE_TMUX_BACKGROUND:-} " in
      *" $pane "*) printf '✻ Waiting for 3 background tasks\n'; exit 0 ;;
    esac
    printf '❯ \nWeekly: 12%%\nSession: 30%%\n' ;;
  display-message)
    pane=""; prev=""
    for a in "$@"; do [ "$prev" = "-t" ] && pane="$a"; prev="$a"; done
    var="FAKE_TMUX_CMD_${pane#%}"
    eval "printf '%s\n' \"\${$var:-zsh}\"" ;;
  send-keys) : ;;
esac
exit 0
STUB
chmod +x "$STUB_DIR/tmux"

# --- fake `ps` -----------------------------------------------------------------
# Only the pane-start-time probe is faked, and only when a fixture exists for the
# tty it asks about: `ps -t <tty>` serves $FAKE_STATE/ps-<tty>.txt, so a scenario
# can put a claude process's start time on either side of the credential's mtime
# and assert the "may still be on the previous account" count. Everything else
# falls through to the REAL ps, so nothing else in the suite (or in bash itself)
# is affected.
cat > "$STUB_DIR/ps" <<'STUB'
#!/usr/bin/env bash
tty=""; prev=""
for a in "$@"; do [ "$prev" = "-t" ] && tty="$a"; prev="$a"; done
f="${FAKE_STATE:-/nonexistent}/ps-$tty.txt"
if [ -n "$tty" ] && [ -f "$f" ]; then cat "$f"; exit 0; fi
exec /bin/ps "$@"
STUB
chmod +x "$STUB_DIR/ps"

# --- fake `ps eww -ax` (pool v2) -----------------------------------------------
# pool_ps() (the `billing now:` header + normalize's live-pin gate) shells out to
# `ps eww -ax` unless CLAUDE_FAILOVER_PS_CMD points at an executable. Left real,
# the suite would read THIS box's actual claude processes, their pinned pool
# dirs, their real identities, and every dashboard assertion would depend on
# what happens to be running. Serves $FAKE_STATE/pool-ps.txt when a scenario
# provides one, else a bare header (no processes at all).
cat > "$STUB_DIR/pool-ps" <<'STUB'
#!/usr/bin/env bash
f="${FAKE_STATE:-/nonexistent}/pool-ps.txt"
if [ -f "$f" ]; then cat "$f"; else printf 'PID TT STAT TIME COMMAND\n'; fi
STUB
chmod +x "$STUB_DIR/pool-ps"
export CLAUDE_FAILOVER_PS_CMD="$STUB_DIR/pool-ps"

export PATH="$STUB_DIR:$PATH"
export TMUX_LOG
export FAKE_OLD_EMAIL="$OLD_EMAIL" FAKE_NEW_EMAIL="$NEW_EMAIL"
export CLAUDE_FAILOVER_VERIFY_SLEEP=0   # keep the retry loop instant under test
export ROTA_PANE_RESTART_SLEEP=0         # --restart-idle's shell wait, instant under test
# The engine has NO default tmux session name (pane convergence is opt-in): the
# suite names one so the stub tmux is consulted at all. Scenario 44 unsets it
# again to prove the opt-out is a silent no-op.
export ROTA_TMUX_SESSION="rota-test-panes"
# Never inherit the real session's pane id: restart_idle_panes skips $TMUX_PANE,
# and a leaked value could silently skip a pane a scenario is asserting on.
unset TMUX_PANE
# Same for the peer list. ROTA_PEERS is SET-BUT-EMPTY-aware by design (that is how
# the remote leg of a peer call switches the feature off), so inheriting one from
# the surrounding shell would arm a peer in every scenario that never asked for
# one. $CLAUDE_FAILOVER_HOME already points the peers FILE at the fake cfg dir.
unset ROTA_PEERS
# Nor the operator's own billing/hand-measurement files. `usage` reads both now
# (seat status, end dates, dated `boosts`, recorded readings), and both default
# inside $CFG_DIR, which every scenario throws away, so the only way a REAL file
# could reach this suite is an inherited override. A run that read one would
# assert against somebody's live seats and change its answer on the day a boost
# expires.
unset CLAUDE_BILLING_JSON CLAUDE_HUMAN_USAGE

# --- per-run fixture ----------------------------------------------------------
# A fresh $HOME each run so state never leaks into the next scenario. v2 shape
# (2026-08-11): each pool dir holds its own COMPLETE credential + its identity
# in <dir>/.claude.json, the root ~/.claude.json claims the OLD account, and a
# STRAY v1-era credential sits in the shared ~/.claude, which the pointer
# switch must DELETE, never adopt, copy, or stash.
setup() {
  RUN="$ROOT/run.$1"; shift
  rm -rf "$RUN"
  mkdir -p "$RUN/.claude" "$RUN/.claude-pool/old" "$RUN/.claude-pool/new" "$RUN/cfg" "$RUN/state"
  local exp=$(( ($(date +%s) + 86400) * 1000 ))
  printf '{"claudeAiOauth":{"accessToken":"TOK-SW-OLD","refreshToken":"rt-old","expiresAt":%s,"refreshTokenExpiresAt":%s}}' \
    "$exp" "$exp" > "$RUN/.claude-pool/old/.credentials.json"
  printf '{"claudeAiOauth":{"accessToken":"TOK-SW-NEW","refreshToken":"rt-new","expiresAt":%s,"refreshTokenExpiresAt":%s}}' \
    "$exp" "$exp" > "$RUN/.claude-pool/new/.credentials.json"
  printf '{"oauthAccount":{"emailAddress":"%s"}}' "$OLD_EMAIL" > "$RUN/.claude-pool/old/.claude.json"
  printf '{"oauthAccount":{"emailAddress":"%s"}}' "$NEW_EMAIL" > "$RUN/.claude-pool/new/.claude.json"
  printf '{"oauthAccount":{"emailAddress":"%s"}}' "$OLD_EMAIL" > "$RUN/.claude.json"
  printf 'STRAY-V1-SHARED-CREDENTIAL' > "$RUN/.claude/.credentials.json"
  cat > "$RUN/cfg/accounts" <<EOF
$OLD_EMAIL|$RUN/.claude-pool/old
$NEW_EMAIL|$RUN/.claude-pool/new
EOF
  export HOME="$RUN" CLAUDE_FAILOVER_HOME="$RUN/cfg" FAKE_STATE="$RUN/state"
}

# switch-all onto the NEW account; captures merged output and exit code.
run_switch() {
  set +e
  OUT="$("$SCRIPT" switch-all "$NEW_EMAIL" 2>&1)"
  RC=$?
  set -e
}

# --- fixture builder for the identity/usage scenarios below -------------------
# Unlike setup() (fixed to the switch-all OLD/NEW shape above, and left
# untouched), this is a bare $HOME with no accounts file and no credentials,
# each scenario below populates exactly what it needs.
new_run() {  # new_run <name>
  RUN="$ROOT/run.$1"
  rm -rf "$RUN"
  mkdir -p "$RUN/.claude" "$RUN/cfg" "$RUN/state"
  export HOME="$RUN" CLAUDE_FAILOVER_HOME="$RUN/cfg" FAKE_STATE="$RUN/state"
}

# An ISO-8601 usage-API-shaped timestamp offset from now, e.g. `iso_in +2H`,
# `iso_in +2d`, `iso_in -2d`, same `date -v` adjustment syntax the real API's
# resets_at values decode to via iso_epoch().
iso_in() { date -u -v"$1" '+%Y-%m-%dT%H:%M:%S.000000+00:00'; }

REAL_HOME="$HOME"
restore_home() { export HOME="$REAL_HOME"; }
trap 'restore_home; cleanup' EXIT

# --- reading the THREE-BUCKET dashboard (2026-08-07) ---------------------------
# The report is now ▶ ACTIVE / ALTERNATIVES / UNAVAILABLE, one blank line between
# buckets, so a scenario that means "the primary ROW" says which bucket it expects
# to find it in, which is a stronger assertion than the old per-row awk, because
# landing in the wrong bucket is now itself a failure.
#
# Every extractor stops at the first blank line after its header, exactly as the
# old row-block awk did, so a bucket can never silently swallow the next one.
active_block()  { awk '/^▶ ACTIVE/{f=1} f&&/^$/{exit} f'; }
alt_block()     { awk '/^  ALTERNATIVES/{f=1;next} f&&/^$/{exit} f'; }
unavail_block() { awk '/^  UNAVAILABLE/{f=1;next} f&&/^$/{exit} f'; }
# The FOURTH bucket (2026-08-25). "I have not measured this" is a statement about
# the TOOL, not a verdict on the account, and filing it under UNAVAILABLE told
# every reader the opposite of the truth about two cancelled-but-live seats.
unmeasured_block() { awk '/^  UNMEASURED/{f=1;next} f&&/^$/{exit} f'; }
# How many ACCOUNT rows a report rendered: the ACTIVE header plus one ✓/✗/? line
# per other account. Alternation rather than a [✓✗] bracket expression, those
# are multi-byte and BSD grep collapses them byte-wise outside a UTF-8 locale.
rendered_rows() { grep -cE '^(▶ ACTIVE|  ✓ |  ✗ |  \? )' || true; }
# Any line that leads with "N% left · M% used" while NOT being one of the two
# metered ACTIVE window rows. The metered rows lead with left deliberately (they
# sit next to a bar whose filled cells ARE the left figure); every SENTENCE must
# still lead with USED, the statusline's number in the statusline's position.
left_first_prose() { grep -vE '^    (weekly|5h) +[█░]' | grep -E '[0-9]+% left · [0-9]+% used' || true; }

# --- 1. the pointer switch, happy path (v2, 2026-08-11) -----------------------
# v1 copied the target credential into ~/.claude and stashed the outgoing one;
# every scenario in this block used to assert that machinery. v2 moves ONLY the
# ~/.claude.json claim, deletes the stray shared credential, and never lets a
# credential byte cross a dir boundary, which is exactly what is asserted now.
setup agrees
OLD_POOL_BEFORE="$(cat "$RUN/.claude-pool/old/.credentials.json")"
NEW_POOL_BEFORE="$(cat "$RUN/.claude-pool/new/.credentials.json")"
FAKE_KEYCHAIN=none run_switch
[ "$RC" -eq 0 ] && ok "pointer switch → exit 0" || bad "pointer switch → exit 0 (got $RC: $OUT)"
grep -q "active account is now $NEW_EMAIL" <<<"$OUT" \
  && ok "pointer switch → reports the new active account" \
  || bad "pointer switch → reports the new active account (got: $OUT)"
[ "$(jq -r '.oauthAccount.emailAddress' "$RUN/.claude.json")" = "$NEW_EMAIL" ] \
  && ok "pointer switch → ~/.claude.json claim moved to the target" \
  || bad "pointer switch → claim moved (got: $(cat "$RUN/.claude.json"))"
[ ! -e "$RUN/.claude/.credentials.json" ] \
  && ok "pointer switch → the stray shared credential is DELETED, not adopted" \
  || bad "pointer switch → shared credential must be deleted (still there: $(cat "$RUN/.claude/.credentials.json"))"
[ "$(cat "$RUN/.claude-pool/old/.credentials.json")" = "$OLD_POOL_BEFORE" ] \
  && [ "$(cat "$RUN/.claude-pool/new/.credentials.json")" = "$NEW_POOL_BEFORE" ] \
  && ok "pointer switch → NOT ONE credential byte moved (both pool copies untouched)" \
  || bad "pointer switch → a pool credential changed under a switch"
[ ! -d "$RUN/cfg/creds" ] \
  && ok "pointer switch → no stash write (the creds/ hand-off dir is never created)" \
  || bad "pointer switch → a stash appeared at cfg/creds"
grep -q "no credential moved" <<<"$OUT" \
  && ok "pointer switch → says out loud that no credential moved" \
  || bad "pointer switch → names the pointer semantics (got: $OUT)"

# --- 2. no subprocess in the verification path --------------------------------
# v1 verified through `claude auth status` (with a lag-retry loop). v2's
# verification is two file reads, the claim and the target dir's identity, so
# a switch must complete without EVER exec'ing the claude CLI. The stub counts
# every invocation into $FAKE_STATE/authcalls; the file must not exist.
setup nosubproc
FAKE_KEYCHAIN=none run_switch
[ "$RC" -eq 0 ] && ok "no-subprocess switch → exit 0" || bad "no-subprocess switch → exit 0 (got $RC: $OUT)"
[ ! -f "$FAKE_STATE/authcalls" ] \
  && ok "no-subprocess switch → the claude CLI was never invoked (file reads only)" \
  || bad "no-subprocess switch → claude was invoked $(cat "$FAKE_STATE/authcalls") time(s)"

# --- 3. resolution is BY IDENTITY, the map is only a hint ----------------------
# The 2026-08-11 live incident: the map said alpha→dirA, but dirA actually held
# work. v2 must follow the IDENTITY: when the mapped dir holds someone else and
# exactly one other dir holds the target, switch to THAT dir, flag
# needs-reconcile, and say so.
setup crossed
# cross the identities (contents swapped, map stale, the incident's exact shape)
printf '{"oauthAccount":{"emailAddress":"%s"}}' "$NEW_EMAIL" > "$RUN/.claude-pool/old/.claude.json"
printf '{"oauthAccount":{"emailAddress":"%s"}}' "$OLD_EMAIL" > "$RUN/.claude-pool/new/.claude.json"
FAKE_KEYCHAIN=none run_switch
[ "$RC" -eq 0 ] && ok "identity resolution → exit 0" || bad "identity resolution → exit 0 (got $RC: $OUT)"
grep -q "the dir that actually holds it" <<<"$OUT" \
  && ok "identity resolution → names the mismatch and the dir it followed instead" \
  || bad "identity resolution → names the mismatch (got: $OUT)"
grep -q "claude-pool/old" <<<"$OUT" \
  && ok "identity resolution → switched to the dir holding the target identity" \
  || bad "identity resolution → wrong dir (got: $OUT)"
[ -f "$RUN/cfg/needs-reconcile" ] \
  && ok "identity resolution → flags needs-reconcile for the keeper to repair the map" \
  || bad "identity resolution → needs-reconcile flag missing"
[ "$(jq -r '.oauthAccount.emailAddress' "$RUN/.claude.json")" = "$NEW_EMAIL" ] \
  && ok "identity resolution → the claim still moves to the TARGET account" \
  || bad "identity resolution → claim wrong (got: $(cat "$RUN/.claude.json"))"

# --- 4. a husked target is REFUSED, with the one command that fixes it ---------
# A pointer aimed at a dir whose credential cannot answer is a login prompt
# wearing a switch's clothes. The refusal happens BEFORE anything moves: the
# claim keeps the old account and the stray shared credential is left alone
# (hygiene belongs to a switch that happens, not to one that is refused).
setup huskrefuse
printf '{"claudeAiOauth":{"accessToken":"","refreshToken":"","refreshTokenExpiresAt":1}}' \
  > "$RUN/.claude-pool/new/.credentials.json"
FAKE_KEYCHAIN=none run_switch
[ "$RC" -ne 0 ] && ok "husked target → refused (non-zero exit)" || bad "husked target → must refuse (got $RC: $OUT)"
grep -q "needs one browser login" <<<"$OUT" \
  && grep -q "CLAUDE_CONFIG_DIR=" <<<"$OUT" \
  && ok "husked target → the refusal names the exact login command" \
  || bad "husked target → names the login command (got: $OUT)"
[ "$(jq -r '.oauthAccount.emailAddress' "$RUN/.claude.json")" = "$OLD_EMAIL" ] \
  && ok "husked target → the claim did not move" \
  || bad "husked target → claim moved on a refused switch"

# --- 5. shared Keychain items: DELETED, both service-name shapes ---------------
# v1 synced the Keychain in lockstep with the shared file; v2 has no shared file,
# so any item under either name (unsuffixed / sha256-hashed, the 2026-08-09
# lesson) is stale by definition and gets removed, even from a locked keychain.
setup keychain
rm -f "$FAKE_STATE"/kc-deleted-* 2>/dev/null || true
FAKE_KEYCHAIN=locked run_switch
[ "$RC" -eq 0 ] \
  && ok "locked keychain → the switch still succeeds (deletion needs no unlock)" \
  || bad "locked keychain → exit 0 expected (got $RC: $OUT)"
grep -q "removed stale shared Keychain item" <<<"$OUT" \
  && ok "locked keychain → says the stale item(s) were removed" \
  || bad "locked keychain → says items removed (got: $OUT)"
KC_HIT="$(ls "$FAKE_STATE"/kc-deleted-* 2>/dev/null | wc -l | tr -d ' ')"
[ "$KC_HIT" -eq 2 ] \
  && ok "keychain → both the unsuffixed AND the sha256-hashed item are acted on" \
  || bad "keychain → expected 2 service names touched, got $KC_HIT"
ls "$FAKE_STATE"/kc-deleted-* 2>/dev/null | grep -q 'Claude_Code_credentials_[0-9a-f]\{8\}$' \
  && ok "keychain → the hashed name really is sha256(dir)[:8], not a guess" \
  || bad "keychain → no 8-hex-suffixed service name was touched"
rm -f "$FAKE_STATE"/kc-deleted-* 2>/dev/null || true

# --- 5b. a welded Keychain item warns but no longer blocks the switch ----------
# v2's verification is the claim + the target dir identity; with the shim
# installed nothing resolves the shared dir, so an undeletable item is worth a
# loud warning and an inspection command, not a failed switch.
setup keychain
FAKE_KEYCHAIN=welded run_switch
[ "$RC" -eq 0 ] \
  && ok "welded Keychain → the pointer switch itself still lands (exit 0)" \
  || bad "welded Keychain → exit 0 expected in v2 (got $RC: $OUT)"
grep -q "could not be deleted" <<<"$OUT" \
  && grep -q "dump-keychain" <<<"$OUT" \
  && ok "welded Keychain → warns and hands over the inspection command" \
  || bad "welded Keychain → warns with next step (got: $OUT)"

# --- 6. identity precedence: oauthAccount beats `claude auth status` ----------
# ~/.claude.json's oauthAccount must be trusted over auth status even when they
# disagree, auth status is stubbed to answer a THIRD, different address, so
# any accidental fallback to it would leak through as the wrong output.
new_run precedence
mkdir -p "$RUN/.claude-pool/sole"
cat > "$RUN/cfg/accounts" <<EOF
sole@example.com|$RUN/.claude-pool/sole
EOF
printf '{"oauthAccount":{"emailAddress":"trusted@example.com"}}' > "$RUN/.claude.json"
set +e
OUT="$(FAKE_OLD_EMAIL=trusted@example.com FAKE_NEW_EMAIL=untrusted@example.com FAKE_LAG=0 "$SCRIPT" active 2>/dev/null)"
RC=$?
set -e
[ "$RC" -eq 0 ] && ok "identity precedence → active exits 0" || bad "identity precedence → active exits 0 (got $RC)"
[ "$OUT" = "trusted@example.com" ] \
  && ok "identity precedence → oauthAccount wins over the stubbed auth status answer" \
  || bad "identity precedence → oauthAccount wins over the stubbed auth status answer (got: $OUT)"

# --- 7. FIX 1 regression: claimed slot's OWN live pool copy must not mask the
# shared credential's real numbers when identity sources disagree -------------
# oauthAccount claims wk@example.com; the shared credential's bytes are
# byte-identical to primary@example.com's pool copy (the strongest identity
# evidence there is), so the fingerprint says primary. wk@example.com's own
# pool credential is ALSO independently live (70% weekly), the exact shape
# that let the bug through: the claimed slot's own "live" state short-circuited
# the adopt, so the active row printed wk's 70% instead of the shared
# credential's real 8%. This is the regression test for that.
new_run fix1
mkdir -p "$RUN/.claude-pool/wk" "$RUN/.claude-pool/primary"
printf '{"claudeAiOauth":{"accessToken":"TOK-SHARED-1"}}' > "$RUN/.claude/.credentials.json"
cp "$RUN/.claude/.credentials.json" "$RUN/.claude-pool/primary/.credentials.json"
printf '{"oauthAccount":{"emailAddress":"primary@example.com"}}' > "$RUN/.claude-pool/primary/.claude.json"
printf '{"claudeAiOauth":{"accessToken":"TOK-WK-1"}}' > "$RUN/.claude-pool/wk/.credentials.json"
printf '{"oauthAccount":{"emailAddress":"wk@example.com"}}' > "$RUN/.claude-pool/wk/.claude.json"
printf '{"oauthAccount":{"emailAddress":"wk@example.com"}}' > "$RUN/.claude.json"
cat > "$RUN/cfg/accounts" <<EOF
wk@example.com|$RUN/.claude-pool/wk
primary@example.com|$RUN/.claude-pool/primary
EOF
printf '{"seven_day":{"utilization":92,"resets_at":"%s"},"five_hour":{"utilization":50,"resets_at":"%s"}}' \
  "$(iso_in +2H)" "$(iso_in +1H)" > "$RUN/state/usage-TOK-SHARED-1.json"
printf '{"seven_day":{"utilization":30,"resets_at":"%s"},"five_hour":{"utilization":20,"resets_at":"%s"}}' \
  "$(iso_in +5d)" "$(iso_in +3H)" > "$RUN/state/usage-TOK-WK-1.json"
set +e
# FAKE_NEW_EMAIL pins the auth-status third opinion to the account oauthAccount
# claims, so this scenario keeps testing ONLY the credential-vs-oauthAccount
# disagreement it was written for (scenario 16 covers auth-status disagreement).
JSON_OUT="$(FAKE_NEW_EMAIL=wk@example.com "$SCRIPT" usage --json 2>/dev/null)"
RC=$?
set -e
[ "$RC" -eq 0 ] && ok "FIX1 regression → usage --json exits 0" || bad "FIX1 regression → usage --json exits 0 (got $RC: $JSON_OUT)"
[ "$(jq -r '.active.email' <<<"$JSON_OUT")" = "wk@example.com" ] \
  && ok "FIX1 regression → oauthAccount's claim (wk) is still the label" \
  || bad "FIX1 regression → oauthAccount's claim is still the label (got: $(jq -r '.active.email' <<<"$JSON_OUT" 2>/dev/null))"
[ -n "$(jq -r '.active.warning // empty' <<<"$JSON_OUT")" ] \
  && ok "FIX1 regression → disagreement warning is present" \
  || bad "FIX1 regression → disagreement warning is present (got: $(jq -c '.active' <<<"$JSON_OUT" 2>/dev/null))"
active_row="$(jq -c '.accounts[] | select(.email=="wk@example.com")' <<<"$JSON_OUT" 2>/dev/null)"
[ "$(jq -r '.active' <<<"$active_row" 2>/dev/null)" = "true" ] \
  && ok "FIX1 regression → the active row is still wk@example.com's row" \
  || bad "FIX1 regression → the active row is still wk@example.com's row (got: $active_row)"
[ "$(jq -r '.weekly.remaining_pct' <<<"$active_row" 2>/dev/null)" = "8" ] \
  && ok "FIX1 regression → active row shows the SHARED credential's 8% weekly, not wk's own 70%" \
  || bad "FIX1 regression → active row shows the SHARED credential's 8% (got: $(jq -r '.weekly.remaining_pct' <<<"$active_row" 2>/dev/null))"
grep -q "disagree" <<<"$(jq -r '.note // empty' <<<"$active_row" 2>/dev/null)" \
  && ok "FIX1 regression → the row plainly says the numbers came from the disagreement, not wk's own pool copy" \
  || bad "FIX1 regression → the row explains where the numbers came from (got: $(jq -r '.note // empty' <<<"$active_row" 2>/dev/null))"

# --- 7b. FIX 2 regression: `active`'s --auto must run the free byte-identity
# check even though oauthAccount is present, and it must need NO network at all
# to do it -----------------------------------------------------------------
# oauthAccount claims wk2@example.com; the shared credential's bytes are
# byte-identical to primary2@example.com's pool copy. No usage-API fixture is
# provided for ANY token here, if this ever silently fell back to a live
# fetch it would 000 and prove nothing either way, so the only way this test
# can pass is the cheap filesystem-only cmp actually running. The old guard
# returned the instant oauthAccount existed, so this warning would never fire.
new_run fix2
mkdir -p "$RUN/.claude-pool/wk2" "$RUN/.claude-pool/primary2"
printf '{"claudeAiOauth":{"accessToken":"TOK-SHARED-F2"}}' > "$RUN/.claude/.credentials.json"
cp "$RUN/.claude/.credentials.json" "$RUN/.claude-pool/primary2/.credentials.json"
printf '{"oauthAccount":{"emailAddress":"primary2@example.com"}}' > "$RUN/.claude-pool/primary2/.claude.json"
printf '{"claudeAiOauth":{"accessToken":"TOK-WK2-F2"}}' > "$RUN/.claude-pool/wk2/.credentials.json"
printf '{"oauthAccount":{"emailAddress":"wk2@example.com"}}' > "$RUN/.claude-pool/wk2/.claude.json"
printf '{"oauthAccount":{"emailAddress":"wk2@example.com"}}' > "$RUN/.claude.json"
cat > "$RUN/cfg/accounts" <<EOF
wk2@example.com|$RUN/.claude-pool/wk2
primary2@example.com|$RUN/.claude-pool/primary2
EOF
set +e
STDOUT="$("$SCRIPT" active 2>"$RUN/state/active.err")"
RC=$?
set -e
STDERR="$(cat "$RUN/state/active.err")"
[ "$RC" -eq 0 ] && ok "FIX2 regression → active exits 0" || bad "FIX2 regression → active exits 0 (got $RC)"
[ "$STDOUT" = "wk2@example.com" ] \
  && ok "FIX2 regression → oauthAccount's claim is still the label on stdout" \
  || bad "FIX2 regression → oauthAccount's claim is still the label (got: $STDOUT)"
grep -q "identical.*bytes" <<<"$STDERR" \
  && ok "FIX2 regression → the free byte-identity check ran and found primary2's twin, with no network fixture available" \
  || bad "FIX2 regression → the free byte-identity check ran (got stderr: $STDERR)"
grep -q "primary2@example.com" <<<"$STDERR" \
  && ok "FIX2 regression → the warning names the account the bytes actually match" \
  || bad "FIX2 regression → the warning names the matching account (got: $STDERR)"

# --- 8. health floor + recommendation, active SPENT ---------------------------
# Mirrors the real 2026-07-30 numbers, with the active account taken all the way
# down: primary is at 99% used / 1% left, i.e. at or under the burn-down
# exhaustion threshold, so the hold is over and the ranking gets to decide again.
# alpha has 90% left resetting in ~2 days; wk has 69% left resetting later
# (~5 days). Expect alpha recommended (soonest reset among floor-clearing
# accounts) and the active account's exhaustion stated in the same breath.
# (Before the 2026-08-06 burn-down rule this scenario ran at 93% used / 7% left;
# that shape now correctly recommends STAY and is scenario 31's job.)
new_run floor
mkdir -p "$RUN/.claude-pool/primary" "$RUN/.claude-pool/alpha" "$RUN/.claude-pool/wk"
printf '{"claudeAiOauth":{"accessToken":"TOK-SHARED-2"}}' > "$RUN/.claude/.credentials.json"
cp "$RUN/.claude/.credentials.json" "$RUN/.claude-pool/primary/.credentials.json"
printf '{"oauthAccount":{"emailAddress":"primary@example.com"}}' > "$RUN/.claude-pool/primary/.claude.json"
printf '{"claudeAiOauth":{"accessToken":"TOK-ALPHA"}}' > "$RUN/.claude-pool/alpha/.credentials.json"
printf '{"oauthAccount":{"emailAddress":"alpha@example.com"}}' > "$RUN/.claude-pool/alpha/.claude.json"
printf '{"claudeAiOauth":{"accessToken":"TOK-WK-2"}}' > "$RUN/.claude-pool/wk/.credentials.json"
printf '{"oauthAccount":{"emailAddress":"wk@example.com"}}' > "$RUN/.claude-pool/wk/.claude.json"
printf '{"oauthAccount":{"emailAddress":"primary@example.com"}}' > "$RUN/.claude.json"
cat > "$RUN/cfg/accounts" <<EOF
primary@example.com|$RUN/.claude-pool/primary
alpha@example.com|$RUN/.claude-pool/alpha
wk@example.com|$RUN/.claude-pool/wk
EOF
printf '{"seven_day":{"utilization":99,"resets_at":"%s"},"five_hour":{"utilization":50,"resets_at":"%s"}}' \
  "$(iso_in +3H)" "$(iso_in +1H)" > "$RUN/state/usage-TOK-SHARED-2.json"
printf '{"seven_day":{"utilization":10,"resets_at":"%s"},"five_hour":{"utilization":20,"resets_at":"%s"}}' \
  "$(iso_in +2d)" "$(iso_in +2H)" > "$RUN/state/usage-TOK-ALPHA.json"
printf '{"seven_day":{"utilization":31,"resets_at":"%s"},"five_hour":{"utilization":25,"resets_at":"%s"}}' \
  "$(iso_in +5d)" "$(iso_in +2H)" > "$RUN/state/usage-TOK-WK-2.json"
set +e
OUT="$(FAKE_NEW_EMAIL=primary@example.com "$SCRIPT" usage 2>/dev/null)"
RC=$?
set -e
[ "$RC" -eq 0 ] && ok "health floor → usage exits 0" || bad "health floor → usage exits 0 (got $RC: $OUT)"
grep -q "switch to alpha@example.com" <<<"$OUT" \
  && ok "health floor → recommends alpha (soonest reset, clears the floor)" \
  || bad "health floor → recommends alpha (got: $OUT)"
grep -q "active account primary@example.com is nearly exhausted (weekly 99% used · 1% left" <<<"$OUT" \
  && ok "health floor → states the active account's exhaustion, used first" \
  || bad "health floor → states the active account's exhaustion (got: $OUT)"
grep -q "^→ switch to" <<<"$OUT" \
  && ok "health floor → a SPENT active account is no longer held: the burn-down is over" \
  || bad "health floor → a spent active account is no longer held (got: $OUT)"

# --- 9. the ONE exception to the burn-down hold: a BLOCKED 5h window ----------
# Weekly headroom you cannot reach is not headroom. The pool is in SCARCITY (alpha 45%
# left, wk 31%, both under the 50% comfortable mark), so burn-down mode is in force
# and primary's healthy 50%-left weekly would normally hold him there, but its 5h
# session window is at 99% used / 1% left, so Claude is blocked RIGHT NOW and only a
# switch unblocks it. The recommendation must switch, and must name the window that
# caused it rather than implying the week is spent.
#
# This also carries FIX 3's property forward (act_note used to populate only when the
# active account was under the health floor, so a switch named the target and never
# said what you were currently on). Since 2026-08-06 this is the ONLY shape in which a
# weekly-healthy active account is switched away from at all, the old "another
# account merely resets sooner" shape now correctly recommends STAY (scenario 31).
new_run blocked5h
mkdir -p "$RUN/.claude-pool/primary" "$RUN/.claude-pool/alpha" "$RUN/.claude-pool/wk"
printf '{"claudeAiOauth":{"accessToken":"TOK-SHARED-3"}}' > "$RUN/.claude/.credentials.json"
cp "$RUN/.claude/.credentials.json" "$RUN/.claude-pool/primary/.credentials.json"
printf '{"oauthAccount":{"emailAddress":"primary@example.com"}}' > "$RUN/.claude-pool/primary/.claude.json"
printf '{"claudeAiOauth":{"accessToken":"TOK-ALPHA-3"}}' > "$RUN/.claude-pool/alpha/.credentials.json"
printf '{"oauthAccount":{"emailAddress":"alpha@example.com"}}' > "$RUN/.claude-pool/alpha/.claude.json"
printf '{"claudeAiOauth":{"accessToken":"TOK-WK-3"}}' > "$RUN/.claude-pool/wk/.credentials.json"
printf '{"oauthAccount":{"emailAddress":"wk@example.com"}}' > "$RUN/.claude-pool/wk/.claude.json"
printf '{"oauthAccount":{"emailAddress":"primary@example.com"}}' > "$RUN/.claude.json"
cat > "$RUN/cfg/accounts" <<EOF
primary@example.com|$RUN/.claude-pool/primary
alpha@example.com|$RUN/.claude-pool/alpha
wk@example.com|$RUN/.claude-pool/wk
EOF
printf '{"seven_day":{"utilization":50,"resets_at":"%s"},"five_hour":{"utilization":99,"resets_at":"%s"}}' \
  "$(iso_in +10d)" "$(iso_in +1H)" > "$RUN/state/usage-TOK-SHARED-3.json"
printf '{"seven_day":{"utilization":55,"resets_at":"%s"},"five_hour":{"utilization":20,"resets_at":"%s"}}' \
  "$(iso_in +2d)" "$(iso_in +2H)" > "$RUN/state/usage-TOK-ALPHA-3.json"
printf '{"seven_day":{"utilization":69,"resets_at":"%s"},"five_hour":{"utilization":25,"resets_at":"%s"}}' \
  "$(iso_in +5d)" "$(iso_in +2H)" > "$RUN/state/usage-TOK-WK-3.json"
set +e
OUT="$(FAKE_NEW_EMAIL=primary@example.com "$SCRIPT" usage 2>/dev/null)"
RC=$?
set -e
[ "$RC" -eq 0 ] && ok "blocked 5h → usage exits 0" || bad "blocked 5h → usage exits 0 (got $RC: $OUT)"
grep -q "switch to alpha@example.com" <<<"$OUT" \
  && ok "blocked 5h → a spent 5h window overrides the burn-down hold and switches" \
  || bad "blocked 5h → recommends alpha (got: $OUT)"
grep -q "active account primary@example.com still has weekly headroom (50% used · 50% left" <<<"$OUT" \
  && ok "blocked 5h → still states the active account's standing (FIX 3's property)" \
  || bad "blocked 5h → states the active account's standing (got: $OUT)"
grep -q "its 5h window is spent (99% used · 1% left" <<<"$OUT" \
  && ok "blocked 5h → names the WINDOW that caused the switch, used-first" \
  || bad "blocked 5h → names the 5h window (got: $OUT)"
grep -q "mode: burn-down" <<<"$OUT" \
  && ok "blocked 5h → the exception is a BURN-DOWN-mode exception, and says so" \
  || bad "blocked 5h → names the mode (got: $OUT)"
grep -q "blocked right now" <<<"$OUT" \
  && ok "blocked 5h → says why switching beats spending the week down" \
  || bad "blocked 5h → explains the exception (got: $OUT)"
! grep -q "is nearly exhausted" <<<"$OUT" \
  && ok "blocked 5h → never claims the WEEKLY window is what ran out" \
  || bad "blocked 5h → must not blame the weekly window (got: $OUT)"

# --- 10. expired-cache rule: a cached row past its reset must say "expired" ---
# never a stale percentage, regardless of whether the number would compute.
new_run expired
mkdir -p "$RUN/.claude-pool/wk"
printf '{"claudeAiOauth":{"accessToken":"TOK-WK-EXP"}}' > "$RUN/.claude-pool/wk/.credentials.json"
cat > "$RUN/cfg/accounts" <<EOF
wk@example.com|$RUN/.claude-pool/wk
EOF
jq -n --arg wr "$(iso_in -2d)" --arg sr "$(iso_in +2H)" \
  '{"wk@example.com":{wk_u:"45",wk_r:$wr,se_u:"20",se_r:$sr,ts:"stale fixture",ts_epoch:"0"}}' \
  > "$RUN/cfg/usage-cache.json"
set +e
OUT="$("$SCRIPT" usage --no-refresh 2>/dev/null)"
JSON_OUT="$("$SCRIPT" usage --no-refresh --json 2>/dev/null)"
RC=$?
set -e
[ "$RC" -eq 0 ] && ok "expired cache → usage --no-refresh exits 0" || bad "expired cache → usage --no-refresh exits 0 (got $RC)"
# ⚠️ THIS ASSERTION WAS INVERTED ON PURPOSE, 2026-08-25. It used to require the
# row to land in UNAVAILABLE reading "weekly window expired", and that wording
# was load-bearing in the worst way: the string means "the number I have is
# stale, go and measure it" and it READS as "this account is finished". Every
# session believed it. Measured 2026-08-21 08:30, both cancelled-but-live seats
# rendered exactly that while each still had roughly two more full weekly
# refreshes of already-paid-for quota.
#
# A cached window that has ROLLED is not bad news about the account, the quota
# behind it is new and simply unmeasured. So the row must NOT be under
# UNAVAILABLE, and must not use the word "expired" about the account.
! grep -q "wk@example.com" <<<"$(unavail_block <<<"$OUT")" \
  && ok "expired cache → the row is NOT filed under UNAVAILABLE" \
  || bad "expired cache → must not be UNAVAILABLE, a rolled window is not a dead seat (got: $OUT)"
grep -q "unmeasured, may be full" <<<"$(unmeasured_block <<<"$OUT")" \
  && ok "expired cache → it is UNMEASURED, and says the quota may be full" \
  || bad "expired cache → UNMEASURED with an invitation to measure (got: $OUT)"
! grep -q "weekly window expired" <<<"$OUT" \
  && ok "expired cache → the word 'expired' never describes the ACCOUNT again" \
  || bad "expired cache → 'weekly window expired' is back (got: $OUT)"
! grep -q "55% left" <<<"$OUT" \
  && ok "expired cache → the stale 55% (100-45) never renders" \
  || bad "expired cache → the stale 55% never renders (got: $OUT)"
cs_row="$(jq -c '.accounts[] | select(.email=="wk@example.com")' <<<"$JSON_OUT" 2>/dev/null)"
[ "$(jq -r '.weekly.expired' <<<"$cs_row" 2>/dev/null)" = "true" ] \
  && ok "expired cache (json) → weekly.expired is true" \
  || bad "expired cache (json) → weekly.expired is true (got: $cs_row)"
[ "$(jq -r '.weekly.remaining_pct' <<<"$cs_row" 2>/dev/null)" = "null" ] \
  && ok "expired cache (json) → weekly.remaining_pct is null, never the stale number" \
  || bad "expired cache (json) → weekly.remaining_pct is null (got: $cs_row)"

# --- 10b. THE SEAT'S LIFECYCLE IS NOT A QUOTA FACT (2026-08-25) --------------
#
# The operator, 2026-08-21: two seats had been cancelled and were still
# perfectly usable, with two or three more weekly refreshes each still to come,
# and every session was writing them off.
#
# The two cases the fix has to tell apart, and they differ ONLY by a date:
#   a cancelled seat whose window ROLLED  -> still live, quota unknown and very
#                                            possibly full
#   a cancelled seat past its END date    -> genuinely finished
# A tool that cannot separate these writes off a live seat carrying two more
# full weekly refreshes of already-paid-for quota, which is what happened.
seed_cancelled_seat() {  # seed_cancelled_seat <ends-date>
  mkdir -p "$RUN/.claude-pool/spare"
  printf '{"claudeAiOauth":{"accessToken":"TOK-SPARE-SEAT"}}' > "$RUN/.claude-pool/spare/.credentials.json"
  cat > "$RUN/cfg/accounts" <<EOF
spare@example.com|$RUN/.claude-pool/spare
EOF
  # a cached weekly window that has ALREADY ROLLED, the exact state that used
  # to render as "weekly window expired"
  jq -n --arg wr "$(iso_in -2d)" --arg sr "$(iso_in +2H)" \
    '{"spare@example.com":{wk_u:"45",wk_r:$wr,se_u:"20",se_r:$sr,ts:"stale fixture",ts_epoch:"0"}}' \
    > "$RUN/cfg/usage-cache.json"
  jq -n --arg ends "$1" \
    '{accounts:{"spare@example.com":{plan:"Max 20x",status:"cancelled",ends:$ends}}}' \
    > "$RUN/billing.json"
}

new_run seatlive
seed_cancelled_seat "$(date -u -v+14d '+%Y-%m-%d')"
set +e
OUT="$(CLAUDE_BILLING_JSON="$RUN/billing.json" "$SCRIPT" usage --no-refresh 2>/dev/null)"
JSON_OUT="$(CLAUDE_BILLING_JSON="$RUN/billing.json" "$SCRIPT" usage --no-refresh --json 2>/dev/null)"
set -e
! grep -q "spare@example.com" <<<"$(unavail_block <<<"$OUT")" \
  && ok "cancelled seat, window rolled → NOT unavailable: the seat has not ended" \
  || bad "cancelled seat, window rolled → must not be UNAVAILABLE (got: $OUT)"
grep -q "spare@example.com" <<<"$(unmeasured_block <<<"$OUT")" \
  && ok "cancelled seat, window rolled → filed under UNMEASURED instead" \
  || bad "cancelled seat, window rolled → belongs in UNMEASURED (got: $OUT)"
# ⚠️ The END DATE is the column that changes behaviour: for a cancelled seat the
# question is never "is this any good", it is "how many weekly windows are left".
grep -q "cancelled, quota until" <<<"$(unmeasured_block <<<"$OUT")" \
  && ok "cancelled seat, window rolled → names the deadline that actually matters" \
  || bad "cancelled seat → must name its end date (got: $OUT)"
grep -q "rota usage --record spare" <<<"$(unmeasured_block <<<"$OUT")" \
  && ok "cancelled seat, window rolled → hands over the exact command that answers it" \
  || bad "cancelled seat → must name the command (got: $OUT)"
[ "$(jq -r '.accounts[0].seat.ended' <<<"$JSON_OUT" 2>/dev/null)" = "false" ] \
  && ok "cancelled seat, window rolled (json) → seat.ended is false" \
  || bad "cancelled seat (json) → seat.ended false (got: $JSON_OUT)"
[ "$(jq -r '.accounts[0].seat.status' <<<"$JSON_OUT" 2>/dev/null)" = "cancelled" ] \
  && ok "cancelled seat, window rolled (json) → seat.status is published verbatim" \
  || bad "cancelled seat (json) → seat.status cancelled (got: $JSON_OUT)"
[ "$(jq -r '.accounts[0].unmeasured' <<<"$JSON_OUT" 2>/dev/null)" = "true" ] \
  && ok "cancelled seat, window rolled (json) → unmeasured is true" \
  || bad "cancelled seat (json) → unmeasured true (got: $JSON_OUT)"

# ⚠️ AND IT MUST BE ABLE TO FAIL. Same fixture, same rolled window, ONE field
# different, the end date is in the past. If this did not flip, the check above
# would be passing on "it never says unavailable", which is not the claim.
new_run seatended
seed_cancelled_seat "$(date -u -v-1d '+%Y-%m-%d')"
set +e
OUT="$(CLAUDE_BILLING_JSON="$RUN/billing.json" "$SCRIPT" usage --no-refresh 2>/dev/null)"
JSON_OUT="$(CLAUDE_BILLING_JSON="$RUN/billing.json" "$SCRIPT" usage --no-refresh --json 2>/dev/null)"
set -e
grep -q "spare@example.com" <<<"$(unavail_block <<<"$OUT")" \
  && ok "seat past its end date → IS unavailable" \
  || bad "seat past its end date → must be UNAVAILABLE (got: $OUT)"
grep -q "seat ended" <<<"$(unavail_block <<<"$OUT")" \
  && ok "seat past its end date → the reason is the SEAT, not the window" \
  || bad "seat past its end date → reason names the seat (got: $OUT)"
[ "$(jq -r '.accounts[0].seat.ended' <<<"$JSON_OUT" 2>/dev/null)" = "true" ] \
  && ok "seat past its end date (json) → seat.ended is true" \
  || bad "seat past its end date (json) → seat.ended true (got: $JSON_OUT)"
[ "$(jq -r '.accounts[0].unmeasured' <<<"$JSON_OUT" 2>/dev/null)" = "false" ] \
  && ok "seat past its end date (json) → an ended seat is never merely unmeasured" \
  || bad "seat past its end date (json) → unmeasured false (got: $JSON_OUT)"

# --- 10b-ii. THE DEADLINE IS min(weekly reset, SEAT END) ---------------------
#
# ⚠️ WRITTEN BECAUSE A SABOTAGE PROVED THE RULE WAS UNTESTED. Removing the seat
# end from the deadline entirely left the whole suite GREEN, so the ranking
# change was riding on nothing, and a later "simplification" back to the weekly
# reset alone would have passed review.
#
# The fixture separates the two rules by construction. Both candidates clear the
# health floor; neither is active:
#   alpha  ACTIVE seat,    weekly resets in 5 DAYS                  -> deadline +5d
#   spare  CANCELLED, ends in 2 DAYS, weekly resets in 6 DAYS       -> deadline +2d
# Ranking on the weekly reset alone picks alpha. Ranking on min(reset, end)
# picks spare, correctly, because whatever is unspent on that seat in two days
# is gone forever, while alpha's window merely rolls.
new_run seatrank
mkdir -p "$RUN/.claude-pool/primary" "$RUN/.claude-pool/alpha" "$RUN/.claude-pool/spare"
sr_exp=$(( ($(date +%s) + 86400) * 1000 ))
for a in primary alpha spare; do
  printf '{"claudeAiOauth":{"accessToken":"TOK-SR-%s","refreshToken":"rt","expiresAt":%s,"refreshTokenExpiresAt":%s}}' \
    "$a" "$sr_exp" "$sr_exp" > "$RUN/.claude-pool/$a/.credentials.json"
  printf '{"oauthAccount":{"emailAddress":"%s@example.com"}}' "$a" > "$RUN/.claude-pool/$a/.claude.json"
done
cp "$RUN/.claude-pool/primary/.credentials.json" "$RUN/.claude/.credentials.json"
printf '{"oauthAccount":{"emailAddress":"primary@example.com"}}' > "$RUN/.claude.json"
cat > "$RUN/cfg/accounts" <<EOF
primary@example.com|$RUN/.claude-pool/primary
alpha@example.com|$RUN/.claude-pool/alpha
spare@example.com|$RUN/.claude-pool/spare
EOF
# active, spent enough that the ordinary ranking decides
printf '{"seven_day":{"utilization":98,"resets_at":"%s"},"five_hour":{"utilization":50,"resets_at":"%s"}}' \
  "$(iso_in +10H)" "$(iso_in +4H)" > "$RUN/state/usage-TOK-SR-primary.json"
printf '{"seven_day":{"utilization":20,"resets_at":"%s"},"five_hour":{"utilization":0,"resets_at":"%s"}}' \
  "$(iso_in +5d)" "$(iso_in +4H)" > "$RUN/state/usage-TOK-SR-alpha.json"
printf '{"seven_day":{"utilization":20,"resets_at":"%s"},"five_hour":{"utilization":0,"resets_at":"%s"}}' \
  "$(iso_in +6d)" "$(iso_in +4H)" > "$RUN/state/usage-TOK-SR-spare.json"
jq -n --arg ends "$(date -u -v+2d '+%Y-%m-%d')" \
  '{accounts:{"spare@example.com":{plan:"Max 20x",status:"cancelled",ends:$ends},
              "alpha@example.com":{plan:"Max 20x",status:"active"}}}' > "$RUN/billing.json"
set +e
SR_OUT="$(FAKE_NEW_EMAIL=primary@example.com CLAUDE_BILLING_JSON="$RUN/billing.json" \
          "$SCRIPT" usage 2>/dev/null)"
set -e
grep -q "switch to spare@example.com" <<<"$SR_OUT" \
  && ok "seat deadline → the CANCELLED seat is picked, though its weekly reset is LATER" \
  || bad "seat deadline → must rank on min(weekly reset, seat end) (got: $SR_OUT)"
! grep -q "switch to alpha@example.com" <<<"$SR_OUT" \
  && ok "seat deadline → and the later-ending seat is not preferred just for resetting sooner" \
  || bad "seat deadline → alpha must not win (got: $SR_OUT)"

# ⚠️ AND THE SENTENCE MUST NAME THE DATE THAT ACTUALLY BOUND THE CHOICE. This
# pick was decided by the SEAT END, and the rationale used to call it "soonest
# weekly reset" anyway, then print a reset instant six days out that had nothing
# to do with it: the right answer under the wrong noun, pointing the reader at
# the wrong date to sanity-check it against.
grep -q "this seat ENDS $(date -u -v+2d '+%Y-%m-%d')" <<<"$SR_OUT" \
  && ok "seat deadline → the rationale names the SEAT END, with the date that bound the pick" \
  || bad "seat deadline → rationale must name the seat end (got: $SR_OUT)"
grep -q "LAST window" <<<"$SR_OUT" \
  && ok "seat deadline → and says why that matters: it is the seat's LAST window" \
  || bad "seat deadline → rationale must say last window (got: $SR_OUT)"
! grep -q "soonest weekly reset among" <<<"$SR_OUT" \
  && ok "seat deadline → and does NOT claim a soonest-weekly-reset rationale it did not use" \
  || bad "seat deadline → must not claim the reset decided it (got: $SR_OUT)"

# ⚠️ AND THE MACHINE SURFACE MUST BE AS HONEST AS THE SENTENCE ABOVE. The
# recommendation published this same instant under the key `weekly_resets_at`
# from 2026-08-27 to 2026-08-28, i.e. THIS pick - bound by a seat end two days
# out - shipped that end date under a name promising a weekly reset that is six
# days out. The date was right, the noun was wrong, and a consumer doing "when
# does quota come back" arithmetic on it got an answer to a question it never
# asked. `deadline_at` names the instant and `deadline_kind` names WHICH of the
# two dates it is; the kind is the load-bearing half, because a bare timestamp
# cannot tell the two apart and that ambiguity was the whole defect.
set +e
SR_JSON="$(FAKE_NEW_EMAIL=primary@example.com CLAUDE_BILLING_JSON="$RUN/billing.json" \
           "$SCRIPT" usage --json 2>/dev/null)"
set -e
[ "$(jq -r '.recommendation.email' <<<"$SR_JSON" 2>/dev/null)" = "spare@example.com" ] \
  && ok "seat deadline (json) → the seat-end-bound pick is the one published" \
  || bad "seat deadline (json) → spare must be the pick (got: $(jq -c '.recommendation' <<<"$SR_JSON" 2>/dev/null))"
[ "$(jq -r '.recommendation.deadline_at' <<<"$SR_JSON" 2>/dev/null)" = "$(date -u -v+2d '+%Y-%m-%d')T00:00:00Z" ] \
  && ok "seat deadline (json) → deadline_at carries the SEAT END, the date that bound the pick" \
  || bad "seat deadline (json) → deadline_at must be the seat end (got: $(jq -c '.recommendation' <<<"$SR_JSON" 2>/dev/null))"
[ "$(jq -r '.recommendation.deadline_kind' <<<"$SR_JSON" 2>/dev/null)" = "seat-end" ] \
  && ok "seat deadline (json) → deadline_kind says seat-end, so the date cannot be read as a reset" \
  || bad "seat deadline (json) → deadline_kind must be seat-end (got: $(jq -c '.recommendation' <<<"$SR_JSON" 2>/dev/null))"
# the misnamed key is GONE, not kept beside the honest one: nothing outside this
# repo ever read it, so a parallel field would only preserve the lie
[ "$(jq -r '.recommendation | has("weekly_resets_at")' <<<"$SR_JSON" 2>/dev/null)" = "false" ] \
  && ok "seat deadline (json) → the misnamed weekly_resets_at is removed, not left alongside" \
  || bad "seat deadline (json) → weekly_resets_at must be gone (got: $(jq -c '.recommendation' <<<"$SR_JSON" 2>/dev/null))"
# ⚠️ AND THE FIXTURE MUST GENUINELY SEPARATE THE TWO DATES. They agree on almost
# every real seat, so without this the assertions above would pass on a pool where
# `deadline_at` could still be the raw weekly reset and nobody would know.
SR_SPARE_RESET="$(jq -r '.accounts[] | select(.email=="spare@example.com") | .weekly.resets_at' <<<"$SR_JSON" 2>/dev/null)"
[ -n "$SR_SPARE_RESET" ] && [ "${SR_SPARE_RESET%%T*}" != "$(date -u -v+2d '+%Y-%m-%d')" ] \
  && ok "seat deadline (json) → the picked seat's own weekly reset is a DIFFERENT date, so the assertion discriminates" \
  || bad "seat deadline (json) → reset and seat end must differ in this fixture (reset: $SR_SPARE_RESET)"

# THE CONTROL, one field different: the seat now ends in 8 days, AFTER its own
# weekly reset at +6d, so nothing is bound by a seat end any more and alpha's
# +5d reset is the soonest deadline in the pool. The pick flips AND the noun
# flips with it - without this the assertions above would pass on a sentence
# that says "seat ENDS" unconditionally.
jq -n --arg ends "$(date -u -v+8d '+%Y-%m-%d')" \
  '{accounts:{"spare@example.com":{plan:"Max 20x",status:"cancelled",ends:$ends},
              "alpha@example.com":{plan:"Max 20x",status:"active"}}}' > "$RUN/billing.json"
set +e
SR_OUT2="$(FAKE_NEW_EMAIL=primary@example.com CLAUDE_BILLING_JSON="$RUN/billing.json" \
           "$SCRIPT" usage 2>/dev/null)"
set -e
grep -q "switch to alpha@example.com" <<<"$SR_OUT2" \
  && ok "seat deadline (control) → an end date AFTER the reset stops binding, and the soonest reset wins" \
  || bad "seat deadline (control) → alpha must win (got: $SR_OUT2)"
grep -q "soonest weekly reset among the accounts clearing the health floor" <<<"$SR_OUT2" \
  && ok "seat deadline (control) → and the rationale says RESET when the reset is what bound it" \
  || bad "seat deadline (control) → rationale must name the reset (got: $SR_OUT2)"
! grep -q "this seat ENDS" <<<"$SR_OUT2" \
  && ok "seat deadline (control) → the seat-end wording is not printed unconditionally" \
  || bad "seat deadline (control) → must not claim a seat end (got: $SR_OUT2)"
# the machine surface flips with it, and `deadline_at` is that account's OWN
# weekly reset to the instant, compared against the row rather than against a
# recomputed clock, so the two can never disagree about the same pick
set +e
SR_JSON2="$(FAKE_NEW_EMAIL=primary@example.com CLAUDE_BILLING_JSON="$RUN/billing.json" \
            "$SCRIPT" usage --json 2>/dev/null)"
set -e
[ "$(jq -r '.recommendation.deadline_kind' <<<"$SR_JSON2" 2>/dev/null)" = "reset" ] \
  && ok "seat deadline (control, json) → deadline_kind flips to reset when the reset is what bound it" \
  || bad "seat deadline (control, json) → deadline_kind must be reset (got: $(jq -c '.recommendation' <<<"$SR_JSON2" 2>/dev/null))"
SR_ALPHA_RESET="$(jq -r '.accounts[] | select(.email=="alpha@example.com") | .weekly.resets_at' <<<"$SR_JSON2" 2>/dev/null)"
[ -n "$SR_ALPHA_RESET" ] \
  && [ "$(jq -r '.recommendation.deadline_at' <<<"$SR_JSON2" 2>/dev/null)" = "$SR_ALPHA_RESET" ] \
  && ok "seat deadline (control, json) → deadline_at is the picked account's own weekly reset" \
  || bad "seat deadline (control, json) → deadline_at must equal alpha's reset $SR_ALPHA_RESET (got: $(jq -c '.recommendation' <<<"$SR_JSON2" 2>/dev/null))"

# --- 10c. a boost is dated data, and expires itself -------------------------
# A percentage is only meaningful against a known baseline, and the baseline
# moves: weekly Claude Code limits were 50% higher through 2026-08-31. A
# hard-coded sentence would still be claiming that months later, so each entry
# carries its own `through` date and simply stops printing.
new_run boost
mkdir -p "$RUN/.claude-pool/spare"
printf '{"claudeAiOauth":{"accessToken":"TOK-B"}}' > "$RUN/.claude-pool/spare/.credentials.json"
printf 'spare@example.com|%s\n' "$RUN/.claude-pool/spare" > "$RUN/cfg/accounts"
jq -n --arg t "$(date -u -v+3d '+%Y-%m-%d')" \
  '{boosts:[{through:$t,what:"Weekly limits are 50% higher"}],accounts:{}}' > "$RUN/live.json"
jq -n --arg t "$(date -u -v-3d '+%Y-%m-%d')" \
  '{boosts:[{through:$t,what:"Weekly limits are 50% higher"}],accounts:{}}' > "$RUN/past.json"
set +e
LIVE_OUT="$(CLAUDE_BILLING_JSON="$RUN/live.json" "$SCRIPT" usage --no-refresh 2>/dev/null)"
PAST_OUT="$(CLAUDE_BILLING_JSON="$RUN/past.json" "$SCRIPT" usage --no-refresh 2>/dev/null)"
set -e
grep -q "boost until" <<<"$LIVE_OUT" \
  && ok "boost → a live boost is stated, so a percentage is read against the right baseline" \
  || bad "boost → a live boost must be shown (got: $LIVE_OUT)"
! grep -q "boost until" <<<"$PAST_OUT" \
  && ok "boost → one whose date has passed disappears on its own" \
  || bad "boost → an expired boost must not print (got: $PAST_OUT)"

# --- 10d. `usage --record`: the path that works when the API will not ---------
# Measured 2026-08-21 09:35 on the pool host: GET /api/oauth/usage answered 429
# for both cancelled seats across six attempts over two and a half minutes, with
# no live session on either and a valid credential in every pool dir. The number
# was two clicks away on the vendor's usage page the whole time.
new_run record
mkdir -p "$RUN/.claude-pool/spare"
printf '{"claudeAiOauth":{"accessToken":"TOK-R"}}' > "$RUN/.claude-pool/spare/.credentials.json"
printf '{"oauthAccount":{"emailAddress":"spare@example.com"}}' > "$RUN/.claude-pool/spare/.claude.json"
printf 'spare@example.com|%s\n' "$RUN/.claude-pool/spare" > "$RUN/cfg/accounts"
set +e
REC_OUT="$(CLAUDE_POOL_DIR="$RUN/.claude-pool" "$SCRIPT" usage --record spare 12 2>&1)"; REC_RC=$?
BAD_OUT="$(CLAUDE_POOL_DIR="$RUN/.claude-pool" "$SCRIPT" usage --record spare 150 2>&1)"; BAD_RC=$?
NOALIAS="$(CLAUDE_POOL_DIR="$RUN/.claude-pool" "$SCRIPT" usage --record 2>&1)"; NOALIAS_RC=$?
set -e
[ "$REC_RC" -eq 0 ] && ok "--record → a real reading is accepted" || bad "--record rc=$REC_RC: $REC_OUT"
[ "$BAD_RC" -ne 0 ] && ok "--record → refuses a percentage outside 0-100" || bad "--record accepted 150%: $BAD_OUT"
[ "$NOALIAS_RC" -ne 0 ] && ok "--record → refuses without an alias and a number" || bad "--record accepted nothing: $NOALIAS"
# ⚠️ IT MUST CARRY THE WINDOW IT BELONGS TO. A measurement with no window is
# indistinguishable from a fresh one forever, which is the very defect this
# whole change is about, a number outliving the window it described.
[ -n "$(jq -r '.accounts["spare@example.com"].weekly_resets_at // empty' "$RUN/cfg/human-usage.json" 2>/dev/null)" ] \
  && ok "--record → the reading is stamped with the window it belongs to" \
  || bad "--record → stored without a window (got: $(cat "$RUN/cfg/human-usage.json" 2>/dev/null))"
[ "$(jq -r '.accounts["spare@example.com"].weekly_used' "$RUN/cfg/human-usage.json" 2>/dev/null)" = "12" ] \
  && ok "--record → stores the USED percentage, the polarity the vendor page prints" \
  || bad "--record → weekly_used wrong (got: $(cat "$RUN/cfg/human-usage.json" 2>/dev/null))"
# ⚠️ AND IT MUST SURVIVE THE READ WITH ITS TIMESTAMP INTACT. Tab is IFS
# *whitespace*, so a tab-joined row collapses its two routinely-empty 5h fields
# and shifts the stamp out of position: the recorded number then rendered with
# NO age at all, a hand-typed figure looking freshly measured, which is exactly
# the dishonesty this change exists to remove.
set +e
REC_TABLE="$(CLAUDE_POOL_DIR="$RUN/.claude-pool" CLAUDE_HUMAN_USAGE="$RUN/cfg/human-usage.json" \
             "$SCRIPT" usage --no-refresh 2>/dev/null)"
REC_JSON="$(CLAUDE_POOL_DIR="$RUN/.claude-pool" CLAUDE_HUMAN_USAGE="$RUN/cfg/human-usage.json" \
            "$SCRIPT" usage --no-refresh --json 2>/dev/null)"
set -e
[ "$(jq -r '.accounts[0].weekly.used_pct' <<<"$REC_JSON" 2>/dev/null)" = "12" ] \
  && ok "--record → the recorded reading is what the usage report then shows" \
  || bad "--record → the reading never reached the report (got: $REC_JSON)"
grep -qE 'cached [A-Z][a-z]{2} [0-9]' <<<"$REC_TABLE" \
  && ok "--record → and it renders WITH its age, never as a stamp-less number" \
  || bad "--record → the read-at stamp was lost on the way back (got: $REC_TABLE)"

# --- 11. move_oauth_account copies the WHOLE object and leaves siblings alone -
new_run oauthmove
mkdir -p "$RUN/.claude-pool/alpha" "$RUN/.claude-pool/beta"
OM_EXP=$(( ($(date +%s) + 86400) * 1000 ))
printf 'OLD-CRED' > "$RUN/.claude/.credentials.json"
printf '{"claudeAiOauth":{"accessToken":"TOK-OM-A","refreshToken":"rt-a","expiresAt":%s,"refreshTokenExpiresAt":%s}}' \
  "$OM_EXP" "$OM_EXP" > "$RUN/.claude-pool/alpha/.credentials.json"
printf '{"claudeAiOauth":{"accessToken":"TOK-OM-B","refreshToken":"rt-b","expiresAt":%s,"refreshTokenExpiresAt":%s}}' \
  "$OM_EXP" "$OM_EXP" > "$RUN/.claude-pool/beta/.credentials.json"
cat > "$RUN/cfg/accounts" <<EOF
alpha@example.com|$RUN/.claude-pool/alpha
beta@example.com|$RUN/.claude-pool/beta
EOF
jq -n '{oauthAccount:{emailAddress:"alpha@example.com",accountUuid:"old-uuid"},
        someOtherTopLevelKey:"keep-me", theme:"dark"}' > "$RUN/.claude.json"
jq -n '{oauthAccount:{emailAddress:"beta@example.com",accountUuid:"new-uuid-1234",
        organizationUuid:"org-5678",extra:{nested:true}}}' > "$RUN/.claude-pool/beta/.claude.json"
set +e
OUT="$(FAKE_OLD_EMAIL=alpha@example.com FAKE_NEW_EMAIL=beta@example.com FAKE_LAG=0 FAKE_KEYCHAIN=none FAKE_CLOBBER='' \
  "$SCRIPT" switch-all "beta@example.com" 2>&1)"
RC=$?
set -e
[ "$RC" -eq 0 ] && ok "move_oauth_account → switch-all exits 0" || bad "move_oauth_account → switch-all exits 0 (got $RC: $OUT)"
[ "$(jq -r '.oauthAccount.accountUuid' "$RUN/.claude.json")" = "new-uuid-1234" ] \
  && ok "move_oauth_account → copies the target's WHOLE oauthAccount object (accountUuid)" \
  || bad "move_oauth_account → copies accountUuid (got: $(jq -c '.oauthAccount' "$RUN/.claude.json"))"
[ "$(jq -r '.oauthAccount.organizationUuid' "$RUN/.claude.json")" = "org-5678" ] \
  && ok "move_oauth_account → copies organizationUuid too, not hand-built fields" \
  || bad "move_oauth_account → copies organizationUuid (got: $(jq -c '.oauthAccount' "$RUN/.claude.json"))"
[ "$(jq -r '.oauthAccount.extra.nested' "$RUN/.claude.json")" = "true" ] \
  && ok "move_oauth_account → copies nested fields verbatim" \
  || bad "move_oauth_account → copies nested fields (got: $(jq -c '.oauthAccount' "$RUN/.claude.json"))"
[ "$(jq -r '.someOtherTopLevelKey' "$RUN/.claude.json")" = "keep-me" ] \
  && ok "move_oauth_account → preserves an unrelated top-level key" \
  || bad "move_oauth_account → preserves an unrelated top-level key (got: $(cat "$RUN/.claude.json"))"
[ "$(jq -r '.theme' "$RUN/.claude.json")" = "dark" ] \
  && ok "move_oauth_account → preserves a second unrelated top-level key" \
  || bad "move_oauth_account → preserves a second unrelated top-level key (got: $(cat "$RUN/.claude.json"))"

# --- 12. `active` exits 3 when identity is unresolvable -----------------------
# No oauthAccount, no shared credential to fingerprint, and the one pool
# account has no stored credential either, nothing to resolve from.
new_run unresolvable
mkdir -p "$RUN/.claude-pool/nobody"
cat > "$RUN/cfg/accounts" <<EOF
nobody@example.com|$RUN/.claude-pool/nobody
EOF
set +e
OUT="$("$SCRIPT" active 2>/dev/null)"
RC=$?
set -e
[ "$RC" -eq 3 ] && ok "unresolvable identity → active exits 3" || bad "unresolvable identity → active exits 3 (got $RC: $OUT)"
[ -z "$OUT" ] && ok "unresolvable identity → active prints nothing to stdout" \
  || bad "unresolvable identity → active prints nothing to stdout (got: $OUT)"

# --- 13. the shared-account probe must NOT set CLAUDE_CONFIG_DIR --------------
# THE 2026-07-30 ROOT CAUSE. Claude Code resolves $CLAUDE_CONFIG_DIR/.claude.json,
# so CLAUDE_CONFIG_DIR=$HOME/.claude aims `auth status` at the NESTED
# ~/.claude/.claude.json, a different file from the ~/.claude.json every real
# session reads. The probe must run with the variable UNSET, and must also STRIP an
# inherited one, which is why this whole run exports a poison value: if the script
# merely stopped setting it but forgot `env -u`, the poison would leak through and
# the stub would record it.
new_run probeenv
mkdir -p "$RUN/.claude-pool/solo"
printf '{"claudeAiOauth":{"accessToken":"TOK-PROBE"}}' > "$RUN/.claude-pool/solo/.credentials.json"
printf '{"oauthAccount":{"emailAddress":"solo@example.com"}}' > "$RUN/.claude-pool/solo/.claude.json"
printf '{"oauthAccount":{"emailAddress":"solo@example.com"}}' > "$RUN/.claude.json"
# the nested trap file, holding a DIFFERENT account, a wrong-file probe would see it
printf '{"oauthAccount":{"emailAddress":"nested-stale@example.com"}}' > "$RUN/.claude/.claude.json"
cat > "$RUN/cfg/accounts" <<EOF
solo@example.com|$RUN/.claude-pool/solo
EOF
printf '{"seven_day":{"utilization":16,"resets_at":"%s"},"five_hour":{"utilization":40,"resets_at":"%s"}}' \
  "$(iso_in +3d)" "$(iso_in +2H)" > "$RUN/state/usage-TOK-PROBE.json"
set +e
OUT="$(CLAUDE_CONFIG_DIR="$RUN/.claude" FAKE_NEW_EMAIL=solo@example.com "$SCRIPT" usage 2>/dev/null)"
RC=$?
set -e
[ "$RC" -eq 0 ] && ok "probe env → usage exits 0" || bad "probe env → usage exits 0 (got $RC: $OUT)"
[ -s "$RUN/state/authenv" ] \
  && ok "probe env → auth status really was probed (so the next assertion means something)" \
  || bad "probe env → auth status really was probed (authenv empty)"
[ "$(sort -u "$RUN/state/authenv")" = "UNSET" ] \
  && ok "probe env → every auth-status probe ran with CLAUDE_CONFIG_DIR UNSET, never \$HOME/.claude" \
  || bad "probe env → every probe ran with CLAUDE_CONFIG_DIR UNSET (recorded: $(sort -u "$RUN/state/authenv" | tr '\n' ' '))"

# --- 14. both polarities, and every SENTENCE still leads with USED ------------
# Claude Code's statusline reports USED ("Weekly: 16%"); this tool used to report
# LEFT. On 2026-07-30 "84% left" next to "16%" was read as the two surfaces naming
# different ACCOUNTS, so both numbers are printed, labelled, everywhere.
#
# REVISED 2026-08-07 with the metered layout. The two ACTIVE window rows now lead
# with "% left" because they are drawn beside a bar whose FILLED cells are the left
# figure, a row saying "16% used" next to an 84%-full bar would make you read the
# bar backwards. Everything that is a SENTENCE rather than a meter, the exclusion
# reasons, the recommendation, the mode line, still leads with USED, in the
# statusline's own position. left_first_prose() is the guard for that split: it
# finds any left-first pair that is NOT one of the metered rows.
new_run polarity
mkdir -p "$RUN/.claude-pool/solo"
printf '{"claudeAiOauth":{"accessToken":"TOK-POL"}}' > "$RUN/.claude-pool/solo/.credentials.json"
printf '{"oauthAccount":{"emailAddress":"solo@example.com"}}' > "$RUN/.claude-pool/solo/.claude.json"
printf '{"oauthAccount":{"emailAddress":"solo@example.com"}}' > "$RUN/.claude.json"
cat > "$RUN/cfg/accounts" <<EOF
solo@example.com|$RUN/.claude-pool/solo
EOF
printf '{"seven_day":{"utilization":16,"resets_at":"%s"},"five_hour":{"utilization":40,"resets_at":"%s"}}' \
  "$(iso_in +3d)" "$(iso_in +2H)" > "$RUN/state/usage-TOK-POL.json"
set +e
OUT="$(FAKE_NEW_EMAIL=solo@example.com "$SCRIPT" usage 2>/dev/null)"
JSON_OUT="$(FAKE_NEW_EMAIL=solo@example.com "$SCRIPT" usage --json 2>/dev/null)"
RC=$?
set -e
[ "$RC" -eq 0 ] && ok "polarity → usage exits 0" || bad "polarity → usage exits 0 (got $RC: $OUT)"
grep -qE '^    weekly  [█░]{15} +84% left · 16% used' <<<"$OUT" \
  && ok "polarity → the metered weekly row carries BOTH polarities, LEFT first so it agrees with its own bar" \
  || bad "polarity → metered weekly row is bar + left-first pair (got: $OUT)"
grep -qE '^    5h      [█░]{15} +60% left · 40% used' <<<"$OUT" \
  && ok "polarity → the metered 5h row carries both polarities the same way" \
  || bad "polarity → metered 5h row is bar + left-first pair (got: $OUT)"
POL_PROSE="$(left_first_prose <<<"$OUT")"
[ -z "$POL_PROSE" ] \
  && ok "polarity → no SENTENCE anywhere in the report leads with left; only the metered rows do" \
  || bad "polarity → a sentence leads with left (got: $POL_PROSE)"
grep -q "16% used · 84% left" <<<"$OUT" \
  && ok "polarity → the used-first pair is still present, so the statusline's number is still findable" \
  || bad "polarity → used-first pair still present (got: $OUT)"
grep -q "40% used · 60% left" <<<"$OUT" \
  && ok "polarity → the 5h used-first pair is still present too" \
  || bad "polarity → 5h used-first pair still present (got: $OUT)"
grep -q "is at weekly 16% used · 84% left" <<<"$OUT" \
  && ok "polarity → the recommendation sentence carries both, used first" \
  || bad "polarity → the recommendation sentence carries both used-first (got: $OUT)"
grep -q "clears the health floor (weekly 16% used · 84% left; 5h 40% used · 60% left)" <<<"$OUT" \
  && ok "polarity → the stay-put rationale carries both windows used-first" \
  || bad "polarity → the stay-put rationale is used-first (got: $OUT)"
pol_row="$(jq -c '.accounts[] | select(.email=="solo@example.com")' <<<"$JSON_OUT" 2>/dev/null)"
[ "$(jq -r '.weekly.remaining_pct' <<<"$pol_row" 2>/dev/null)" = "84" ] \
  && ok "polarity (json) → remaining_pct is untouched (published shape)" \
  || bad "polarity (json) → remaining_pct is untouched (got: $pol_row)"
[ "$(jq -r '.weekly.used_pct' <<<"$pol_row" 2>/dev/null)" = "16" ] \
  && ok "polarity (json) → weekly.used_pct added alongside it" \
  || bad "polarity (json) → weekly.used_pct added (got: $pol_row)"
[ "$(jq -r '.five_hour.used_pct' <<<"$pol_row" 2>/dev/null)" = "40" ] \
  && ok "polarity (json) → five_hour.used_pct added alongside it" \
  || bad "polarity (json) → five_hour.used_pct added (got: $pol_row)"

# --- 15. the nested stale config is a live trap and must be reported ----------
# ~/.claude/.claude.json is not ours to delete, so `usage` warns whenever it names
# a different account than ~/.claude.json, and stays SILENT when they agree.
new_run nested
mkdir -p "$RUN/.claude-pool/solo"
printf '{"claudeAiOauth":{"accessToken":"TOK-NEST"}}' > "$RUN/.claude-pool/solo/.credentials.json"
printf '{"oauthAccount":{"emailAddress":"live@example.com"}}' > "$RUN/.claude-pool/solo/.claude.json"
printf '{"oauthAccount":{"emailAddress":"live@example.com"}}' > "$RUN/.claude.json"
printf '{"oauthAccount":{"emailAddress":"stale@example.com"}}' > "$RUN/.claude/.claude.json"
cat > "$RUN/cfg/accounts" <<EOF
live@example.com|$RUN/.claude-pool/solo
EOF
printf '{"seven_day":{"utilization":20,"resets_at":"%s"},"five_hour":{"utilization":20,"resets_at":"%s"}}' \
  "$(iso_in +3d)" "$(iso_in +2H)" > "$RUN/state/usage-TOK-NEST.json"
set +e
OUT="$(FAKE_NEW_EMAIL=live@example.com "$SCRIPT" usage 2>/dev/null)"
JSON_OUT="$(FAKE_NEW_EMAIL=live@example.com "$SCRIPT" usage --json 2>/dev/null)"
RC=$?
set -e
[ "$RC" -eq 0 ] && ok "nested config → usage exits 0" || bad "nested config → usage exits 0 (got $RC: $OUT)"
grep -q "stale NESTED config" <<<"$OUT" \
  && ok "nested config → warns that a nested config exists" \
  || bad "nested config → warns a nested config exists (got: $OUT)"
grep -q "stale@example.com" <<<"$OUT" && grep -q "live@example.com" <<<"$OUT" \
  && ok "nested config → names BOTH values so the drift is visible" \
  || bad "nested config → names both values (got: $OUT)"
# shellcheck disable=SC2016  # the warning prints the literal text "$HOME"; nothing to expand
grep -qF 'CLAUDE_CONFIG_DIR=$HOME/.claude' <<<"$OUT" \
  && ok "nested config → says exactly which probe shape reads the wrong file" \
  || bad "nested config → names the probe shape that reads it (got: $OUT)"
[ -n "$(jq -r '.active.nested_config_warning // empty' <<<"$JSON_OUT" 2>/dev/null)" ] \
  && ok "nested config (json) → surfaced as active.nested_config_warning" \
  || bad "nested config (json) → surfaced in json (got: $(jq -c '.active' <<<"$JSON_OUT" 2>/dev/null))"
# now make the two agree, the warning must go completely quiet
printf '{"oauthAccount":{"emailAddress":"live@example.com"}}' > "$RUN/.claude/.claude.json"
set +e
OUT2="$(FAKE_NEW_EMAIL=live@example.com "$SCRIPT" usage 2>&1)"
JSON2="$(FAKE_NEW_EMAIL=live@example.com "$SCRIPT" usage --json 2>/dev/null)"
set -e
! grep -q "NESTED" <<<"$OUT2" \
  && ok "nested config → silent when the two configs agree (no needless alarm)" \
  || bad "nested config → silent when they agree (got: $OUT2)"
[ "$(jq -r '.active.nested_config_warning' <<<"$JSON2" 2>/dev/null)" = "null" ] \
  && ok "nested config (json) → null when the two configs agree" \
  || bad "nested config (json) → null when they agree (got: $(jq -c '.active' <<<"$JSON2" 2>/dev/null))"

# --- 16. auth status restored as a real third opinion ------------------------
# Now that it is probed correctly it should normally AGREE with oauthAccount, and a
# disagreement is a genuine warning rather than something to disclaim.
new_run thirdopinion
mkdir -p "$RUN/.claude-pool/solo"
printf '{"claudeAiOauth":{"accessToken":"TOK-3RD"}}' > "$RUN/.claude-pool/solo/.credentials.json"
printf '{"oauthAccount":{"emailAddress":"solo@example.com"}}' > "$RUN/.claude-pool/solo/.claude.json"
printf '{"oauthAccount":{"emailAddress":"solo@example.com"}}' > "$RUN/.claude.json"
cat > "$RUN/cfg/accounts" <<EOF
solo@example.com|$RUN/.claude-pool/solo
EOF
printf '{"seven_day":{"utilization":20,"resets_at":"%s"},"five_hour":{"utilization":20,"resets_at":"%s"}}' \
  "$(iso_in +3d)" "$(iso_in +2H)" > "$RUN/state/usage-TOK-3RD.json"
set +e
AGREE_JSON="$(FAKE_NEW_EMAIL=solo@example.com "$SCRIPT" usage --json 2>/dev/null)"
# --verbose: the identity/fingerprint line is DETAIL, not a warning, so the
# default three-bucket view no longer carries it (2026-08-07). It still prints,
# that is what --verbose is for, and what this asserts.
AGREE_OUT="$(FAKE_NEW_EMAIL=solo@example.com "$SCRIPT" usage --verbose 2>&1)"
AGREE_PLAIN="$(FAKE_NEW_EMAIL=solo@example.com "$SCRIPT" usage 2>&1)"
DIS_JSON="$(FAKE_NEW_EMAIL=someone-else@example.com "$SCRIPT" usage --json 2>/dev/null)"
DIS_OUT="$(FAKE_NEW_EMAIL=someone-else@example.com "$SCRIPT" usage 2>&1)"
set -e
[ "$(jq -r '.active.auth_status' <<<"$AGREE_JSON" 2>/dev/null)" = "solo@example.com" ] \
  && ok "third opinion → auth status is consulted and recorded" \
  || bad "third opinion → auth status is recorded (got: $(jq -c '.active' <<<"$AGREE_JSON" 2>/dev/null))"
[ "$(jq -r '.active.auth_warning' <<<"$AGREE_JSON" 2>/dev/null)" = "null" ] \
  && ok "third opinion → no warning when it agrees" \
  || bad "third opinion → no warning when it agrees (got: $(jq -c '.active' <<<"$AGREE_JSON" 2>/dev/null))"
grep -q 'auth status\` agrees' <<<"$AGREE_OUT" \
  && ok "third opinion → agreement is stated as corroboration, not disclaimed (--verbose)" \
  || bad "third opinion → agreement is stated as corroboration (got: $AGREE_OUT)"
! grep -q 'identity:' <<<"$AGREE_PLAIN" \
  && ok "third opinion → the routine identity line is DETAIL: absent from the default view" \
  || bad "third opinion → identity line stays behind --verbose (got: $AGREE_PLAIN)"
[ -n "$(jq -r '.active.auth_warning // empty' <<<"$DIS_JSON" 2>/dev/null)" ] \
  && ok "third opinion → disagreement IS a warning now" \
  || bad "third opinion → disagreement is a warning (got: $(jq -c '.active' <<<"$DIS_JSON" 2>/dev/null))"
grep -q "someone-else@example.com" <<<"$DIS_OUT" && grep -q "solo@example.com" <<<"$DIS_OUT" \
  && ok "third opinion → the warning names both answers" \
  || bad "third opinion → the warning names both answers (got: $DIS_OUT)"
! grep -q "not a trustworthy identity source" <<<"$DIS_OUT" \
  && ok "third opinion → the retired 'not trustworthy' disclaimer is gone" \
  || bad "third opinion → the retired disclaimer is gone (got: $DIS_OUT)"

# --- 17. FRESH window: 100% headroom, no active window, and RECOMMENDABLE -----
# The 2026-07-30 bug. When an account's weekly window has reset and nothing has been
# spent since, the API answers utilization 0.0 with resets_at NULL, the healthiest
# possible state. The old code read the missing resets_at as "incomplete usage data",
# rendered "resets no active window" and EXCLUDED the row, so the account with the
# most headroom was the one account the tool refused to recommend (seen live on
# ~/.claude-pool/primary). Here primary is fully fresh and alpha is healthy with a
# REAL reset in 2 days: fresh must be eligible, must render honestly, and must rank
# BEHIND alpha because nothing of its headroom is expiring.
#
# The ACTIVE account is a third slot, `spent`, taken to 99% used: since 2026-08-06 the
# burn-down rule holds him on whatever he is already on until it is spent, so the
# ranking this scenario is about is only reached once the active account is done. (It
# used to make the fresh account itself the active one, which now, correctly, just
# says "stay".)
new_run fresh
mkdir -p "$RUN/.claude-pool/spent" "$RUN/.claude-pool/primary" "$RUN/.claude-pool/alpha"
printf '{"claudeAiOauth":{"accessToken":"TOK-FRESH-SPENT"}}' > "$RUN/.claude/.credentials.json"
cp "$RUN/.claude/.credentials.json" "$RUN/.claude-pool/spent/.credentials.json"
printf '{"oauthAccount":{"emailAddress":"spent@example.com"}}' > "$RUN/.claude-pool/spent/.claude.json"
printf '{"claudeAiOauth":{"accessToken":"TOK-FRESH"}}' > "$RUN/.claude-pool/primary/.credentials.json"
printf '{"oauthAccount":{"emailAddress":"primary@example.com"}}' > "$RUN/.claude-pool/primary/.claude.json"
printf '{"claudeAiOauth":{"accessToken":"TOK-FRESH-ALPHA"}}' > "$RUN/.claude-pool/alpha/.credentials.json"
printf '{"oauthAccount":{"emailAddress":"alpha@example.com"}}' > "$RUN/.claude-pool/alpha/.claude.json"
printf '{"oauthAccount":{"emailAddress":"spent@example.com"}}' > "$RUN/.claude.json"
cat > "$RUN/cfg/accounts" <<EOF
spent@example.com|$RUN/.claude-pool/spent
primary@example.com|$RUN/.claude-pool/primary
alpha@example.com|$RUN/.claude-pool/alpha
EOF
printf '{"seven_day":{"utilization":99,"resets_at":"%s"},"five_hour":{"utilization":40,"resets_at":"%s"}}' \
  "$(iso_in +3H)" "$(iso_in +1H)" > "$RUN/state/usage-TOK-FRESH-SPENT.json"
# verbatim shape of the live response that exposed the bug
printf '{"seven_day":{"utilization":0.0,"resets_at":null,"limit_dollars":null},"five_hour":{"utilization":0.0,"resets_at":null}}' \
  > "$RUN/state/usage-TOK-FRESH.json"
printf '{"seven_day":{"utilization":18,"resets_at":"%s"},"five_hour":{"utilization":23,"resets_at":"%s"}}' \
  "$(iso_in +2d)" "$(iso_in +2H)" > "$RUN/state/usage-TOK-FRESH-ALPHA.json"
set +e
OUT="$(FAKE_NEW_EMAIL=spent@example.com "$SCRIPT" usage 2>/dev/null)"
VOUT="$(FAKE_NEW_EMAIL=spent@example.com "$SCRIPT" usage --verbose 2>/dev/null)"
JSON_OUT="$(FAKE_NEW_EMAIL=spent@example.com "$SCRIPT" usage --json 2>/dev/null)"
RC=$?
set -e
[ "$RC" -eq 0 ] && ok "fresh window → usage exits 0" || bad "fresh window → usage exits 0 (got $RC: $OUT)"
# A fully unspent account is the healthiest thing in the pool, so its place in the
# report is ALTERNATIVES with 100% left in both windows, the bucket is the assertion.
grep -qE '^  ✓ primary@example\.com +weekly 100% left · 5h 100% left' <<<"$(alt_block <<<"$OUT")" \
  && ok "fresh window → lands in ALTERNATIVES at 100% left in both windows" \
  || bad "fresh window → ALTERNATIVES row at 100%/100% (got: $OUT)"
grep -q "weekly no active window yet (starts on first use)" <<<"$VOUT" \
  && ok "fresh window → --verbose says the window has not STARTED, rather than inventing a reset" \
  || bad "fresh window → --verbose explains the unstarted window (got: $VOUT)"
! grep -q "resets no active window" <<<"$OUT$VOUT" \
  && ok "fresh window → never prints a fake reset ('resets no active window')" \
  || bad "fresh window → never prints a fake reset (got: $OUT)"
! grep -q "primary@example.com" <<<"$(unavail_block <<<"$OUT")" \
  && ok "fresh window → the row is NOT in UNAVAILABLE" \
  || bad "fresh window → the row must not be UNAVAILABLE (got: $(unavail_block <<<"$OUT"))"
! grep -q "skipped" <<<"$(alt_block <<<"$VOUT")" \
  && ok "fresh window → the row carries no skip reason, even under --verbose" \
  || bad "fresh window → the row is not skipped (got: $(alt_block <<<"$VOUT"))"
! grep -q "incomplete usage data" <<<"$OUT" \
  && ok "fresh window → never called 'incomplete usage data'" \
  || bad "fresh window → never called incomplete (got: $OUT)"
fresh_row="$(jq -c '.accounts[] | select(.email=="primary@example.com")' <<<"$JSON_OUT" 2>/dev/null)"
[ "$(jq -r '.recommendable' <<<"$fresh_row" 2>/dev/null)" = "true" ] \
  && ok "fresh window → recommendable, not excluded" \
  || bad "fresh window → recommendable (got: $fresh_row)"
grep -q "switch to alpha@example.com" <<<"$OUT" \
  && ok "fresh window → ranks BEHIND a healthy account with a real reset (alpha wins)" \
  || bad "fresh window → ranks behind alpha (got: $OUT)"
[ "$(jq -r '.recommendation.email' <<<"$JSON_OUT" 2>/dev/null)" = "alpha@example.com" ] \
  && ok "fresh window (json) → recommendation is alpha, the account whose headroom expires" \
  || bad "fresh window (json) → recommendation is alpha (got: $(jq -c '.recommendation' <<<"$JSON_OUT" 2>/dev/null))"
[ "$(jq -r '.recommendation.weekly_fresh' <<<"$JSON_OUT" 2>/dev/null)" = "false" ] \
  && ok "fresh window (json) → recommendation.weekly_fresh false when the pick has a real reset" \
  || bad "fresh window (json) → recommendation.weekly_fresh false (got: $(jq -c '.recommendation' <<<"$JSON_OUT" 2>/dev/null))"

# --- 17b. the --json shape of a fresh window ---------------------------------
# A consumer must be able to tell "fresh" (100% left, window not started) from
# "unknown" (no numbers at all) without guessing, and both are resets_at:null.
[ "$(jq -r '.weekly.remaining_pct' <<<"$fresh_row" 2>/dev/null)" = "100" ] \
  && ok "fresh window (json) → weekly.remaining_pct is 100" \
  || bad "fresh window (json) → weekly.remaining_pct is 100 (got: $fresh_row)"
[ "$(jq -r '.weekly.used_pct' <<<"$fresh_row" 2>/dev/null)" = "0" ] \
  && ok "fresh window (json) → weekly.used_pct is 0" \
  || bad "fresh window (json) → weekly.used_pct is 0 (got: $fresh_row)"
[ "$(jq -r '.weekly.resets_at' <<<"$fresh_row" 2>/dev/null)" = "null" ] \
  && ok "fresh window (json) → weekly.resets_at is null, never an invented stamp" \
  || bad "fresh window (json) → weekly.resets_at is null (got: $fresh_row)"
[ "$(jq -r '.weekly.fresh' <<<"$fresh_row" 2>/dev/null)" = "true" ] \
  && ok "fresh window (json) → weekly.fresh flags it as fresh, not unknown" \
  || bad "fresh window (json) → weekly.fresh is true (got: $fresh_row)"
[ "$(jq -r '.weekly.expired' <<<"$fresh_row" 2>/dev/null)" = "false" ] \
  && ok "fresh window (json) → weekly.expired stays false (fresh is not expired)" \
  || bad "fresh window (json) → weekly.expired is false (got: $fresh_row)"
[ "$(jq -r '.five_hour | [.remaining_pct,.used_pct,.resets_at,.fresh] | @csv' <<<"$fresh_row" 2>/dev/null)" = '100,0,,true' ] \
  && ok "fresh window (json) → the 5h window carries the same fresh shape" \
  || bad "fresh window (json) → 5h fresh shape (got: $(jq -c '.five_hour' <<<"$fresh_row" 2>/dev/null))"
gm_row="$(jq -c '.accounts[] | select(.email=="alpha@example.com")' <<<"$JSON_OUT" 2>/dev/null)"
[ "$(jq -r '.weekly.fresh' <<<"$gm_row" 2>/dev/null)" = "false" ] \
  && ok "fresh window (json) → a NORMAL window is fresh:false, so the flag discriminates" \
  || bad "fresh window (json) → a normal window is fresh:false (got: $gm_row)"

# --- 18. a fresh account WINS when it is the only one clearing the floor ------
# Same rule, other end: the active account is SPENT (99% used, at/under the burn-down
# threshold, so the hold is over) and everything else is unusable, so the fully
# unspent account is the pick, and the sentence must not refer to a reset time it
# does not have.
new_run freshwins
mkdir -p "$RUN/.claude-pool/alpha" "$RUN/.claude-pool/primary"
printf '{"claudeAiOauth":{"accessToken":"TOK-FW-SHARED"}}' > "$RUN/.claude/.credentials.json"
cp "$RUN/.claude/.credentials.json" "$RUN/.claude-pool/alpha/.credentials.json"
printf '{"oauthAccount":{"emailAddress":"alpha@example.com"}}' > "$RUN/.claude-pool/alpha/.claude.json"
printf '{"claudeAiOauth":{"accessToken":"TOK-FW-PRIMARY"}}' > "$RUN/.claude-pool/primary/.credentials.json"
printf '{"oauthAccount":{"emailAddress":"primary@example.com"}}' > "$RUN/.claude-pool/primary/.claude.json"
printf '{"oauthAccount":{"emailAddress":"alpha@example.com"}}' > "$RUN/.claude.json"
cat > "$RUN/cfg/accounts" <<EOF
alpha@example.com|$RUN/.claude-pool/alpha
primary@example.com|$RUN/.claude-pool/primary
EOF
printf '{"seven_day":{"utilization":99,"resets_at":"%s"},"five_hour":{"utilization":80,"resets_at":"%s"}}' \
  "$(iso_in +2d)" "$(iso_in +2H)" > "$RUN/state/usage-TOK-FW-SHARED.json"
printf '{"seven_day":{"utilization":0.0,"resets_at":null},"five_hour":{"utilization":0.0,"resets_at":null}}' \
  > "$RUN/state/usage-TOK-FW-PRIMARY.json"
set +e
OUT="$(FAKE_NEW_EMAIL=alpha@example.com "$SCRIPT" usage 2>/dev/null)"
JSON_OUT="$(FAKE_NEW_EMAIL=alpha@example.com "$SCRIPT" usage --json 2>/dev/null)"
RC=$?
set -e
[ "$RC" -eq 0 ] && ok "fresh wins → usage exits 0" || bad "fresh wins → usage exits 0 (got $RC: $OUT)"
grep -q "switch to primary@example.com" <<<"$OUT" \
  && ok "fresh wins → the fresh account is the pick when it is the only one clearing the floor" \
  || bad "fresh wins → the fresh account is the pick (got: $OUT)"
grep -q "weekly window has not started yet" <<<"$OUT" \
  && ok "fresh wins → the rationale says the window has not started instead of naming a reset" \
  || bad "fresh wins → the rationale explains the fresh pick (got: $OUT)"
! grep -q "soonest weekly reset among" <<<"$OUT" \
  && ok "fresh wins → does NOT claim a soonest-reset rationale it cannot have" \
  || bad "fresh wins → no soonest-reset rationale (got: $OUT)"
[ "$(jq -r '.recommendation.action' <<<"$JSON_OUT" 2>/dev/null)" = "switch" ] \
  && ok "fresh wins (json) → action is switch" \
  || bad "fresh wins (json) → action is switch (got: $(jq -c '.recommendation' <<<"$JSON_OUT" 2>/dev/null))"
[ "$(jq -r '.recommendation.deadline_at' <<<"$JSON_OUT" 2>/dev/null)" = "null" ] \
  && ok "fresh wins (json) → deadline_at is null, not an empty string" \
  || bad "fresh wins (json) → deadline_at is null (got: $(jq -c '.recommendation' <<<"$JSON_OUT" 2>/dev/null))"
# ⚠️ AND THE KIND GOES NULL WITH IT. A kind beside no date would be a claim about
# a deadline that does not exist, the same shape of dishonesty this pair replaced;
# rota_seat_deadline returns BOTH fields empty for a seat with neither date, and
# the published pair mirrors that rather than inventing a default of "reset".
[ "$(jq -r '.recommendation.deadline_kind' <<<"$JSON_OUT" 2>/dev/null)" = "null" ] \
  && ok "fresh wins (json) → deadline_kind is null too, never a kind without a date" \
  || bad "fresh wins (json) → deadline_kind is null (got: $(jq -c '.recommendation' <<<"$JSON_OUT" 2>/dev/null))"
[ "$(jq -r '.recommendation.weekly_fresh' <<<"$JSON_OUT" 2>/dev/null)" = "true" ] \
  && ok "fresh wins (json) → weekly_fresh marks the null reset as fresh, not missing" \
  || bad "fresh wins (json) → weekly_fresh is true (got: $(jq -c '.recommendation' <<<"$JSON_OUT" 2>/dev/null))"

# --- 19. genuinely INCOMPLETE data is still excluded --------------------------
# The fix must not swallow the real failure modes it sits next to. Two shapes:
# `dead` has no usage fixture at all (the fetch fails), and `partial` answers 200
# with seven_day.utilization but NO five_hour.utilization. Neither is fresh, and
# both must stay out of the pick with a reason on the row.
new_run incomplete
mkdir -p "$RUN/.claude-pool/alpha" "$RUN/.claude-pool/dead" "$RUN/.claude-pool/partial"
printf '{"claudeAiOauth":{"accessToken":"TOK-INC-SHARED"}}' > "$RUN/.claude/.credentials.json"
cp "$RUN/.claude/.credentials.json" "$RUN/.claude-pool/alpha/.credentials.json"
printf '{"oauthAccount":{"emailAddress":"alpha@example.com"}}' > "$RUN/.claude-pool/alpha/.claude.json"
printf '{"claudeAiOauth":{"accessToken":"TOK-INC-DEAD"}}' > "$RUN/.claude-pool/dead/.credentials.json"
printf '{"oauthAccount":{"emailAddress":"dead@example.com"}}' > "$RUN/.claude-pool/dead/.claude.json"
printf '{"claudeAiOauth":{"accessToken":"TOK-INC-PARTIAL"}}' > "$RUN/.claude-pool/partial/.credentials.json"
printf '{"oauthAccount":{"emailAddress":"partial@example.com"}}' > "$RUN/.claude-pool/partial/.claude.json"
printf '{"oauthAccount":{"emailAddress":"alpha@example.com"}}' > "$RUN/.claude.json"
cat > "$RUN/cfg/accounts" <<EOF
alpha@example.com|$RUN/.claude-pool/alpha
dead@example.com|$RUN/.claude-pool/dead
partial@example.com|$RUN/.claude-pool/partial
EOF
printf '{"seven_day":{"utilization":18,"resets_at":"%s"},"five_hour":{"utilization":23,"resets_at":"%s"}}' \
  "$(iso_in +2d)" "$(iso_in +2H)" > "$RUN/state/usage-TOK-INC-SHARED.json"
# no usage-TOK-INC-DEAD.json on purpose: the fake curl answers "\n000", a failed fetch
printf '{"seven_day":{"utilization":40,"resets_at":"%s"},"five_hour":{"resets_at":"%s"}}' \
  "$(iso_in +2d)" "$(iso_in +2H)" > "$RUN/state/usage-TOK-INC-PARTIAL.json"
set +e
OUT="$(FAKE_NEW_EMAIL=alpha@example.com "$SCRIPT" usage 2>/dev/null)"
VOUT="$(FAKE_NEW_EMAIL=alpha@example.com "$SCRIPT" usage --verbose 2>/dev/null)"
JSON_OUT="$(FAKE_NEW_EMAIL=alpha@example.com "$SCRIPT" usage --json 2>/dev/null)"
RC=$?
set -e
[ "$RC" -eq 0 ] && ok "incomplete data → usage exits 0" || bad "incomplete data → usage exits 0 (got $RC: $OUT)"
dead_row="$(jq -c '.accounts[] | select(.email=="dead@example.com")' <<<"$JSON_OUT" 2>/dev/null)"
[ "$(jq -r '.recommendable' <<<"$dead_row" 2>/dev/null)" = "false" ] \
  && ok "incomplete data → a FAILED fetch is still excluded" \
  || bad "incomplete data → a failed fetch is excluded (got: $dead_row)"
grep -q "no LIVE numbers" <<<"$(jq -r '.reason // empty' <<<"$dead_row" 2>/dev/null)" \
  && ok "incomplete data → the failed fetch says it has no live numbers" \
  || bad "incomplete data → the failed fetch names its reason (got: $(jq -r '.reason // empty' <<<"$dead_row" 2>/dev/null))"
[ "$(jq -r '.weekly.fresh' <<<"$dead_row" 2>/dev/null)" = "false" ] \
  && ok "incomplete data → a failed fetch is NOT flagged fresh (unknown stays unknown)" \
  || bad "incomplete data → a failed fetch is not fresh (got: $dead_row)"
[ "$(jq -r '.weekly.remaining_pct' <<<"$dead_row" 2>/dev/null)" = "null" ] \
  && ok "incomplete data → a failed fetch reports null percentages, never 100" \
  || bad "incomplete data → a failed fetch reports null (got: $dead_row)"
part_row="$(jq -c '.accounts[] | select(.email=="partial@example.com")' <<<"$JSON_OUT" 2>/dev/null)"
[ "$(jq -r '.recommendable' <<<"$part_row" 2>/dev/null)" = "false" ] \
  && ok "incomplete data → a 200 missing five_hour.utilization is still excluded" \
  || bad "incomplete data → a partial 200 is excluded (got: $part_row)"
[ "$(jq -r '.reason' <<<"$part_row" 2>/dev/null)" = "incomplete usage data" ] \
  && ok "incomplete data → the partial 200 keeps the 'incomplete usage data' reason" \
  || bad "incomplete data → the partial 200 keeps its reason (got: $part_row)"
# the default view carries the SHORT reason in its column; the full sentence is
# not deleted, it moved to --verbose. Both are asserted, so neither can quietly go.
grep -qE '^  ✗ partial@example\.com +incomplete data' <<<"$(unavail_block <<<"$OUT")" \
  && ok "incomplete data → UNAVAILABLE row carries the short reason in its column" \
  || bad "incomplete data → short reason on the row (got: $(unavail_block <<<"$OUT"))"
grep -q "skipped incomplete usage data" <<<"$VOUT" \
  && ok "incomplete data → --verbose still prints the full 'incomplete usage data' sentence" \
  || bad "incomplete data → --verbose keeps the full sentence (got: $VOUT)"
grep -qE '^  ✗ dead@example\.com +(no live numbers|stored token stale)' <<<"$(unavail_block <<<"$OUT")" \
  && ok "incomplete data → a FAILED fetch says so in its own short reason" \
  || bad "incomplete data → the failed fetch has a short reason (got: $(unavail_block <<<"$OUT"))"

# --- 20. a CACHED fresh window must survive the round-trip --------------------
# A fresh window is the first thing that ever put an EMPTY value in the cache
# (resets_at is null), and cache_get read the row with IFS=$'\t', tab is IFS
# whitespace, so bash collapsed the run of tabs and dropped the empty fields,
# shifting every later field left. The cached utilization "0.0" then landed in
# C_WKR and window_expired compared it as a timestamp, so the healthiest possible
# row came back as "expired (window reset since)" on the --no-refresh path.
# The cache FILE was always correct; only the read was lossy.
new_run cachedfresh
mkdir -p "$RUN/.claude-pool/primary"
printf '{"claudeAiOauth":{"accessToken":"TOK-CACHED-FRESH"}}' > "$RUN/.claude-pool/primary/.credentials.json"
printf '{"oauthAccount":{"emailAddress":"primary@example.com"}}' > "$RUN/.claude-pool/primary/.claude.json"
cat > "$RUN/cfg/accounts" <<EOF
primary@example.com|$RUN/.claude-pool/primary
EOF
# exactly what cache_flush writes for a fresh account: numbers, empty reset stamps
jq -n '{"primary@example.com":{wk_u:"0.0",wk_r:"",se_u:"0.0",se_r:"",
        ts:"Jul 30 21:06",ts_epoch:"1785438377"}}' > "$RUN/cfg/usage-cache.json"
set +e
OUT="$("$SCRIPT" usage --no-refresh 2>/dev/null)"
VOUT="$("$SCRIPT" usage --no-refresh --verbose 2>/dev/null)"
JSON_OUT="$("$SCRIPT" usage --no-refresh --json 2>/dev/null)"
RC=$?
set -e
[ "$RC" -eq 0 ] && ok "cached fresh → usage --no-refresh exits 0" || bad "cached fresh → exits 0 (got $RC: $OUT)"
! grep -qE "expired|weekly window expired" <<<"$OUT" \
  && ok "cached fresh → never renders a fresh window as expired" \
  || bad "cached fresh → never renders as expired (got: $OUT)"
grep -q "resets  weekly no active window yet (starts on first use) · 5h no active window yet (starts on first use)" <<<"$VOUT" \
  && ok "cached fresh → BOTH windows round-trip out of the cache as unstarted, not shifted" \
  || bad "cached fresh → both windows round-trip as unstarted (got: $VOUT)"
# the short reason for a --no-refresh row must actually RENDER: written as a bare
# literal it began with "--", which printf ate as an option and left the column blank
grep -qE '^  ✗ primary@example\.com +--no-refresh \(cached\)' <<<"$(unavail_block <<<"$OUT")" \
  && ok "cached fresh → the --no-refresh short reason renders (a leading -- is not eaten as a printf option)" \
  || bad "cached fresh → --no-refresh short reason renders (got: $(unavail_block <<<"$OUT"))"
cf_row="$(jq -c '.accounts[] | select(.email=="primary@example.com")' <<<"$JSON_OUT" 2>/dev/null)"
[ "$(jq -r '.weekly | [.remaining_pct,.used_pct,.resets_at,.expired,.fresh] | @csv' <<<"$cf_row" 2>/dev/null)" = '100,0,,false,true' ] \
  && ok "cached fresh (json) → the cached weekly window round-trips as fresh, not expired" \
  || bad "cached fresh (json) → weekly round-trips as fresh (got: $(jq -c '.weekly' <<<"$cf_row" 2>/dev/null))"
[ "$(jq -r '.five_hour | [.remaining_pct,.used_pct,.resets_at,.expired,.fresh] | @csv' <<<"$cf_row" 2>/dev/null)" = '100,0,,false,true' ] \
  && ok "cached fresh (json) → the cached 5h window round-trips too (no field shift)" \
  || bad "cached fresh (json) → 5h round-trips (got: $(jq -c '.five_hour' <<<"$cf_row" 2>/dev/null))"
# v2: a cache row older than 60 min renders `stale Xh`, the age up front, so a
# July number can never read as current. The human stamp still round-trips out
# of the cache (it feeds the recommendation's cached-suffix), but the row tag is
# now the age.
grep -qE '\[stale [0-9]+h\]' <<<"$OUT" \
  && ok "cached fresh → a >60min-old row renders as [stale Xh], never as current" \
  || bad "cached fresh → stale-age tag (got: $OUT)"

# --- 21. BINDING weekly limit: a SCOPED limit above weekly_all is the figure --
# The usage response carries a `limits` array as well as seven_day, and a per-model
# (scoped) weekly entry can sit far ABOVE the all-model one. seven_day == weekly_all,
# so reading only seven_day makes the cap that will actually wall you invisible, the
# dashboard reports comfortable headroom right up to the moment the account stops
# answering. The binding figure is max(percent) over group=="weekly", carrying THAT
# entry's own resets_at, and the scope is named on the row so 47% can never be
# misread as the all-model number.
new_run bindscoped
mkdir -p "$RUN/.claude-pool/solo"
printf '{"claudeAiOauth":{"accessToken":"TOK-BIND-SCOPED"}}' > "$RUN/.claude/.credentials.json"
cp "$RUN/.claude/.credentials.json" "$RUN/.claude-pool/solo/.credentials.json"
printf '{"oauthAccount":{"emailAddress":"solo@example.com"}}' > "$RUN/.claude-pool/solo/.claude.json"
printf '{"oauthAccount":{"emailAddress":"solo@example.com"}}' > "$RUN/.claude.json"
cat > "$RUN/cfg/accounts" <<EOF
solo@example.com|$RUN/.claude-pool/solo
EOF
WK_ALL_R="$(iso_in +5d)"; WK_SCOPED_R="$(iso_in +2d)"; FIVE_R="$(iso_in +2H)"
# the live response shape, verbatim down to the null seven_day_* siblings
printf '{"five_hour":{"utilization":34.0,"resets_at":"%s"},
 "seven_day":{"utilization":21.0,"resets_at":"%s"},
 "seven_day_opus":null,"seven_day_sonnet":null,"seven_day_cowork":null,
 "limits":[
   {"kind":"session","group":"session","percent":34,"is_active":true,"resets_at":"%s","scope":null},
   {"kind":"weekly_all","group":"weekly","percent":21,"is_active":false,"resets_at":"%s","scope":null},
   {"kind":"weekly_scoped","group":"weekly","percent":47,"is_active":false,"resets_at":"%s",
    "scope":{"model":{"id":null,"display_name":"Opus"}}}]}' \
  "$FIVE_R" "$WK_ALL_R" "$FIVE_R" "$WK_ALL_R" "$WK_SCOPED_R" \
  > "$RUN/state/usage-TOK-BIND-SCOPED.json"
set +e
OUT="$(FAKE_NEW_EMAIL=solo@example.com "$SCRIPT" usage 2>/dev/null)"
JSON_OUT="$(FAKE_NEW_EMAIL=solo@example.com "$SCRIPT" usage --json 2>/dev/null)"
RC=$?
set -e
[ "$RC" -eq 0 ] && ok "binding scoped → usage exits 0" || bad "binding scoped → usage exits 0 (got $RC: $OUT)"
grep -qE '^    weekly  [█░]{15} +53% left · 47% used  \(binding: Opus\)' <<<"$OUT" \
  && ok "binding scoped → the SCOPED limit is the metered weekly figure and the scope is named on the row" \
  || bad "binding scoped → scoped limit is the weekly figure, scope named (got: $OUT)"
! grep -qE "21% used · 79% left|79% left · 21% used" <<<"$OUT" \
  && ok "binding scoped → seven_day's 21% never renders as weekly (it is not the binding cap)" \
  || bad "binding scoped → seven_day's 21% must not render as weekly (got: $OUT)"
grep -qE '^    5h      [█░]{15} +66% left · 34% used' <<<"$OUT" \
  && ok "binding scoped → the 5h window is untouched by the weekly binding rule" \
  || bad "binding scoped → 5h window untouched (got: $OUT)"
grep -q "34% used · 66% left" <<<"$OUT" \
  && ok "binding scoped → the 5h pair is still available used-first in the rationale" \
  || bad "binding scoped → 5h used-first in the rationale (got: $OUT)"
grep -q "binding: Opus, resets" <<<"$OUT" \
  && ok "binding scoped → the recommendation sentence names the binding limit too" \
  || bad "binding scoped → recommendation names the binding limit (got: $OUT)"
bind_row="$(jq -c '.accounts[] | select(.email=="solo@example.com")' <<<"$JSON_OUT" 2>/dev/null)"
[ "$(jq -r '.weekly.used_pct' <<<"$bind_row" 2>/dev/null)" = "47" ] \
  && ok "binding scoped (json) → weekly.used_pct is the BINDING 47, not seven_day's 21" \
  || bad "binding scoped (json) → weekly.used_pct is 47 (got: $bind_row)"
[ "$(jq -r '.weekly.remaining_pct' <<<"$bind_row" 2>/dev/null)" = "53" ] \
  && ok "binding scoped (json) → weekly.remaining_pct is the binding 53" \
  || bad "binding scoped (json) → weekly.remaining_pct is 53 (got: $bind_row)"
[ "$(jq -r '.weekly.kind' <<<"$bind_row" 2>/dev/null)" = "weekly_scoped" ] \
  && ok "binding scoped (json) → weekly.kind exposes which limit bound" \
  || bad "binding scoped (json) → weekly.kind is weekly_scoped (got: $bind_row)"
[ "$(jq -r '.weekly.scope' <<<"$bind_row" 2>/dev/null)" = "Opus" ] \
  && ok "binding scoped (json) → weekly.scope names the model" \
  || bad "binding scoped (json) → weekly.scope is Opus (got: $bind_row)"
[ "$(jq -r '.weekly.resets_at' <<<"$bind_row" 2>/dev/null)" = "$WK_SCOPED_R" ] \
  && ok "binding scoped (json) → weekly.resets_at is the BINDING entry's own stamp, not weekly_all's" \
  || bad "binding scoped (json) → weekly.resets_at is the scoped stamp (got: $(jq -r '.weekly.resets_at' <<<"$bind_row" 2>/dev/null), wanted $WK_SCOPED_R)"
[ "$(jq -r '.five_hour.used_pct' <<<"$bind_row" 2>/dev/null)" = "34" ] \
  && ok "binding scoped (json) → five_hour is still five_hour.utilization" \
  || bad "binding scoped (json) → five_hour.used_pct is 34 (got: $bind_row)"
# the cache stores the binding NUMBER but not which limit produced it, so a --no-refresh
# row must keep the 47 and drop the annotation rather than invent or stale one
set +e
CACHED_OUT="$("$SCRIPT" usage --no-refresh 2>/dev/null)"
CACHED_JSON="$("$SCRIPT" usage --no-refresh --json 2>/dev/null)"
set -e
grep -qE '^    weekly  [█░]{15} +53% left · 47% used' <<<"$CACHED_OUT" \
  && ok "binding scoped → the cached row keeps the binding NUMBER" \
  || bad "binding scoped → cached row keeps the binding number (got: $CACHED_OUT)"
! grep -q "(binding:" <<<"$CACHED_OUT" \
  && ok "binding scoped → the cached row drops the annotation instead of inventing one" \
  || bad "binding scoped → cached row drops the annotation (got: $CACHED_OUT)"
[ "$(jq -r '.accounts[0].weekly | [.kind,.scope] | @csv' <<<"$CACHED_JSON" 2>/dev/null)" = ',' ] \
  && ok "binding scoped (json) → a cached row reports kind/scope null, never a stale pair" \
  || bad "binding scoped (json) → cached kind/scope are null (got: $(jq -c '.accounts[0].weekly' <<<"$CACHED_JSON" 2>/dev/null))"

# --- 22. weekly_all binds when IT is the higher one ---------------------------
# Same mechanism, the ordinary case: the scoped entry is the small one (a live
# response has weekly_scoped Fable at 2%), so weekly_all is the binding figure and the
# row must render exactly as it always did, no scope annotation to disambiguate.
new_run bindall
mkdir -p "$RUN/.claude-pool/solo"
printf '{"claudeAiOauth":{"accessToken":"TOK-BIND-ALL"}}' > "$RUN/.claude/.credentials.json"
cp "$RUN/.claude/.credentials.json" "$RUN/.claude-pool/solo/.credentials.json"
printf '{"oauthAccount":{"emailAddress":"solo@example.com"}}' > "$RUN/.claude-pool/solo/.claude.json"
printf '{"oauthAccount":{"emailAddress":"solo@example.com"}}' > "$RUN/.claude.json"
cat > "$RUN/cfg/accounts" <<EOF
solo@example.com|$RUN/.claude-pool/solo
EOF
WK_ALL_R="$(iso_in +5d)"; FIVE_R="$(iso_in +2H)"
printf '{"five_hour":{"utilization":34.0,"resets_at":"%s"},
 "seven_day":{"utilization":21.0,"resets_at":"%s"},
 "seven_day_opus":null,"seven_day_sonnet":null,"seven_day_cowork":null,
 "limits":[
   {"kind":"session","group":"session","percent":34,"is_active":true,"resets_at":"%s","scope":null},
   {"kind":"weekly_all","group":"weekly","percent":21,"is_active":false,"resets_at":"%s","scope":null},
   {"kind":"weekly_scoped","group":"weekly","percent":2,"is_active":false,"resets_at":"%s",
    "scope":{"model":{"id":null,"display_name":"Fable"}}}]}' \
  "$FIVE_R" "$WK_ALL_R" "$FIVE_R" "$WK_ALL_R" "$WK_ALL_R" \
  > "$RUN/state/usage-TOK-BIND-ALL.json"
set +e
OUT="$(FAKE_NEW_EMAIL=solo@example.com "$SCRIPT" usage 2>/dev/null)"
JSON_OUT="$(FAKE_NEW_EMAIL=solo@example.com "$SCRIPT" usage --json 2>/dev/null)"
RC=$?
set -e
[ "$RC" -eq 0 ] && ok "binding all → usage exits 0" || bad "binding all → usage exits 0 (got $RC: $OUT)"
grep -qE '^    weekly  [█░]{15} +79% left · 21% used' <<<"$OUT" \
  && ok "binding all → weekly_all is the binding figure when it is the higher one" \
  || bad "binding all → weekly_all is the binding figure (got: $OUT)"
! grep -q "(binding:" <<<"$OUT" \
  && ok "binding all → no scope annotation when the binding limit is the all-model one" \
  || bad "binding all → no annotation for weekly_all (got: $OUT)"
! grep -qE "2% used · 98% left|98% left · 2% used" <<<"$OUT" \
  && ok "binding all → the small scoped Fable cap never becomes the weekly figure" \
  || bad "binding all → the scoped Fable cap is not the weekly figure (got: $OUT)"
ba_row="$(jq -c '.accounts[] | select(.email=="solo@example.com")' <<<"$JSON_OUT" 2>/dev/null)"
[ "$(jq -r '.weekly.kind' <<<"$ba_row" 2>/dev/null)" = "weekly_all" ] \
  && ok "binding all (json) → weekly.kind is weekly_all" \
  || bad "binding all (json) → weekly.kind is weekly_all (got: $ba_row)"
[ "$(jq -r '.weekly.scope' <<<"$ba_row" 2>/dev/null)" = "null" ] \
  && ok "binding all (json) → weekly.scope is null for an unscoped limit, never the string \"null\"" \
  || bad "binding all (json) → weekly.scope is null (got: $ba_row)"
[ "$(jq -r '.weekly.used_pct' <<<"$ba_row" 2>/dev/null)" = "21" ] \
  && ok "binding all (json) → weekly.used_pct matches seven_day, as it must when weekly_all binds" \
  || bad "binding all (json) → weekly.used_pct is 21 (got: $ba_row)"

# --- 23. FALLBACK: no usable `limits` must behave exactly as before ------------
# An older or differently-shaped response must not break the tool. Absent, empty, a
# non-array, and a limits array with no weekly group all fall back to seven_day, with
# kind/scope null. The last sub-case is the null-safety one: a scoped binding whose
# display_name is null must render UNannotated, never "(binding: null)".
new_run bindfallback
mkdir -p "$RUN/.claude-pool/solo"
printf '{"claudeAiOauth":{"accessToken":"TOK-FB"}}' > "$RUN/.claude/.credentials.json"
cp "$RUN/.claude/.credentials.json" "$RUN/.claude-pool/solo/.credentials.json"
printf '{"oauthAccount":{"emailAddress":"solo@example.com"}}' > "$RUN/.claude-pool/solo/.claude.json"
printf '{"oauthAccount":{"emailAddress":"solo@example.com"}}' > "$RUN/.claude.json"
cat > "$RUN/cfg/accounts" <<EOF
solo@example.com|$RUN/.claude-pool/solo
EOF
FB_WK_R="$(iso_in +5d)"; FB_SE_R="$(iso_in +2H)"
fb_case() {  # fb_case <label> <limits-json-fragment-or-empty>
  local label="$1" frag="$2" body
  body="{\"five_hour\":{\"utilization\":34.0,\"resets_at\":\"$FB_SE_R\"},\"seven_day\":{\"utilization\":21.0,\"resets_at\":\"$FB_WK_R\"}$frag}"
  printf '%s' "$body" > "$RUN/state/usage-TOK-FB.json"
  rm -f "$RUN/cfg/usage-cache.json"
  set +e
  FB_OUT="$(FAKE_NEW_EMAIL=solo@example.com "$SCRIPT" usage 2>/dev/null)"
  FB_JSON="$(FAKE_NEW_EMAIL=solo@example.com "$SCRIPT" usage --json 2>/dev/null)"
  FB_RC=$?
  set -e
  [ "$FB_RC" -eq 0 ] && ok "fallback [$label] → usage exits 0" \
    || bad "fallback [$label] → usage exits 0 (got $FB_RC: $FB_OUT)"
  grep -q "21% used · 79% left" <<<"$FB_OUT" \
    && ok "fallback [$label] → weekly falls back to seven_day, unchanged" \
    || bad "fallback [$label] → weekly falls back to seven_day (got: $FB_OUT)"
  ! grep -q "(binding:" <<<"$FB_OUT" \
    && ok "fallback [$label] → no scope annotation on the fallback path" \
    || bad "fallback [$label] → no annotation on fallback (got: $FB_OUT)"
  [ "$(jq -r '.accounts[0].weekly | [.kind,.scope] | @csv' <<<"$FB_JSON" 2>/dev/null)" = ',' ] \
    && ok "fallback [$label] (json) → weekly.kind and weekly.scope are both null" \
    || bad "fallback [$label] (json) → kind/scope null (got: $(jq -c '.accounts[0].weekly' <<<"$FB_JSON" 2>/dev/null))"
  [ "$(jq -r '.accounts[0].weekly.resets_at' <<<"$FB_JSON" 2>/dev/null)" = "$FB_WK_R" ] \
    && ok "fallback [$label] (json) → weekly.resets_at is seven_day's own stamp" \
    || bad "fallback [$label] (json) → weekly.resets_at is seven_day's (got: $(jq -r '.accounts[0].weekly.resets_at' <<<"$FB_JSON" 2>/dev/null))"
}
fb_case "limits absent"    ''
fb_case "limits empty"     ',"limits":[]'
fb_case "limits not array" ',"limits":"garbage"'
fb_case "no weekly group"  ",\"limits\":[{\"kind\":\"session\",\"group\":\"session\",\"percent\":34,\"resets_at\":\"$FB_SE_R\",\"scope\":null}]"
fb_case "limits null"      ',"limits":null'
# null-safety: a scoped limit really does bind here (47), but its display_name is null
printf '{"five_hour":{"utilization":34.0,"resets_at":"%s"},"seven_day":{"utilization":21.0,"resets_at":"%s"},
 "limits":[{"kind":"weekly_all","group":"weekly","percent":21,"resets_at":"%s","scope":null},
   {"kind":"weekly_scoped","group":"weekly","percent":47,"resets_at":"%s",
    "scope":{"model":{"id":null,"display_name":null}}}]}' \
  "$FB_SE_R" "$FB_WK_R" "$FB_WK_R" "$FB_WK_R" > "$RUN/state/usage-TOK-FB.json"
rm -f "$RUN/cfg/usage-cache.json"
set +e
OUT="$(FAKE_NEW_EMAIL=solo@example.com "$SCRIPT" usage 2>/dev/null)"
JSON_OUT="$(FAKE_NEW_EMAIL=solo@example.com "$SCRIPT" usage --json 2>/dev/null)"
RC=$?
set -e
[ "$RC" -eq 0 ] && ok "null scope name → usage exits 0" || bad "null scope name → usage exits 0 (got $RC: $OUT)"
grep -q "47% used · 53% left" <<<"$OUT" \
  && ok "null scope name → the scoped limit still binds (47), only the name is missing" \
  || bad "null scope name → the scoped limit still binds (got: $OUT)"
! grep -q "binding: null" <<<"$OUT" \
  && ok "null scope name → never renders the literal string \"null\" as the scope" \
  || bad "null scope name → renders 'binding: null' (got: $OUT)"
! grep -q "(binding:" <<<"$OUT" \
  && ok "null scope name → renders unannotated rather than annotated with nothing" \
  || bad "null scope name → renders unannotated (got: $OUT)"
ns_row="$(jq -c '.accounts[0]' <<<"$JSON_OUT" 2>/dev/null)"
[ "$(jq -r '.weekly.scope' <<<"$ns_row" 2>/dev/null)" = "null" ] \
  && ok "null scope name (json) → weekly.scope is JSON null, not the string \"null\"" \
  || bad "null scope name (json) → weekly.scope is null (got: $ns_row)"
[ "$(jq -r '.weekly.kind' <<<"$ns_row" 2>/dev/null)" = "weekly_scoped" ] \
  && ok "null scope name (json) → weekly.kind still records that a scoped limit bound" \
  || bad "null scope name (json) → weekly.kind is weekly_scoped (got: $ns_row)"

# --- 24. the BINDING number drives the health floor and the recommendation -----
# This is what FIX 2 is for. The active account's weekly_all sits at a comfortable 10%,
# but its Opus-scoped weekly cap is at 99%, that is the wall it will actually hit. On
# seven_day alone the tool would report 90% headroom and recommend staying put right up
# until the account stops answering. The binding figure must exclude it from the pick,
# say so used-first with the scope named, and hand the recommendation to alpha.
# `busy` is the 5h-floor half of the same assertion.
new_run bindfloor
mkdir -p "$RUN/.claude-pool/opuscap" "$RUN/.claude-pool/alpha" "$RUN/.claude-pool/busy"
printf '{"claudeAiOauth":{"accessToken":"TOK-BF-SHARED"}}' > "$RUN/.claude/.credentials.json"
cp "$RUN/.claude/.credentials.json" "$RUN/.claude-pool/opuscap/.credentials.json"
printf '{"oauthAccount":{"emailAddress":"opuscap@example.com"}}' > "$RUN/.claude-pool/opuscap/.claude.json"
printf '{"claudeAiOauth":{"accessToken":"TOK-BF-ALPHA"}}' > "$RUN/.claude-pool/alpha/.credentials.json"
printf '{"oauthAccount":{"emailAddress":"alpha@example.com"}}' > "$RUN/.claude-pool/alpha/.claude.json"
printf '{"claudeAiOauth":{"accessToken":"TOK-BF-BUSY"}}' > "$RUN/.claude-pool/busy/.credentials.json"
printf '{"oauthAccount":{"emailAddress":"busy@example.com"}}' > "$RUN/.claude-pool/busy/.claude.json"
printf '{"oauthAccount":{"emailAddress":"opuscap@example.com"}}' > "$RUN/.claude.json"
cat > "$RUN/cfg/accounts" <<EOF
opuscap@example.com|$RUN/.claude-pool/opuscap
alpha@example.com|$RUN/.claude-pool/alpha
busy@example.com|$RUN/.claude-pool/busy
EOF
BF_ALL_R="$(iso_in +6d)"; BF_SCOPED_R="$(iso_in +3d)"; BF_SE_R="$(iso_in +2H)"
printf '{"five_hour":{"utilization":20,"resets_at":"%s"},"seven_day":{"utilization":10,"resets_at":"%s"},
 "limits":[{"kind":"session","group":"session","percent":20,"resets_at":"%s","scope":null},
   {"kind":"weekly_all","group":"weekly","percent":10,"resets_at":"%s","scope":null},
   {"kind":"weekly_scoped","group":"weekly","percent":99,"resets_at":"%s",
    "scope":{"model":{"id":null,"display_name":"Opus"}}}]}' \
  "$BF_SE_R" "$BF_ALL_R" "$BF_SE_R" "$BF_ALL_R" "$BF_SCOPED_R" \
  > "$RUN/state/usage-TOK-BF-SHARED.json"
printf '{"seven_day":{"utilization":18,"resets_at":"%s"},"five_hour":{"utilization":23,"resets_at":"%s"}}' \
  "$(iso_in +2d)" "$BF_SE_R" > "$RUN/state/usage-TOK-BF-ALPHA.json"
printf '{"seven_day":{"utilization":10,"resets_at":"%s"},"five_hour":{"utilization":95,"resets_at":"%s"}}' \
  "$(iso_in +4d)" "$BF_SE_R" > "$RUN/state/usage-TOK-BF-BUSY.json"
set +e
OUT="$(FAKE_NEW_EMAIL=opuscap@example.com "$SCRIPT" usage 2>/dev/null)"
VOUT="$(FAKE_NEW_EMAIL=opuscap@example.com "$SCRIPT" usage --verbose 2>/dev/null)"
JSON_OUT="$(FAKE_NEW_EMAIL=opuscap@example.com "$SCRIPT" usage --json 2>/dev/null)"
RC=$?
set -e
[ "$RC" -eq 0 ] && ok "binding floor → usage exits 0" || bad "binding floor → usage exits 0 (got $RC: $OUT)"
# opuscap is the ACTIVE account, so its numbers are the metered block at the top.
# Scoping to that block matters because `busy` legitimately renders a 10%-used
# weekly of its own further down the report.
bf_block="$(active_block <<<"$OUT")"
! grep -qE "10% used · 90% left|90% left · 10% used" <<<"$bf_block" \
  && ok "binding floor → the comfortable weekly_all 10% never renders on the capped account's row" \
  || bad "binding floor → weekly_all's 10% must not render (got: $bf_block)"
grep -qE '^    weekly  [█░]{15} +1% left · 99% used  \(binding: Opus\)' <<<"$bf_block" \
  && ok "binding floor → the Opus cap that will actually wall him is the metered weekly figure, named" \
  || bad "binding floor → the Opus cap is the weekly figure (got: $bf_block)"
grep -q "skipped weekly 99% used · 1% left  (binding: Opus) is under the 20%-left floor" <<<"$VOUT" \
  && ok "binding floor → --verbose keeps the full exclusion reason, used-first with the scope named" \
  || bad "binding floor → --verbose exclusion reason is used-first + names the scope (got: $VOUT)"
grep -q "skipped 5h 95% used · 5% left is under the 10%-left floor" <<<"$VOUT" \
  && ok "binding floor → --verbose keeps the 5h exclusion reason, used-first too" \
  || bad "binding floor → --verbose 5h exclusion reason is used-first (got: $VOUT)"
# and the DEFAULT view compresses each of those to a column, scope included
grep -qE '^  ✗ busy@example\.com +5h 5% left' <<<"$(unavail_block <<<"$OUT")" \
  && ok "binding floor → the default view names the 5h window as the short reason" \
  || bad "binding floor → short 5h reason (got: $(unavail_block <<<"$OUT"))"
grep -q "switch to alpha@example.com" <<<"$OUT" \
  && ok "binding floor → the recommendation goes to the account that really has headroom" \
  || bad "binding floor → recommends alpha (got: $OUT)"
grep -q "is nearly exhausted (weekly 99% used · 1% left, binding: Opus, resets" <<<"$OUT" \
  && ok "binding floor → the active-account note is used-first and names the binding limit" \
  || bad "binding floor → active-account note used-first + binding named (got: $OUT)"
bf_row="$(jq -c '.accounts[] | select(.email=="opuscap@example.com")' <<<"$JSON_OUT" 2>/dev/null)"
[ "$(jq -r '.recommendable' <<<"$bf_row" 2>/dev/null)" = "false" ] \
  && ok "binding floor (json) → the scoped-capped account is excluded from the pick" \
  || bad "binding floor (json) → excluded from the pick (got: $bf_row)"
[ "$(jq -r '.weekly | [.used_pct,.remaining_pct,.kind,.scope] | @csv' <<<"$bf_row" 2>/dev/null)" = '99,1,"weekly_scoped","Opus"' ] \
  && ok "binding floor (json) → the whole binding shape travels together" \
  || bad "binding floor (json) → binding shape (got: $(jq -c '.weekly' <<<"$bf_row" 2>/dev/null))"
[ "$(jq -r '.weekly.resets_at' <<<"$bf_row" 2>/dev/null)" = "$BF_SCOPED_R" ] \
  && ok "binding floor (json) → the reset shown is the Opus cap's, not weekly_all's" \
  || bad "binding floor (json) → reset is the scoped one (got: $(jq -r '.weekly.resets_at' <<<"$bf_row" 2>/dev/null))"
[ "$(jq -r '.recommendation.email' <<<"$JSON_OUT" 2>/dev/null)" = "alpha@example.com" ] \
  && ok "binding floor (json) → recommendation follows the binding-aware floor" \
  || bad "binding floor (json) → recommendation is alpha (got: $(jq -c '.recommendation' <<<"$JSON_OUT" 2>/dev/null))"
BF_PROSE="$(left_first_prose <<<"$OUT")"
[ -z "$BF_PROSE" ] \
  && ok "binding floor → no SENTENCE in a multi-account report leads with left either" \
  || bad "binding floor → a sentence leads with left (got: $BF_PROSE)"

# --- 25. switch-auto must never dead-end merely because the data was old -------
# The 2026-08-05 defect. `rota switch` with no argument exists so the operator never has to
# name an account, yet with every stored token stale (curl answers 000 here, the
# shape of a dead network or a rejected token) every row fell back to a cache, every
# cached row was excluded as "no LIVE numbers", and the verb refused to choose:
#   rota-engine: no other account with LIVE numbers clearing the health
#   floor (>=20% weekly, >=10% 5h; current: primary@example.com), see `rota usage`
# The cache here is OLD (stamped 20 Jul) but its windows have NOT expired and wk
# plainly clears the floor with the soonest weekly reset, so there IS a right answer.
# switch-auto must find it, say the numbers were cached, and exit 0.
sa_fixture() {  # sa_fixture <name> <wk-weekly-used> <wk-weekly-reset> <alpha-weekly-used>
  new_run "$1"
  mkdir -p "$RUN/.claude-pool/alpha" "$RUN/.claude-pool/wk" "$RUN/.claude-pool/primary"
  printf '{"claudeAiOauth":{"accessToken":"TOK-SA-SHARED"}}'  > "$RUN/.claude/.credentials.json"
  printf '{"claudeAiOauth":{"accessToken":"TOK-SA-ALPHA"}}'   > "$RUN/.claude-pool/alpha/.credentials.json"
  printf '{"claudeAiOauth":{"accessToken":"TOK-SA-WK"}}'      > "$RUN/.claude-pool/wk/.credentials.json"
  printf '{"claudeAiOauth":{"accessToken":"TOK-SA-PRIMARY"}}' > "$RUN/.claude-pool/primary/.credentials.json"
  printf '{"oauthAccount":{"emailAddress":"alpha@example.com"}}'   > "$RUN/.claude-pool/alpha/.claude.json"
  printf '{"oauthAccount":{"emailAddress":"wk@example.com"}}'      > "$RUN/.claude-pool/wk/.claude.json"
  printf '{"oauthAccount":{"emailAddress":"primary@example.com"}}' > "$RUN/.claude-pool/primary/.claude.json"
  printf '{"oauthAccount":{"emailAddress":"primary@example.com"}}' > "$RUN/.claude.json"
  cat > "$RUN/cfg/accounts" <<EOF
alpha@example.com|$RUN/.claude-pool/alpha
wk@example.com|$RUN/.claude-pool/wk
primary@example.com|$RUN/.claude-pool/primary
EOF
  # NO usage-TOK-* fixtures at all → the stub curl answers "\n000" for every token,
  # so not one row can come back live and the haiku nudge cannot rescue it either.
  # primary (the ACTIVE account) is cached at 99% used on purpose: since 2026-08-06 the
  # burn-down rule holds him on the active account until it is spent, so every one of
  # these switch-auto scenarios is about what happens AFTER that hold ends.
  cat > "$RUN/cfg/usage-cache.json" <<EOF
{
  "alpha@example.com":   {"wk_u":"$4","wk_r":"$(iso_in +5d)","se_u":"10","se_r":"$(iso_in +2H)","ts":"Jul 20 02:14","ts_epoch":"1784585640"},
  "wk@example.com":      {"wk_u":"$2","wk_r":"$3","se_u":"20","se_r":"$(iso_in +3H)","ts":"Jul 20 02:14","ts_epoch":"1784585640"},
  "primary@example.com": {"wk_u":"99","wk_r":"$(iso_in +4d)","se_u":"15","se_r":"$(iso_in +1H)","ts":"Jul 20 02:14","ts_epoch":"1784585640"}
}
EOF
}

sa_fixture staleswitch 30 "$(iso_in +2d)" 95
set +e
OUT="$(FAKE_NEW_EMAIL=primary@example.com "$SCRIPT" switch-auto --dry-run 2>&1)"
RC=$?
set -e
[ "$RC" -eq 0 ] \
  && ok "stale switch-auto → exits 0 instead of dead-ending" \
  || bad "stale switch-auto → exits 0 (got $RC: $OUT)"
grep -q "optimizer pick: wk@example.com" <<<"$OUT" \
  && ok "stale switch-auto → still picks the right account (soonest reset above the floor)" \
  || bad "stale switch-auto → picks wk (got: $OUT)"
grep -q "from CACHED numbers" <<<"$OUT" \
  && ok "stale switch-auto → marks the pick as made on cached numbers" \
  || bad "stale switch-auto → marks the cached fallback (got: $OUT)"
grep -q "no account returned LIVE numbers this run" <<<"$OUT" \
  && ok "stale switch-auto → says WHY it fell back, per account" \
  || bad "stale switch-auto → explains the fallback (got: $OUT)"
grep -q "(dry-run, no switch performed)" <<<"$OUT" \
  && ok "stale switch-auto → --dry-run still performs no switch" \
  || bad "stale switch-auto → --dry-run performs no switch (got: $OUT)"

# --- 26. the health floor is unchanged: a genuine no-headroom pool still fails --
# "Never fail merely because the data was old" is not "never fail". With every
# CACHED row under the floor too, there is genuinely nothing to switch to and the
# verb must still say so, with the floors and the current account named.
sa_fixture nofloor 95 "$(iso_in +2d)" 96
set +e
OUT="$(FAKE_NEW_EMAIL=primary@example.com "$SCRIPT" switch-auto --dry-run 2>&1)"
RC=$?
set -e
[ "$RC" -eq 1 ] \
  && ok "no real headroom → still exits 1 (the floor was not weakened)" \
  || bad "no real headroom → exits 1 (got $RC: $OUT)"
grep -q "on live OR cached numbers" <<<"$OUT" \
  && ok "no real headroom → says both sources were tried, so it reads as a verdict not a gap" \
  || bad "no real headroom → names both sources (got: $OUT)"
grep -q ">=20% weekly, >=10% 5h" <<<"$OUT" \
  && ok "no real headroom → still names the floors it judged against" \
  || bad "no real headroom → names the floors (got: $OUT)"

# --- 27. an EXPIRED cached window is still never scored ------------------------
# A cached number whose window has already reset is not old data, it is WRONG data:
# it was measured inside a window that no longer exists. The cached fallback must
# not resurrect it, even though doing so would let the pick succeed.
sa_fixture expiredcache 30 "$(iso_in -2d)" 95
set +e
OUT="$(FAKE_NEW_EMAIL=primary@example.com "$SCRIPT" switch-auto --dry-run 2>&1)"
RC=$?
set -e
[ "$RC" -eq 1 ] \
  && ok "expired cached window → not scored, even by the cached fallback" \
  || bad "expired cached window → not scored (got $RC: $OUT)"
! grep -q "optimizer pick: wk@example.com" <<<"$OUT" \
  && ok "expired cached window → wk's dead 70%-left number never becomes the pick" \
  || bad "expired cached window → wk must not be picked (got: $OUT)"

# --- 28. the LIVE path is untouched by the fallback ----------------------------
# The fallback is a SECOND pass, so whenever a live fetch lands the output must be
# exactly what it always was, no cached marker, no note.
sa_fixture liveswitch 30 "$(iso_in +2d)" 95
printf '{"seven_day":{"utilization":30,"resets_at":"%s"},"five_hour":{"utilization":20,"resets_at":"%s"}}' \
  "$(iso_in +2d)" "$(iso_in +3H)" > "$RUN/state/usage-TOK-SA-WK.json"
printf '{"seven_day":{"utilization":95,"resets_at":"%s"},"five_hour":{"utilization":10,"resets_at":"%s"}}' \
  "$(iso_in +5d)" "$(iso_in +2H)" > "$RUN/state/usage-TOK-SA-ALPHA.json"
printf '{"seven_day":{"utilization":99,"resets_at":"%s"},"five_hour":{"utilization":15,"resets_at":"%s"}}' \
  "$(iso_in +4d)" "$(iso_in +1H)" > "$RUN/state/usage-TOK-SA-PRIMARY.json"
printf '{"seven_day":{"utilization":99,"resets_at":"%s"},"five_hour":{"utilization":15,"resets_at":"%s"}}' \
  "$(iso_in +4d)" "$(iso_in +1H)" > "$RUN/state/usage-TOK-SA-SHARED.json"
set +e
OUT="$(FAKE_NEW_EMAIL=primary@example.com "$SCRIPT" switch-auto --dry-run 2>&1)"
RC=$?
set -e
[ "$RC" -eq 0 ] && ok "live switch-auto → exits 0" || bad "live switch-auto → exits 0 (got $RC: $OUT)"
grep -q "optimizer pick: wk@example.com" <<<"$OUT" \
  && ok "live switch-auto → picks wk" \
  || bad "live switch-auto → picks wk (got: $OUT)"
! grep -q "CACHED" <<<"$OUT" \
  && ok "live switch-auto → no cached marker on the daily happy path" \
  || bad "live switch-auto → no cached marker (got: $OUT)"

# --- 29. `usage --json`: the additive camelCase view a phone renderer needs -----
# Every published snake_case field keeps its name and value; the camelCase keys sit
# alongside them. Guarded together because the whole point is that adding the second
# view never disturbs the first.
new_run jsonshape
mkdir -p "$RUN/.claude-pool/one" "$RUN/.claude-pool/two"
printf '{"claudeAiOauth":{"accessToken":"TOK-J1"}}' > "$RUN/.claude/.credentials.json"
cp "$RUN/.claude/.credentials.json" "$RUN/.claude-pool/one/.credentials.json"
printf '{"claudeAiOauth":{"accessToken":"TOK-J2"}}' > "$RUN/.claude-pool/two/.credentials.json"
printf '{"oauthAccount":{"emailAddress":"one@example.com"}}' > "$RUN/.claude-pool/one/.claude.json"
printf '{"oauthAccount":{"emailAddress":"two@example.com"}}' > "$RUN/.claude-pool/two/.claude.json"
printf '{"oauthAccount":{"emailAddress":"one@example.com"}}' > "$RUN/.claude.json"
cat > "$RUN/cfg/accounts" <<EOF
one@example.com|$RUN/.claude-pool/one
two@example.com|$RUN/.claude-pool/two
EOF
J_WK="$(iso_in +2d)"; J_SE="$(iso_in +2H)"
printf '{"seven_day":{"utilization":69,"resets_at":"%s"},"five_hour":{"utilization":7,"resets_at":"%s"}}' \
  "$J_WK" "$J_SE" > "$RUN/state/usage-TOK-J1.json"
printf '{"seven_day":{"utilization":30,"resets_at":"%s"},"five_hour":{"utilization":20,"resets_at":"%s"}}' \
  "$(iso_in +3d)" "$(iso_in +3H)" > "$RUN/state/usage-TOK-J2.json"
set +e
JS="$(FAKE_NEW_EMAIL=one@example.com "$SCRIPT" usage --json 2>/dev/null)"
RC=$?
set -e
[ "$RC" -eq 0 ] && ok "json shape → exits 0" || bad "json shape → exits 0 (got $RC)"
jq -e 'type=="object"' <<<"$JS" >/dev/null 2>&1 \
  && ok "json shape → stdout is exactly one JSON object" \
  || bad "json shape → stdout is one object (got: $JS)"
j1="$(jq -c '.accounts[] | select(.email=="one@example.com")' <<<"$JS" 2>/dev/null)"
[ "$(jq -r '[.weekly.usedPct,.weekly.leftPct,.weekly.used_pct,.weekly.remaining_pct] | @csv' <<<"$j1" 2>/dev/null)" = "69,31,69,31" ] \
  && ok "json shape → weekly carries BOTH polarities in BOTH namings" \
  || bad "json shape → weekly both namings (got: $(jq -c '.weekly' <<<"$j1" 2>/dev/null))"
[ "$(jq -r '.weekly.resetsAt' <<<"$j1" 2>/dev/null)" = "$J_WK" ] \
  && ok "json shape → weekly.resetsAt mirrors resets_at" \
  || bad "json shape → weekly.resetsAt (got: $(jq -r '.weekly.resetsAt' <<<"$j1" 2>/dev/null))"
wk_in="$(jq -r '.weekly.resetsInSeconds' <<<"$j1" 2>/dev/null)"
[ "$wk_in" -gt 170000 ] && [ "$wk_in" -le 172800 ] \
  && ok "json shape → weekly.resetsInSeconds is a real countdown (~2d)" \
  || bad "json shape → weekly.resetsInSeconds ~2d (got: $wk_in)"
[ "$(jq -r '[.session.usedPct,.session.leftPct] | @csv' <<<"$j1" 2>/dev/null)" = "7,93" ] \
  && ok "json shape → session mirrors five_hour under the name the phone uses" \
  || bad "json shape → session mirrors five_hour (got: $(jq -c '.session' <<<"$j1" 2>/dev/null))"
[ "$(jq -r '[.loggedIn,.current,.live,.stale,.active] | @csv' <<<"$j1" 2>/dev/null)" = "true,true,true,false,true" ] \
  && ok "json shape → loggedIn/current/live/stale sit alongside the published active" \
  || bad "json shape → per-account booleans (got: $j1)"
[ "$(jq -r '.generatedAt' <<<"$JS" 2>/dev/null)" = "$(jq -r '.generated_at' <<<"$JS" 2>/dev/null)" ] \
  && ok "json shape → generatedAt mirrors generated_at" \
  || bad "json shape → generatedAt mirrors generated_at"
[ "$(jq -r '.activeEmail' <<<"$JS" 2>/dev/null)" = "one@example.com" ] \
  && ok "json shape → activeEmail is the governing account, flat for a phone renderer" \
  || bad "json shape → activeEmail (got: $(jq -r '.activeEmail' <<<"$JS" 2>/dev/null))"
[ "$(jq -r '.active.email' <<<"$JS" 2>/dev/null)" = "one@example.com" ] \
  && ok "json shape → the published active OBJECT is untouched" \
  || bad "json shape → active object untouched (got: $(jq -c '.active' <<<"$JS" 2>/dev/null))"
# the reason must be the dashboard's own sentence, not a paraphrase
J_REASON="$(jq -r '.recommendation.reason' <<<"$JS" 2>/dev/null)"
J_HUMAN="$(FAKE_NEW_EMAIL=one@example.com "$SCRIPT" usage 2>/dev/null | grep -c "^→" || true)"
[ "$J_HUMAN" -ge 1 ] && [ "${J_REASON:0:1}" = "→" ] \
  && ok "json shape → recommendation.reason is the same sentence the dashboard prints" \
  || bad "json shape → recommendation.reason is the dashboard sentence (got: $J_REASON)"
case "$J_REASON" in
  *$'\n'*) bad "json shape → recommendation.reason is one line (got a newline)" ;;
  *)       ok  "json shape → recommendation.reason is collapsed to one line" ;;
esac

# --- 30. `usage --json` fails as JSON, so a caller can always parse the answer --
# Without this a phone renderer got an English line on stderr and could only show
# "no data" with no reason. jq is deliberately hidden from PATH for the second half:
# the error object must be buildable WITHOUT it.
new_run jsonerr
set +e
ERR_OUT="$("$SCRIPT" usage --json 2>/dev/null)"
ERR_RC=$?
set -e
[ "$ERR_RC" -ne 0 ] && ok "json error → non-zero exit when it cannot answer" \
  || bad "json error → non-zero exit (got $ERR_RC)"
[ -n "$(jq -r '.error // empty' <<<"$ERR_OUT" 2>/dev/null)" ] \
  && ok "json error → the failure is a parseable {\"error\":…} on stdout" \
  || bad "json error → parseable error object (got: $ERR_OUT)"
# ...and the human path is untouched: same failure, plain English, still exit 1
set +e
PLAIN_OUT="$("$SCRIPT" usage 2>&1)"
PLAIN_RC=$?
set -e
[ "$PLAIN_RC" -ne 0 ] && grep -q "^rota-engine: " <<<"$PLAIN_OUT" \
  && ok "json error → the non-JSON path still fails in plain English" \
  || bad "json error → non-JSON path unchanged (got $PLAIN_RC: $PLAIN_OUT)"

# --- 31. SCARCITY (burn-down mode): the floor must not push him OFF an account -
# the operator, 2026-08-06: "let's stay on the current account until we get to 98, 99, 98,
# or almost 100% (ideally 100%), and then switch to the work account.", and, on the
# policy: "in general I agree with the 20% meaning, so that's the right rule in
# general. It's just that we are maxing out all the plans at the moment, and hence we
# don't have the luxury of switching away that early."
#
# So burn-down is a MODE, entered when the pool has nowhere comfortable to go. This is
# the exact live shape that motivated it: the active account (primary) is at 91% used
# / 9% left, UNDER the 20% health floor, so every run told him to switch, while the
# only alternative, wk, has 31% left, i.e. under the 50% comfortable mark. So: STAY,
# the row must not also print a "skipped … under the floor" contradiction, `rota switch`
# with no argument must refuse (exit 0, not an error), the reason must name the mode
# and the numbers that chose it, and the JSON must say the same thing in the same
# words. Scenario 34 is the same fixture with a roomy pool, where FLOOR mode is right
# and it switches exactly as it always did.
burn_fixture() {  # burn_fixture <name> <active-weekly-used> [alt-weekly-used=69]
  new_run "$1"
  mkdir -p "$RUN/.claude-pool/primary" "$RUN/.claude-pool/wk"
  printf '{"claudeAiOauth":{"accessToken":"TOK-BD-SHARED"}}' > "$RUN/.claude/.credentials.json"
  cp "$RUN/.claude/.credentials.json" "$RUN/.claude-pool/primary/.credentials.json"
  printf '{"oauthAccount":{"emailAddress":"primary@example.com"}}' > "$RUN/.claude-pool/primary/.claude.json"
  printf '{"claudeAiOauth":{"accessToken":"TOK-BD-WK"}}' > "$RUN/.claude-pool/wk/.credentials.json"
  printf '{"oauthAccount":{"emailAddress":"wk@example.com"}}' > "$RUN/.claude-pool/wk/.claude.json"
  printf '{"oauthAccount":{"emailAddress":"primary@example.com"}}' > "$RUN/.claude.json"
  cat > "$RUN/cfg/accounts" <<EOF
primary@example.com|$RUN/.claude-pool/primary
wk@example.com|$RUN/.claude-pool/wk
EOF
  printf '{"seven_day":{"utilization":%s,"resets_at":"%s"},"five_hour":{"utilization":68,"resets_at":"%s"}}' \
    "$2" "$(iso_in +10H)" "$(iso_in +4H)" > "$RUN/state/usage-TOK-BD-SHARED.json"
  printf '{"seven_day":{"utilization":%s,"resets_at":"%s"},"five_hour":{"utilization":0,"resets_at":"%s"}}' \
    "${3:-69}" "$(iso_in +4d)" "$(iso_in +5H)" > "$RUN/state/usage-TOK-BD-WK.json"
}

burn_fixture burndown 91
set +e
OUT="$(FAKE_NEW_EMAIL=primary@example.com "$SCRIPT" usage 2>/dev/null)"
VOUT="$(FAKE_NEW_EMAIL=primary@example.com "$SCRIPT" usage --verbose 2>/dev/null)"
JSON_OUT="$(FAKE_NEW_EMAIL=primary@example.com "$SCRIPT" usage --json 2>/dev/null)"
SW_OUT="$(FAKE_NEW_EMAIL=primary@example.com "$SCRIPT" switch-auto --dry-run 2>&1)"
SW_RC=$?
set -e
grep -q "^→ stay on primary@example.com: weekly 91% used · 9% left" <<<"$OUT" \
  && ok "burn-down → STAYS on an account under the 20% floor but with real headroom" \
  || bad "burn-down → stays on the active account (got: $OUT)"
! grep -q "switch to wk@example.com" <<<"$OUT" \
  && ok "burn-down → never recommends switching off headroom he is still spending" \
  || bad "burn-down → must not recommend a switch (got: $OUT)"
grep -q "spend it down before it resets" <<<"$OUT" \
  && ok "burn-down → says the deadline the headroom is racing" \
  || bad "burn-down → names the reset (got: $OUT)"
grep -q "switch at ~2% left" <<<"$OUT" \
  && ok "burn-down → states the threshold that will end the hold" \
  || bad "burn-down → states the threshold (got: $OUT)"
grep -q 'Then `rota switch` moves to wk@example.com' <<<"$OUT" \
  && ok "burn-down → still names where the ranking sends him next" \
  || bad "burn-down → names the next account (got: $OUT)"
grep -q "mode: burn-down, nowhere comfortable to go (best other account wk@example.com at 31% weekly left, comfortable mark 50%)" <<<"$OUT" \
  && ok "burn-down → names the MODE and the pool numbers that triggered it" \
  || bad "burn-down → names the mode and its trigger (got: $OUT)"
# the row it recommends must not simultaneously say it was skipped, checked
# against --verbose, which is the only view that carries skip reasons at all, so
# the assertion cannot pass merely because the default view hides them
bd_block="$(active_block <<<"$VOUT")"
grep -q "primary@example.com" <<<"$bd_block" \
  && ! grep -q "skipped" <<<"$bd_block" \
  && ok "burn-down → the held row is the ACTIVE block and drops its 'under the floor' skip reason" \
  || bad "burn-down → the held row must not say skipped (got: $bd_block)"
[ "$(jq -r '.recommendation.action' <<<"$JSON_OUT")" = "stay" ] \
  && ok "burn-down (json) → action is stay" \
  || bad "burn-down (json) → action is stay (got: $(jq -c '.recommendation' <<<"$JSON_OUT" 2>/dev/null))"
[ "$(jq -r '.recommendation.burn_down_hold' <<<"$JSON_OUT")" = "true" ] \
  && ok "burn-down (json) → burn_down_hold distinguishes a HOLD from a ranking that happened to stay" \
  || bad "burn-down (json) → burn_down_hold is true (got: $(jq -c '.recommendation' <<<"$JSON_OUT" 2>/dev/null))"
[ "$(jq -r '.floors | [.exhausted_pct,.comfortable_pct] | @csv' <<<"$JSON_OUT")" = '2,50' ] \
  && ok "burn-down (json) → both new thresholds are published alongside the floors" \
  || bad "burn-down (json) → floors.exhausted_pct/comfortable_pct (got: $(jq -c '.floors' <<<"$JSON_OUT" 2>/dev/null))"
[ "$(jq -r '.recommendation | [.mode,.mode_forced,.best_alternative.email,.best_alternative.weekly_left_pct] | @csv' <<<"$JSON_OUT")" = '"burn-down",false,"wk@example.com",31' ] \
  && ok "burn-down (json) → mode + trigger numbers are machine-readable, not only in the prose" \
  || bad "burn-down (json) → mode + best_alternative (got: $(jq -c '.recommendation' <<<"$JSON_OUT" 2>/dev/null))"
[ "$(jq -r '.accounts[] | select(.email=="primary@example.com") | .recommendable' <<<"$JSON_OUT")" = "true" ] \
  && ok "burn-down (json) → the held row is recommendable, matching the sentence" \
  || bad "burn-down (json) → held row is recommendable (got: $(jq -c '.accounts[]|select(.email=="primary@example.com")' <<<"$JSON_OUT" 2>/dev/null))"
# The reason must be the WHOLE recommendation block the terminal printed, the stay
# sentence AND the mode line, collapsed exactly the way json_usage collapses it, so
# the phone and the terminal can never explain the same pick differently.
# The `(in 9h59m)` countdown is normalised away on BOTH sides: these are two separate
# runs and it legitimately ticks between them, which would fail an otherwise exact
# comparison once a minute for no reason.
same_sentence() { sed 's/(in [^)]*)/(in …)/g'; }
[ "$(jq -r '.recommendation.reason' <<<"$JSON_OUT" | same_sentence)" \
   = "$(grep -E '^→ |^  mode: ' <<<"$OUT" | tr '\n' ' ' | sed 's/  */ /g; s/ *$//' | same_sentence)" ] \
  && ok "burn-down (json) → reason is the terminal's own sentence, mode line included" \
  || bad "burn-down (json) → reason matches the terminal (got: $(jq -r '.recommendation.reason' <<<"$JSON_OUT"))"
[ "$SW_RC" -eq 0 ] \
  && ok "burn-down → a bare \`rota switch\` exits 0, not an error" \
  || bad "burn-down → switch-auto exits 0 (got $SW_RC: $SW_OUT)"
grep -q "^→ stay on primary@example.com" <<<"$SW_OUT" \
  && ok "burn-down → switch-auto refuses and prints the SAME stay sentence" \
  || bad "burn-down → switch-auto prints the stay reason (got: $SW_OUT)"
! grep -q "optimizer pick" <<<"$SW_OUT" \
  && ok "burn-down → switch-auto never announces a pick it is not going to make" \
  || bad "burn-down → switch-auto must not announce a pick (got: $SW_OUT)"

# --- 32. the threshold is a real boundary, and it is tunable -------------------
# 3% left → still holding. 2% left → at the threshold, the burn-down is over and the
# ordinary ranking (floor + soonest reset) takes back over. And the whole rule moves
# with CLAUDE_FAILOVER_EXHAUSTED, so 9% left switches when the threshold is 10.
burn_fixture burnedge97 97
set +e
OUT="$(FAKE_NEW_EMAIL=primary@example.com "$SCRIPT" usage 2>/dev/null)"
set -e
grep -q "^→ stay on primary@example.com: weekly 97% used · 3% left" <<<"$OUT" \
  && ok "threshold → 3% left is still above the 2% threshold: hold" \
  || bad "threshold → 3% left holds (got: $OUT)"

burn_fixture burnedge98 98
set +e
OUT="$(FAKE_NEW_EMAIL=primary@example.com "$SCRIPT" usage 2>/dev/null)"
JSON_OUT="$(FAKE_NEW_EMAIL=primary@example.com "$SCRIPT" usage --json 2>/dev/null)"
set -e
grep -q "switch to wk@example.com" <<<"$OUT" \
  && ok "threshold → 2% left is AT the threshold: the ranking decides again" \
  || bad "threshold → 2% left switches (got: $OUT)"
grep -q "soonest weekly reset among the accounts clearing the health floor" <<<"$OUT" \
  && ok "threshold → the target is picked by the EXISTING rule, unchanged" \
  || bad "threshold → target picked by the existing ranking (got: $OUT)"
[ "$(jq -r '.recommendation.burn_down_hold' <<<"$JSON_OUT")" = "false" ] \
  && ok "threshold (json) → burn_down_hold clears once the account is spent" \
  || bad "threshold (json) → burn_down_hold is false (got: $(jq -c '.recommendation' <<<"$JSON_OUT" 2>/dev/null))"

burn_fixture burnenv 91
set +e
OUT="$(CLAUDE_FAILOVER_EXHAUSTED=10 FAKE_NEW_EMAIL=primary@example.com "$SCRIPT" usage 2>/dev/null)"
set -e
grep -q "switch to wk@example.com" <<<"$OUT" \
  && ok "threshold → CLAUDE_FAILOVER_EXHAUSTED=10 makes 9% left count as spent" \
  || bad "threshold → the env override moves the boundary (got: $OUT)"

# --- 33. a HOLD decided on cached numbers must say so --------------------------
# Staying put is the conservative direction, so, unlike the pick, cached numbers are
# allowed to hold. The age must ride along, exactly as switch-auto's cached fallback
# labels its pick.
new_run burncached
mkdir -p "$RUN/.claude-pool/primary" "$RUN/.claude-pool/wk"
printf '{"claudeAiOauth":{"accessToken":"TOK-BC-SHARED"}}' > "$RUN/.claude/.credentials.json"
cp "$RUN/.claude/.credentials.json" "$RUN/.claude-pool/primary/.credentials.json"
printf '{"oauthAccount":{"emailAddress":"primary@example.com"}}' > "$RUN/.claude-pool/primary/.claude.json"
printf '{"claudeAiOauth":{"accessToken":"TOK-BC-WK"}}' > "$RUN/.claude-pool/wk/.credentials.json"
printf '{"oauthAccount":{"emailAddress":"wk@example.com"}}' > "$RUN/.claude-pool/wk/.claude.json"
printf '{"oauthAccount":{"emailAddress":"primary@example.com"}}' > "$RUN/.claude.json"
cat > "$RUN/cfg/accounts" <<EOF
primary@example.com|$RUN/.claude-pool/primary
wk@example.com|$RUN/.claude-pool/wk
EOF
cat > "$RUN/cfg/usage-cache.json" <<EOF
{
  "primary@example.com": {"wk_u":"91","wk_r":"$(iso_in +10H)","se_u":"68","se_r":"$(iso_in +4H)","ts":"Jul 20 02:14","ts_epoch":"1784585640"},
  "wk@example.com":      {"wk_u":"69","wk_r":"$(iso_in +4d)","se_u":"0","se_r":"$(iso_in +5H)","ts":"Jul 20 02:14","ts_epoch":"1784585640"}
}
EOF
set +e
OUT="$(FAKE_NEW_EMAIL=primary@example.com "$SCRIPT" usage --no-refresh 2>/dev/null)"
JSON_OUT="$(FAKE_NEW_EMAIL=primary@example.com "$SCRIPT" usage --no-refresh --json 2>/dev/null)"
set -e
grep -q "^→ stay on primary@example.com: weekly 91% used · 9% left" <<<"$OUT" \
  && ok "cached hold → cached numbers may hold him (staying put is the safe direction)" \
  || bad "cached hold → holds on cached numbers (got: $OUT)"
grep -q "\[from CACHED numbers, Jul 20 02:14" <<<"$OUT" \
  && ok "cached hold → the decision is labelled as made on cached numbers" \
  || bad "cached hold → labels the cached decision (got: $OUT)"
[ "$(jq -r '.recommendation.from_cached_numbers' <<<"$JSON_OUT")" = "true" ] \
  && ok "cached hold (json) → from_cached_numbers travels with the hold" \
  || bad "cached hold (json) → from_cached_numbers is true (got: $(jq -c '.recommendation' <<<"$JSON_OUT" 2>/dev/null))"

# --- 34. A ROOMY POOL keeps the 20% floor exactly as it was --------------------
# The other half of the two-mode rule, and the one that stops this from becoming a
# permanent inversion of the floor. Same active account as scenario 31 (91% used /
# 9% left), but wk is fresh-ish at 80% left, at or above the 50% comfortable mark, so
# there IS somewhere good to go, moving off 9% costs nothing, and the recommendation
# must be the unchanged pre-2026-08-06 one: switch to wk.
burn_fixture roomy 91 20
set +e
OUT="$(FAKE_NEW_EMAIL=primary@example.com "$SCRIPT" usage 2>/dev/null)"
VOUT="$(FAKE_NEW_EMAIL=primary@example.com "$SCRIPT" usage --verbose 2>/dev/null)"
JSON_OUT="$(FAKE_NEW_EMAIL=primary@example.com "$SCRIPT" usage --json 2>/dev/null)"
SW_OUT="$(FAKE_NEW_EMAIL=primary@example.com "$SCRIPT" switch-auto --dry-run 2>&1)"
SW_RC=$?
set -e
grep -q "switch to wk@example.com" <<<"$OUT" \
  && ok "roomy pool → FLOOR mode: still switches off a 9%-left account, exactly as before" \
  || bad "roomy pool → recommends switching to wk (got: $OUT)"
grep -q "is nearly exhausted (weekly 91% used · 9% left" <<<"$OUT" \
  && ok "roomy pool → the pre-existing act_note wording is untouched" \
  || bad "roomy pool → act_note unchanged (got: $OUT)"
grep -q "skipped weekly 91% used · 9% left is under the 20%-left floor" <<<"$VOUT" \
  && ok "roomy pool → the floor still excludes the active row, with its own reason (--verbose)" \
  || bad "roomy pool → the floor still excludes the active row (got: $VOUT)"
grep -q "mode: floor, there IS somewhere good to go (best other account wk@example.com at 80% weekly left, comfortable mark 50%)" <<<"$OUT" \
  && ok "roomy pool → says WHY the floor is governing, with the numbers" \
  || bad "roomy pool → names the floor mode and its trigger (got: $OUT)"
[ "$(jq -r '.recommendation | [.mode,.action,.burn_down_hold] | @csv' <<<"$JSON_OUT")" = '"floor","switch",false' ] \
  && ok "roomy pool (json) → mode floor, action switch, no hold" \
  || bad "roomy pool (json) → mode/action/hold (got: $(jq -c '.recommendation' <<<"$JSON_OUT" 2>/dev/null))"
[ "$SW_RC" -eq 0 ] && grep -q "optimizer pick: wk@example.com" <<<"$SW_OUT" \
  && ok "roomy pool → a bare \`rota switch\` switches again instead of refusing" \
  || bad "roomy pool → switch-auto picks wk (got $SW_RC: $SW_OUT)"

# --- 35. CLAUDE_FAILOVER_MODE forces either mode regardless of the trigger ------
# Both directions, on fixtures whose auto-trigger says the opposite, so the override is
# proved to be doing the work and not just agreeing with the default.
set +e
OUT="$(CLAUDE_FAILOVER_MODE=burn-down FAKE_NEW_EMAIL=primary@example.com "$SCRIPT" usage 2>/dev/null)"
set -e
grep -q "^→ stay on primary@example.com" <<<"$OUT" \
  && ok "forced mode → CLAUDE_FAILOVER_MODE=burn-down holds even with a roomy pool" \
  || bad "forced mode → burn-down forced on a roomy pool (got: $OUT)"
grep -q "mode: burn-down (forced by CLAUDE_FAILOVER_MODE)" <<<"$OUT" \
  && ok "forced mode → says the mode was forced, not inferred" \
  || bad "forced mode → labels the override (got: $OUT)"
# the pool numbers are reported, but never as a comparison the override just bypassed
grep -q "comfortable mark 50%" <<<"$OUT" \
  && ! grep -qE "(at or above|under) the 50% (comfortable )?mark" <<<"$OUT" \
  && ok "forced mode → reports what the trigger SAW without claiming it decided" \
  || bad "forced mode → must not restate a bypassed comparison (got: $OUT)"

burn_fixture forcedfloor 91
set +e
OUT="$(CLAUDE_FAILOVER_MODE=floor FAKE_NEW_EMAIL=primary@example.com "$SCRIPT" usage 2>/dev/null)"
JSON_OUT="$(CLAUDE_FAILOVER_MODE=floor FAKE_NEW_EMAIL=primary@example.com "$SCRIPT" usage --json 2>/dev/null)"
set -e
grep -q "switch to wk@example.com" <<<"$OUT" \
  && ok "forced mode → CLAUDE_FAILOVER_MODE=floor switches even under scarcity" \
  || bad "forced mode → floor forced under scarcity (got: $OUT)"
[ "$(jq -r '.recommendation | [.mode,.mode_forced] | @csv' <<<"$JSON_OUT")" = '"floor",true' ] \
  && ok "forced mode (json) → mode_forced flags the override" \
  || bad "forced mode (json) → mode_forced is true (got: $(jq -c '.recommendation' <<<"$JSON_OUT" 2>/dev/null))"
set +e
ERR_OUT="$(CLAUDE_FAILOVER_MODE=nonsense FAKE_NEW_EMAIL=primary@example.com "$SCRIPT" usage 2>&1)"
ERR_RC=$?
set -e
[ "$ERR_RC" -ne 0 ] && grep -q "CLAUDE_FAILOVER_MODE must be auto, floor or burn-down" <<<"$ERR_OUT" \
  && ok "forced mode → a typo'd mode fails loudly instead of silently reverting to auto" \
  || bad "forced mode → rejects an unknown mode (got $ERR_RC: $ERR_OUT)"

# --- 36. `repair-nested`: the trap scenario 15 only REPORTS, now fixed ---------
# The fix is a SYMLINK, never a delete: nested_config_warning() already reads
# same-file (`-ef`) as healthy, so pointing the nested config at ~/.claude.json makes a
# CLAUDE_CONFIG_DIR=$HOME/.claude probe answer correctly instead of not at all, and one
# file cannot drift from itself. Every scenario here runs against the sandbox $HOME
# new_run() builds; nothing below can reach the real ~/.claude.
#
# Deliberately NO accounts file in these fixtures: the trap is a property of ~/.claude,
# not of the account pool, so the verb has to work on a box that was never set up.
run_repair() {  # run_repair [args…] → RC/OUT
  set +e
  OUT="$("$SCRIPT" repair-nested "$@" 2>&1)"
  RC=$?
  set -e
}
# The backups that exist, by glob rather than `ls`, every name here starts with a dot,
# so a plain `ls` listed none of them and silently counted zero. An unmatched glob stays
# literal, hence the -e guard; `if` rather than `&&` so a zero-backup run is an answer
# and not a set -e abort.
bak_names() {
  local f
  for f in "$RUN"/.claude/.claude.json.stale-bak-*; do
    if [ -e "$f" ]; then basename "$f"; fi
  done
}
nested_bak() {
  local f n=0
  for f in "$RUN"/.claude/.claude.json.stale-bak-*; do
    if [ -e "$f" ]; then n=$((n + 1)); fi
  done
  printf '%s' "$n"
}

# 36a. absent nested file → no-op, exit 0
new_run repair-absent
printf '{"oauthAccount":{"emailAddress":"live@example.com"}}' > "$RUN/.claude.json"
run_repair
[ "$RC" -eq 0 ] && ok "repair-nested → absent nested file exits 0" \
  || bad "repair-nested → absent nested file exits 0 (got $RC: $OUT)"
grep -q "nothing to repair" <<<"$OUT" \
  && ok "repair-nested → absent nested file says 'nothing to repair'" \
  || bad "repair-nested → says nothing to repair (got: $OUT)"
[ ! -e "$RUN/.claude/.claude.json" ] && [ "$(nested_bak)" = "0" ] \
  && ok "repair-nested → absent nested file creates nothing at all" \
  || bad "repair-nested → created something out of nothing (dir: $(ls -a "$RUN/.claude"))"

# 36b. already the same file → no-op, exit 0, and NO second backup on a re-run
new_run repair-idempotent
printf '{"oauthAccount":{"emailAddress":"live@example.com"}}' > "$RUN/.claude.json"
ln -s "$RUN/.claude.json" "$RUN/.claude/.claude.json"
run_repair
[ "$RC" -eq 0 ] && ok "repair-nested → already-repaired box exits 0" \
  || bad "repair-nested → already-repaired box exits 0 (got $RC: $OUT)"
grep -q "already healthy" <<<"$OUT" \
  && ok "repair-nested → already-repaired box says 'already healthy'" \
  || bad "repair-nested → says already healthy (got: $OUT)"
[ "$(nested_bak)" = "0" ] \
  && ok "repair-nested → idempotent: a re-run makes NO second backup" \
  || bad "repair-nested → re-run littered a backup ($(bak_names))"
[ -L "$RUN/.claude/.claude.json" ] \
  && ok "repair-nested → the existing symlink is left in place" \
  || bad "repair-nested → clobbered a healthy symlink"

# 36c. the real thing: a drifted stale nested config
new_run repair-drift
STALE='{"oauthAccount":{"emailAddress":"stale@example.com"}}'
printf '{"oauthAccount":{"emailAddress":"live@example.com"}}' > "$RUN/.claude.json"
printf '%s' "$STALE" > "$RUN/.claude/.claude.json"
run_repair
[ "$RC" -eq 0 ] && ok "repair-nested → a drifted config repairs and exits 0" \
  || bad "repair-nested → drifted config exits 0 (got $RC: $OUT)"
[ -L "$RUN/.claude/.claude.json" ] \
  && ok "repair-nested → the nested config is now a symlink" \
  || bad "repair-nested → nested config is not a symlink (got: $(ls -l "$RUN/.claude/.claude.json"))"
[ "$RUN/.claude/.claude.json" -ef "$RUN/.claude.json" ] \
  && ok "repair-nested → -ef now passes, i.e. the warning's own healthy test" \
  || bad "repair-nested → -ef still fails after the repair"
BAK="$(bak_names | head -1)"
[ -n "$BAK" ] && [ "$(cat "$RUN/.claude/$BAK")" = "$STALE" ] \
  && ok "repair-nested → the backup holds the ORIGINAL bytes" \
  || bad "repair-nested → backup missing or rewritten (bak='$BAK')"
grep -q "stale@example.com" <<<"$OUT" && grep -q "live@example.com" <<<"$OUT" \
  && ok "repair-nested → prints the identity before AND after" \
  || bad "repair-nested → names both identities (got: $OUT)"
# and the trap is genuinely gone: a probe reading the nested path now sees the live account
[ "$(jq -r '.oauthAccount.emailAddress' "$RUN/.claude/.claude.json")" = "live@example.com" ] \
  && ok "repair-nested → a CLAUDE_CONFIG_DIR=\$HOME/.claude probe now reads the RIGHT account" \
  || bad "repair-nested → nested path still resolves to the wrong account"
# The drift really is gone, not just currently-agreeing: a WRITE to the nested path now
# lands in ~/.claude.json itself, so there is no second file left to fall behind.
printf '{"oauthAccount":{"emailAddress":"second@example.com"}}' > "$RUN/.claude/.claude.json"
[ "$(jq -r '.oauthAccount.emailAddress' "$RUN/.claude.json")" = "second@example.com" ] \
  && ok "repair-nested → after the repair a write to the nested path IS a write to the root" \
  || bad "repair-nested → the two paths are still separate files"
# A box that drifts AGAIN on the same day must not clobber the first backup, that copy
# is the only surviving record of what it drifted to the first time.
printf '{"oauthAccount":{"emailAddress":"live@example.com"}}' > "$RUN/.claude.json"
rm -f "$RUN/.claude/.claude.json"
printf '{"oauthAccount":{"emailAddress":"second@example.com"}}' > "$RUN/.claude/.claude.json"
run_repair
[ "$(nested_bak)" = "2" ] && [ "$(cat "$RUN/.claude/$BAK")" = "$STALE" ] \
  && ok "repair-nested → a same-day second backup gets a non-colliding name" \
  || bad "repair-nested → same-day backup collided ($(bak_names))"

# 36d. no valid root to point at → REFUSE, non-zero, nested left byte-for-byte alone
new_run repair-noroot
printf '%s' "$STALE" > "$RUN/.claude/.claude.json"
run_repair
[ "$RC" -ne 0 ] && ok "repair-nested → refuses (non-zero) when ~/.claude.json is missing" \
  || bad "repair-nested → must refuse without a root config (got $RC: $OUT)"
[ "$(cat "$RUN/.claude/.claude.json")" = "$STALE" ] && [ ! -L "$RUN/.claude/.claude.json" ] \
  && ok "repair-nested → refusal leaves the nested file byte-for-byte untouched" \
  || bad "repair-nested → refusal modified the nested file"
[ "$(nested_bak)" = "0" ] \
  && ok "repair-nested → a refusal writes no backup either" \
  || bad "repair-nested → refusal still littered a backup"
# a root that EXISTS but is not valid JSON is the same refusal, a symlink to a
# truncated config is strictly worse than the drift it would replace
printf 'not json at all' > "$RUN/.claude.json"
run_repair
[ "$RC" -ne 0 ] && grep -q "not valid JSON" <<<"$OUT" \
  && ok "repair-nested → refuses when the root config is not valid JSON" \
  || bad "repair-nested → must refuse on an unparseable root (got $RC: $OUT)"
[ "$(cat "$RUN/.claude/.claude.json")" = "$STALE" ] \
  && ok "repair-nested → the unparseable-root refusal is also non-destructive" \
  || bad "repair-nested → modified the nested file on an unparseable root"

# 36e. --dry-run changes nothing
new_run repair-dryrun
printf '{"oauthAccount":{"emailAddress":"live@example.com"}}' > "$RUN/.claude.json"
printf '%s' "$STALE" > "$RUN/.claude/.claude.json"
run_repair --dry-run
[ "$RC" -eq 0 ] && ok "repair-nested --dry-run → exits 0" \
  || bad "repair-nested --dry-run → exits 0 (got $RC: $OUT)"
grep -q "dry-run" <<<"$OUT" \
  && ok "repair-nested --dry-run → says it is a dry run" \
  || bad "repair-nested --dry-run → labels itself (got: $OUT)"
[ "$(cat "$RUN/.claude/.claude.json")" = "$STALE" ] && [ ! -L "$RUN/.claude/.claude.json" ] \
  && ok "repair-nested --dry-run → the nested file is untouched" \
  || bad "repair-nested --dry-run → modified the nested file"
[ "$(nested_bak)" = "0" ] \
  && ok "repair-nested --dry-run → no backup written" \
  || bad "repair-nested --dry-run → wrote a backup ($(bak_names))"

# 36f. discoverability: --help lists it, and the warning names it as the remedy
set +e
HELP_OUT="$("$SCRIPT" --help 2>&1)"
HELP_RC=$?
set -e
[ "$HELP_RC" -eq 0 ] && grep -q "repair-nested" <<<"$HELP_OUT" \
  && ok "repair-nested → listed in --help (exit $HELP_RC)" \
  || bad "repair-nested → must appear in --help (got $HELP_RC)"
# the warning scenario 15 exercises must now point at the fix, not just describe the trap
new_run repair-warnpoints
mkdir -p "$RUN/.claude-pool/solo"
printf '{"claudeAiOauth":{"accessToken":"TOK-FIX"}}' > "$RUN/.claude-pool/solo/.credentials.json"
printf '{"oauthAccount":{"emailAddress":"live@example.com"}}' > "$RUN/.claude-pool/solo/.claude.json"
printf '{"oauthAccount":{"emailAddress":"live@example.com"}}' > "$RUN/.claude.json"
printf '%s' "$STALE" > "$RUN/.claude/.claude.json"
cat > "$RUN/cfg/accounts" <<EOF
live@example.com|$RUN/.claude-pool/solo
EOF
printf '{"seven_day":{"utilization":20,"resets_at":"%s"},"five_hour":{"utilization":20,"resets_at":"%s"}}' \
  "$(iso_in +3d)" "$(iso_in +2H)" > "$RUN/state/usage-TOK-FIX.json"
set +e
WARN_OUT="$(FAKE_NEW_EMAIL=live@example.com "$SCRIPT" usage 2>/dev/null)"
set -e
grep -q "repair-nested" <<<"$WARN_OUT" \
  && ok "nested warning → names \`repair-nested\` as the remedy" \
  || bad "nested warning → must name the fix (got: $WARN_OUT)"
grep -q "stale NESTED config" <<<"$WARN_OUT" \
  && ok "nested warning → keeps its existing explanatory wording" \
  || bad "nested warning → lost its original text (got: $WARN_OUT)"

# --- 37. `rota switch` explains ITSELF: the picture ships with the decision -----
# the operator, 2026-08-06: "maybe it'd be good if the output could also show why you made
# that decision and where the other accounts are at, so I never have to go and check."
# switch-auto used to answer in ONE line and then charge a second command for the
# reasoning:
#   rota-engine: no other account clearing the health floor (>=20% weekly,
#   >=10% 5h; current: seat-a@example.com), on live OR cached numbers, see `rota usage`
# It now prints the SAME per-account table `usage` prints, the same renderer, so the
# two surfaces cannot describe the pool differently, then the decision and its
# rationale, then acts. `--quiet` keeps the old terse one-liner, pointer included,
# for anything parsing this output.
explains_fixture() {  # explains_fixture <name>
  new_run "$1"
  mkdir -p "$RUN/.claude-pool/primary" "$RUN/.claude-pool/wk" "$RUN/.claude-pool/alpha"
  # COMPLETE-shaped credentials (v2): scenario 43 drives a REAL switch through
  # this fixture, and the pointer switch refuses a husk, an accessToken alone
  # no longer passes.
  local ex_exp=$(( ($(date +%s) + 86400) * 1000 ))
  printf '{"claudeAiOauth":{"accessToken":"TOK-EX-SHARED","refreshToken":"rt-ex-shared","expiresAt":%s,"refreshTokenExpiresAt":%s}}' \
    "$ex_exp" "$ex_exp" > "$RUN/.claude/.credentials.json"
  cp "$RUN/.claude/.credentials.json" "$RUN/.claude-pool/primary/.credentials.json"
  printf '{"oauthAccount":{"emailAddress":"primary@example.com"}}' > "$RUN/.claude-pool/primary/.claude.json"
  printf '{"claudeAiOauth":{"accessToken":"TOK-EX-WK","refreshToken":"rt-ex-wk","expiresAt":%s,"refreshTokenExpiresAt":%s}}' \
    "$ex_exp" "$ex_exp" > "$RUN/.claude-pool/wk/.credentials.json"
  printf '{"oauthAccount":{"emailAddress":"wk@example.com"}}' > "$RUN/.claude-pool/wk/.claude.json"
  printf '{"claudeAiOauth":{"accessToken":"TOK-EX-ALPHA","refreshToken":"rt-ex-alpha","expiresAt":%s,"refreshTokenExpiresAt":%s}}' \
    "$ex_exp" "$ex_exp" > "$RUN/.claude-pool/alpha/.credentials.json"
  printf '{"oauthAccount":{"emailAddress":"alpha@example.com"}}' > "$RUN/.claude-pool/alpha/.claude.json"
  printf '{"oauthAccount":{"emailAddress":"primary@example.com"}}' > "$RUN/.claude.json"
  cat > "$RUN/cfg/accounts" <<EOF
primary@example.com|$RUN/.claude-pool/primary
wk@example.com|$RUN/.claude-pool/wk
alpha@example.com|$RUN/.claude-pool/alpha
EOF
  # The active account is at 98% used, AT the exhaustion threshold, so the burn-down
  # hold is over and the ordinary ranking decides. wk clears the floor (80% left);
  # alpha does not (5% left), so it earns a per-row skip reason worth printing.
  printf '{"seven_day":{"utilization":98,"resets_at":"%s"},"five_hour":{"utilization":50,"resets_at":"%s"}}' \
    "$(iso_in +10H)" "$(iso_in +4H)" > "$RUN/state/usage-TOK-EX-SHARED.json"
  printf '{"seven_day":{"utilization":20,"resets_at":"%s"},"five_hour":{"utilization":0,"resets_at":"%s"}}' \
    "$(iso_in +4d)" "$(iso_in +5H)" > "$RUN/state/usage-TOK-EX-WK.json"
  printf '{"seven_day":{"utilization":95,"resets_at":"%s"},"five_hour":{"utilization":10,"resets_at":"%s"}}' \
    "$(iso_in +2d)" "$(iso_in +3H)" > "$RUN/state/usage-TOK-EX-ALPHA.json"
}

explains_fixture explains
set +e
EX_OUT="$(FAKE_NEW_EMAIL=primary@example.com "$SCRIPT" switch-auto --dry-run 2>&1)"
EX_RC=$?
EX_OUT_V="$(FAKE_NEW_EMAIL=primary@example.com "$SCRIPT" switch-auto --dry-run --verbose 2>&1)"
EXQ_OUT="$(FAKE_NEW_EMAIL=primary@example.com "$SCRIPT" switch-auto --dry-run --quiet 2>&1)"
EXQ_RC=$?
# ⚠️ AN EMPTY BILLING FILE, PINNED ON PURPOSE. `usage` reads billing.json now,
# for seat status, end dates and dated `boosts`. Under this suite that path
# resolves inside the throwaway $CFG_DIR and does not exist, but pinning it says
# so out loud: a golden snapshot that ever read a REAL billing file would
# inherit its dated boosts and then fail by itself on the day one expired, with
# a diff pointing at a line nobody touched.
printf '{"accounts":{}}\n' > "$RUN/no-billing.json"
EX_USAGE="$(FAKE_NEW_EMAIL=primary@example.com CLAUDE_BILLING_JSON="$RUN/no-billing.json" "$SCRIPT" usage 2>/dev/null)"
set -e

[ "$EX_RC" -eq 0 ] && ok "self-explaining switch → still exits 0 and still switches" \
  || bad "self-explaining switch → exits 0 (got $EX_RC: $EX_OUT)"
# a ROW for every configured account, not just the one it picked
[ "$(rendered_rows <<<"$EX_OUT")" -eq 3 ] \
  && ok "self-explaining switch → renders a row for EVERY configured account" \
  || bad "self-explaining switch → one row per account (got: $EX_OUT)"
grep -q '^      slot    alpha@example.com · ~/.claude-pool/alpha' <<<"$EX_OUT_V" \
  && grep -q '^      slot    wk@example.com · ~/.claude-pool/wk' <<<"$EX_OUT_V" \
  && grep -q '^      slot    primary@example.com · ~/.claude-pool/primary' <<<"$EX_OUT_V" \
  && ok "self-explaining switch → --verbose names every account with its own slot + pool dir" \
  || bad "self-explaining switch → names each slot (got: $EX_OUT_V)"
# the active account is metered; the others are one compact line each
grep -qE '^▶ ACTIVE   primary@example\.com +\[live\]' <<<"$EX_OUT" \
  && ok "self-explaining switch → the active account heads the table as ▶ ACTIVE" \
  || bad "self-explaining switch → marks the active row (got: $EX_OUT)"
grep -qE '^    weekly  [█░]{15} +2% left · 98% used' <<<"$EX_OUT" \
  && grep -qE '^    5h      [█░]{15} +50% left · 50% used' <<<"$EX_OUT" \
  && ok "self-explaining switch → the active account's windows are metered, both polarities" \
  || bad "self-explaining switch → metered active windows (got: $EX_OUT)"
grep -qE '^  ✓ wk@example\.com +weekly  80% left · 5h 100% left +rota switch wk' <<<"$(alt_block <<<"$EX_OUT")" \
  && ok "self-explaining switch → the switchable account is an ALTERNATIVE, with the exact command" \
  || bad "self-explaining switch → ALTERNATIVES row + command (got: $EX_OUT)"
# the PER-ACCOUNT reason, "where the other accounts are at" is only half the ask
grep -qE '^  ✗ alpha@example\.com +weekly 5% left' <<<"$(unavail_block <<<"$EX_OUT")" \
  && ok "self-explaining switch → each unavailable account says why, in its own column" \
  || bad "self-explaining switch → per-account short reasons (got: $EX_OUT)"
grep -q '^      skipped weekly 95% used · 5% left is under the 20%-left floor' <<<"$EX_OUT_V" \
  && ok "self-explaining switch → --verbose still carries the full skip sentence" \
  || bad "self-explaining switch → --verbose skip sentence (got: $EX_OUT_V)"
# the decision AND its rationale, in the dashboard's own words
grep -q '^→ switch to wk@example.com' <<<"$EX_OUT" \
  && ok "self-explaining switch → states the decision" \
  || bad "self-explaining switch → states the decision (got: $EX_OUT)"
grep -q '^  soonest weekly reset among the accounts clearing the health floor' <<<"$EX_OUT" \
  && ok "self-explaining switch → states the RATIONALE for that decision" \
  || bad "self-explaining switch → states the rationale (got: $EX_OUT)"
grep -q '^  mode: floor, there IS somewhere good to go' <<<"$EX_OUT" \
  && ok "self-explaining switch → names the mode that produced the decision" \
  || bad "self-explaining switch → names the mode (got: $EX_OUT)"
# and it still ACTS: the pick line and the dry-run marker are untouched
grep -q '^optimizer pick: wk@example.com' <<<"$EX_OUT" \
  && grep -q '^(dry-run, no switch performed)$' <<<"$EX_OUT" \
  && ok "self-explaining switch → the action lines are unchanged underneath the table" \
  || bad "self-explaining switch → action lines unchanged (got: $EX_OUT)"

# --quiet is the OLD behaviour, byte for byte: the pick line and the dry-run marker,
# nothing else. Anything parsing this output can opt back in.
[ "$EXQ_RC" -eq 0 ] && [ "$(wc -l <<<"$EXQ_OUT" | tr -d ' ')" = "2" ] \
  && ok "--quiet → back to the terse two-line answer (pick + dry-run marker)" \
  || bad "--quiet → terse output (got $EXQ_RC, $(wc -l <<<"$EXQ_OUT") lines: $EXQ_OUT)"
! grep -q 'Claude account pool' <<<"$EXQ_OUT" && [ "$(rendered_rows <<<"$EXQ_OUT")" -eq 0 ] \
  && ok "--quiet → no table at all" \
  || bad "--quiet → must print no table (got: $EXQ_OUT)"
grep -q '^optimizer pick: wk@example.com' <<<"$EXQ_OUT" \
  && ok "--quiet → still makes and announces the same pick" \
  || bad "--quiet → announces the pick (got: $EXQ_OUT)"
# -q is the short form of the same flag
set +e
EXQ2_OUT="$(FAKE_NEW_EMAIL=primary@example.com "$SCRIPT" switch-auto --dry-run -q 2>&1)"
set -e
[ "$(wc -l <<<"$EXQ2_OUT" | tr -d ' ')" = "2" ] \
  && ok "--quiet → -q is the same flag" \
  || bad "--quiet → -q short form (got: $EXQ2_OUT)"
# an unknown flag is now a loud usage error rather than a silently ignored argument
set +e
EXBAD_OUT="$(FAKE_NEW_EMAIL=primary@example.com "$SCRIPT" switch-auto --nonsense 2>&1)"
EXBAD_RC=$?
set -e
[ "$EXBAD_RC" -ne 0 ] && grep -q 'switch-auto \[--dry-run\] \[--quiet\]' <<<"$EXBAD_OUT" \
  && ok "self-explaining switch → an unknown flag fails with the real usage line" \
  || bad "self-explaining switch → rejects unknown flags (got $EXBAD_RC: $EXBAD_OUT)"

# --- 38. the "see `rota usage`" pointer is GONE from the default failure path ----
# The exact line that started this. When there genuinely is nowhere to go, the verdict
# must still be a verdict (exit 1, floors named), but the rows are already on screen,
# so pointing at a second command is the round trip this change exists to remove. Under
# --quiet there IS no table, so the pointer legitimately stays.
sa_fixture nopointer 95 "$(iso_in +2d)" 96
set +e
NP_OUT="$(FAKE_NEW_EMAIL=primary@example.com "$SCRIPT" switch-auto --dry-run 2>&1)"
NP_RC=$?
NPQ_OUT="$(FAKE_NEW_EMAIL=primary@example.com "$SCRIPT" switch-auto --dry-run --quiet 2>&1)"
NPQ_RC=$?
set -e
[ "$NP_RC" -eq 1 ] && ok "no headroom → the verdict is still exit 1 (the floor is untouched)" \
  || bad "no headroom → exits 1 (got $NP_RC: $NP_OUT)"
! grep -q 'rota usage' <<<"$NP_OUT" \
  && ok "no headroom → the default answer never sends you to a second command" \
  || bad "no headroom → must not point at \`rota usage\` (got: $NP_OUT)"
[ "$(rendered_rows <<<"$NP_OUT")" -eq 3 ] \
  && ok "no headroom → it shows where all three accounts stand instead" \
  || bad "no headroom → renders every row (got: $NP_OUT)"
grep -q 'none, no other account clears the health floor right now' <<<"$NP_OUT" \
  && ok "no headroom → ALTERNATIVES says so explicitly instead of being an empty gap" \
  || bad "no headroom → empty ALTERNATIVES is named (got: $NP_OUT)"
# COLUMNS: every UNAVAILABLE row's [state] marker must start at the same offset,
# the one thing a short reason longer than its column would silently break, and
# the whole reason short_reason() keeps every arm inside 22 characters
NP_TAG_COLS="$(grep '^  ✗ ' <<<"$NP_OUT" | awk '{print index($0,"[")}' | sort -u | wc -l | tr -d ' ')"
[ "$NP_TAG_COLS" = "1" ] \
  && ok "no headroom → every UNAVAILABLE row's columns line up (no reason overflows its column)" \
  || bad "no headroom → UNAVAILABLE columns align (got: $(grep '^  ✗ ' <<<"$NP_OUT"))"
grep -q 'the reason it was skipped are in the rows above' <<<"$NP_OUT" \
  && ok "no headroom → the verdict points AT the rows it just printed" \
  || bad "no headroom → verdict references the rows (got: $NP_OUT)"
grep -q '>=20% weekly, >=10% 5h' <<<"$NP_OUT" \
  && grep -q 'on live OR cached numbers' <<<"$NP_OUT" \
  && ok "no headroom → still names the floors and both data sources" \
  || bad "no headroom → names the floors + sources (got: $NP_OUT)"
[ "$NPQ_RC" -eq 1 ] && [ "$(wc -l <<<"$NPQ_OUT" | tr -d ' ')" = "1" ] \
  && ok "--quiet no headroom → back to the single-line refusal" \
  || bad "--quiet no headroom → one line (got $NPQ_RC: $NPQ_OUT)"
grep -q 'see `rota usage`' <<<"$NPQ_OUT" \
  && ok "--quiet no headroom → keeps the pointer, since there is then no table to read" \
  || bad "--quiet no headroom → keeps the pointer (got: $NPQ_OUT)"

# --- 39. LAYOUT SNAPSHOT: the whole three-bucket dashboard, pinned --------------
# This slot used to assert that `usage` was BYTE-IDENTICAL to the pre-extraction
# dashboard. That intent expired on 2026-08-07, when the human view was
# deliberately redesigned into ▶ ACTIVE / ALTERNATIVES / UNAVAILABLE with meters
# and colour. What has NOT expired is the reason the guard existed: a whole-report
# snapshot catches the accidental change that a phrase-level grep sails past.
#
# So the snapshot stays and pins the NEW layout, every bucket header, every
# column position, the recommendation and the mode line. The byte-identity
# promise moved to the machine surface, `usage --json`, in scenario 39b: THAT is
# the output the dashboard parses, and it is the one that must not move a byte.
#
# Only genuinely clock-dependent text is normalised away (the "generated at"
# header, HH:MM reset stamps, relative countdowns and the "back <when>" column,
# whose own width varies with a one- vs two-digit day), because two runs a second
# apart legitimately differ there and nowhere else.
norm_clock() {
  sed -E 's/^Claude account pool, .*/Claude account pool, <ts>/
          s/\(in [^)]*\)/(in <t>)/g
          s/resets in [0-9]+[dhm]([0-9]+m)?/resets in <t>/g
          s/back [^[]*\[/back <when>  [/g
          s/[0-9]{2}:[0-9]{2} (today|tomorrow|[A-Za-z]{3} [0-9]{1,2} [A-Za-z]{3})/<time>/g'
}
EX_USAGE_NORM="$(norm_clock <<<"$EX_USAGE")"
EX_USAGE_WANT="$(cat <<'SNAP'
Claude account pool, <ts>

  billing now: no live pinned claude session

▶ ACTIVE   primary@example.com     [live]
    weekly  ░░░░░░░░░░░░░░░     2% left · 98% used   resets in <t>
    5h      ████████░░░░░░░    50% left · 50% used   resets in <t>

  ALTERNATIVES, have capacity, switch anytime
  ✓ wk@example.com          weekly  80% left · 5h 100% left  rota switch wk          [live]

  UNAVAILABLE
  ✗ alpha@example.com       weekly 5% left          back <when>  [live]

→ switch to wk@example.com: `rota switch wk`
  soonest weekly reset among the accounts clearing the health floor (weekly 20% used · 80% left; 5h 0% used · 100% left, resets <time> (in <t>)), so that headroom gets spent before it expires. The active account primary@example.com is nearly exhausted (weekly 98% used · 2% left, resets <time> (in <t>)).
  mode: floor, there IS somewhere good to go (best other account wk@example.com at 80% weekly left, comfortable mark 50%), so moving off early costs nothing and the >=20%-left floor governs as usual.
SNAP
)"
[ "$EX_USAGE_NORM" = "$EX_USAGE_WANT" ] \
  && ok "layout snapshot → the whole three-bucket dashboard renders exactly as designed" \
  || bad "layout snapshot → dashboard changed:
$(diff <(printf '%s\n' "$EX_USAGE_WANT") <(printf '%s\n' "$EX_USAGE_NORM") || true)"
# and the table switch-auto prints IS that same table, not a second implementation:
# every rendered row line of the dashboard appears verbatim in switch-auto's output
# norm_clock on BOTH sides: EX_USAGE and EX_OUT are two separate runs, and the
# "resets in 9h59m" countdown legitimately ticks between them, an exact compare
# would fail once a minute for no reason (the same normalisation scenario 31 does).
EX_ROWS_MISSING=0
EX_OUT_NORM="$(norm_clock <<<"$EX_OUT")"
while IFS= read -r line; do
  grep -qxF "$line" <<<"$EX_OUT_NORM" || EX_ROWS_MISSING=$((EX_ROWS_MISSING + 1))
done < <(grep -E '^(▶ ACTIVE|  ✓ |  ✗ |    (weekly|5h) )' <<<"$EX_USAGE_NORM")
[ "$EX_ROWS_MISSING" -eq 0 ] \
  && ok "one renderer → every dashboard row line appears verbatim in \`rota switch\`" \
  || bad "one renderer → $EX_ROWS_MISSING dashboard row lines missing from switch-auto"

# --- 39b. THE byte-identity guard, moved to `usage --json` ----------------------
# the dashboard parses this object; the human view above is free to be redesigned, the
# machine one is not. Field names, field ORDER and every value are pinned for a
# fixed fixture, with only the clock normalised, so an accidental rename, a
# dropped alias or a reordered key fails here rather than on the operator's phone.
#
# Scenarios 38 and 37 left DIFFERENT fixtures behind, and 39b/40/41 all run the
# script live, so the explains fixture, the same three accounts scenario 39
# snapshots, is re-established here rather than inherited from whatever ran last.
#
# 2026-08-27 GREW the pinned set by four paths (accounts.N.quota_data,
# accounts.N.quota_source, accounts.N.quota_measured_at and the top-level `peer`),
# which is the point: provenance is part of the published contract now, so it is
# pinned like everything else rather than the guard being loosened to let it in.
explains_fixture explainsjson
norm_json() {
  jq -S 'del(.generated_at, .generatedAt)
         | (.accounts[].weekly.resetsInSeconds) |= null
         | (.accounts[].session.resetsInSeconds) |= null
         | (.accounts[].weekly.resets_at, .accounts[].weekly.resetsAt,
            .accounts[].five_hour.resets_at, .accounts[].session.resetsAt,
            .recommendation.deadline_at) |= (if . == null then null else "<iso>" end)
         | .recommendation.reason |= (gsub("\\(in [^)]*\\)"; "(in <t>)")
                                      | gsub("[0-9]{2}:[0-9]{2} [A-Za-z0-9 ]+?(?=\\)|;|,)"; "<time>"))'
}
# the same pinned-empty billing file as scenario 39, and for the same reason:
# this fixture's run dir is a fresh one, so it needs its own copy
printf '{"accounts":{}}\n' > "$RUN/no-billing.json"
EX_JSON="$(FAKE_NEW_EMAIL=primary@example.com CLAUDE_BILLING_JSON="$RUN/no-billing.json" "$SCRIPT" usage --json 2>/dev/null | norm_json)"
# every published key path, in sorted order, the shape contract itself
# LC_ALL=C so the ordering is ASCII and identical on every box, a locale-sorted
# expectation would pass here and fail on a runner with a different LC_COLLATE.
EX_JSON_PATHS="$(jq -S -r 'paths | join(".")' <<<"$EX_JSON" | sed -E 's/\.[0-9]+/.N/g' | LC_ALL=C sort -u | tr '\n' ' ')"
# ⚠️ GREW BY NINE PATHS ACROSS TWO ADDITIVE CHANGES, then took its FIRST
# BREAKING ONE. Read the third entry before assuming the promise is still
# "nothing is ever renamed or removed": it is not, and this line is where a
# rename has to be argued for rather than slipped through.
#   2026-08-25  `seat.{status,ends,ended}` and `unmeasured`, because a consumer
#               that only ever saw `weekly.expired` could not tell "this account
#               is finished" from "I have not measured this", the same confusion
#               the human table had and the reason two live seats were written off
#   2026-08-27  `quota_data` / `quota_source` / `quota_measured_at` per row and the
#               top-level `peer` object, so a consumer can see WHOSE measurement a
#               number is and HOW OLD it is, not merely that one exists
#   2026-08-28  BREAKING, deliberately: `recommendation.weekly_resets_at` REMOVED,
#               `recommendation.deadline_at` + `recommendation.deadline_kind` added.
#               The old key had held min(weekly reset, seat end) since 2026-08-27,
#               so on a seat-end-bound pick it published an end date under a name
#               promising a reset. A fleet-wide grep found it read in exactly two
#               places, both this file, so keeping it would have preserved a lie
#               for an audience of zero. THIS ASSERTION IS WHY THAT WAS SAFE: the
#               rename could not land quietly, it reds here until the published
#               contract is edited by hand and the diff is reviewed.
EX_JSON_PATHS_WANT="accounts accounts.N accounts.N.active accounts.N.alias accounts.N.cached_at accounts.N.config_dir accounts.N.current accounts.N.data accounts.N.email accounts.N.five_hour accounts.N.five_hour.expired accounts.N.five_hour.fresh accounts.N.five_hour.remaining_pct accounts.N.five_hour.resets_at accounts.N.five_hour.used_pct accounts.N.label accounts.N.live accounts.N.loggedIn accounts.N.note accounts.N.quota_data accounts.N.quota_measured_at accounts.N.quota_source accounts.N.reason accounts.N.recommendable accounts.N.seat accounts.N.seat.ended accounts.N.seat.ends accounts.N.seat.status accounts.N.session accounts.N.session.expired accounts.N.session.fresh accounts.N.session.leftPct accounts.N.session.resetsAt accounts.N.session.resetsInSeconds accounts.N.session.usedPct accounts.N.stale accounts.N.stale_reason accounts.N.unmeasured accounts.N.weekly accounts.N.weekly.expired accounts.N.weekly.fresh accounts.N.weekly.kind accounts.N.weekly.leftPct accounts.N.weekly.remaining_pct accounts.N.weekly.resetsAt accounts.N.weekly.resetsInSeconds accounts.N.weekly.resets_at accounts.N.weekly.scope accounts.N.weekly.usedPct accounts.N.weekly.used_pct active active.auth_status active.auth_warning active.email active.fingerprint active.nested_config_warning active.source active.warning activeEmail floors floors.comfortable_pct floors.exhausted_pct floors.session_pct floors.weekly_pct peer recommendation recommendation.action recommendation.alias recommendation.best_alternative recommendation.best_alternative.email recommendation.best_alternative.weekly_left_pct recommendation.burn_down_hold recommendation.deadline_at recommendation.deadline_kind recommendation.email recommendation.from_cached_numbers recommendation.label recommendation.mode recommendation.mode_forced recommendation.reason recommendation.weekly_fresh "
[ "$EX_JSON_PATHS" = "$EX_JSON_PATHS_WANT" ] \
  && ok "json byte-identity → every published key path is exactly what the dashboard was promised" \
  || bad "json byte-identity → key paths drifted:
$(diff <(tr ' ' '\n' <<<"$EX_JSON_PATHS_WANT") <(tr ' ' '\n' <<<"$EX_JSON_PATHS") || true)"
# ...and the VALUES, not only the names
EX_JSON_VALS="$(jq -S -c '{a:[.accounts[]|{email,data,active,loggedIn,live,stale,recommendable,
                                            wk:[.weekly.used_pct,.weekly.remaining_pct,.weekly.usedPct,.weekly.leftPct,.weekly.fresh,.weekly.expired,.weekly.kind,.weekly.scope],
                                            se:[.five_hour.used_pct,.five_hour.remaining_pct,.session.usedPct,.session.leftPct,.session.fresh,.session.expired]}],
                           r:(.recommendation|{action,email,label,alias,deadline_kind,weekly_fresh,from_cached_numbers,mode,mode_forced,burn_down_hold,best_alternative}),
                           f:.floors, ae:.activeEmail}' <<<"$EX_JSON")"
EX_JSON_VALS_WANT='{"a":[{"active":true,"data":"live","email":"primary@example.com","live":true,"loggedIn":true,"recommendable":false,"se":[50,50,50,50,false,false],"stale":false,"wk":[98,2,98,2,false,false,null,null]},{"active":false,"data":"live","email":"wk@example.com","live":true,"loggedIn":true,"recommendable":true,"se":[0,100,0,100,false,false],"stale":false,"wk":[20,80,20,80,false,false,null,null]},{"active":false,"data":"live","email":"alpha@example.com","live":true,"loggedIn":true,"recommendable":false,"se":[10,90,10,90,false,false],"stale":false,"wk":[95,5,95,5,false,false,null,null]}],"ae":"primary@example.com","f":{"comfortable_pct":50,"exhausted_pct":2,"session_pct":10,"weekly_pct":20},"r":{"action":"switch","alias":"wk","best_alternative":{"email":"wk@example.com","weekly_left_pct":80},"burn_down_hold":false,"deadline_kind":"reset","email":"wk@example.com","from_cached_numbers":false,"label":"wk@example.com","mode":"floor","mode_forced":false,"weekly_fresh":false}}'
[ "$EX_JSON_VALS" = "$EX_JSON_VALS_WANT" ] \
  && ok "json byte-identity → every published VALUE is unchanged too, not just the names" \
  || bad "json byte-identity → values drifted:
  want: $EX_JSON_VALS_WANT
  got:  $EX_JSON_VALS"
# the human redesign must not have leaked a single escape byte into the JSON
! printf '%s' "$EX_JSON" | grep -q "$(printf '\033')" \
  && ok "json byte-identity → no ANSI escape ever reaches the JSON, even in a TTY-forced run" \
  || bad "json byte-identity → colour leaked into the JSON"

# --- 40. COLOUR: on when asked, off when asked, never by accident ---------------
# `--no-color` must not merely mute the colours, it must emit no escape bytes at
# all, the dashboard is piped, redirected and grepped, and a stray SGR sequence
# breaks every one of those. NO_COLOR is honoured for ANY value. And `--color`
# forces codes on even here, where stdout is a command substitution and the auto
# rule would (correctly) suppress them.
ESC="$(printf '\033')"
set +e
CLR_ON="$(FAKE_NEW_EMAIL=primary@example.com "$SCRIPT" usage --color 2>/dev/null)"
CLR_OFF="$(FAKE_NEW_EMAIL=primary@example.com "$SCRIPT" usage --no-color 2>/dev/null)"
CLR_AUTO="$(FAKE_NEW_EMAIL=primary@example.com "$SCRIPT" usage 2>/dev/null)"
CLR_NOENV="$(NO_COLOR=1 FAKE_NEW_EMAIL=primary@example.com "$SCRIPT" usage 2>/dev/null)"
CLR_NOENV_FORCED="$(NO_COLOR=1 FAKE_NEW_EMAIL=primary@example.com "$SCRIPT" usage --color 2>/dev/null)"
# shellcheck disable=SC1007  # NO_COLOR set to the EMPTY string is the case under test
CLR_NOENV_EMPTY="$(NO_COLOR= FAKE_NEW_EMAIL=primary@example.com "$SCRIPT" usage 2>/dev/null)"
CLR_JSON="$(FAKE_NEW_EMAIL=primary@example.com "$SCRIPT" usage --json --color 2>/dev/null)"
CLR_BAD="$(FAKE_NEW_EMAIL=primary@example.com "$SCRIPT" usage --nonsense 2>&1)"
CLR_BAD_RC=$?
set -e
grep -q "$ESC" <<<"$CLR_ON" \
  && ok "colour → --color forces SGR codes on even when stdout is not a TTY" \
  || bad "colour → --color forces colour on (got: $CLR_ON)"
! grep -q "$ESC" <<<"$CLR_OFF" \
  && ok "colour → --no-color emits ZERO escape bytes, not merely no colour" \
  || bad "colour → --no-color emits no escapes (got: $CLR_OFF)"
! grep -q "$ESC" <<<"$CLR_AUTO" \
  && ok "colour → auto is off when stdout is not a TTY (piped output stays greppable)" \
  || bad "colour → auto off when piped (got: $CLR_AUTO)"
! grep -q "$ESC" <<<"$CLR_NOENV" \
  && ok "colour → NO_COLOR=1 vetoes colour, so the environment can turn it off globally" \
  || bad "colour → NO_COLOR suppresses colour (got: $CLR_NOENV)"
! grep -q "$ESC" <<<"$CLR_NOENV_EMPTY" \
  && ok "colour → NO_COLOR with an EMPTY value counts too (no-color.org: any value)" \
  || bad "colour → NO_COLOR= suppresses colour (got: $CLR_NOENV_EMPTY)"
grep -q "$ESC" <<<"$CLR_NOENV_FORCED" \
  && ok "colour → an explicit --color still beats NO_COLOR: the flag is the last word" \
  || bad "colour → --color overrides NO_COLOR (got: $CLR_NOENV_FORCED)"
! grep -q "$ESC" <<<"$CLR_JSON" \
  && ok "colour → --json is never coloured, even with --color asked for explicitly" \
  || bad "colour → --json is never coloured (got: $CLR_JSON)"
# with colour off the LAYOUT still has to line up, same bytes as --no-color.
# norm_clock on every side: these are separate runs and the countdown ticks.
CLR_OFF_N="$(norm_clock <<<"$CLR_OFF")"
[ "$(norm_clock <<<"$CLR_AUTO")" = "$CLR_OFF_N" ] \
  && ok "colour → the uncoloured layout is identical whether it was auto-off or forced off" \
  || bad "colour → auto-off and --no-color agree"
# and the coloured run is the SAME REPORT once the escapes are stripped, so
# colour can never change what the dashboard says, including its column widths,
# which is the trap: padding a string that already carries zero-width escapes
# pads by the wrong amount and the columns collapse.
CLR_STRIPPED="$(sed -E "s/${ESC}\[[0-9;]*m//g" <<<"$CLR_ON" | norm_clock)"
[ "$CLR_STRIPPED" = "$CLR_OFF_N" ] \
  && ok "colour → stripping the SGR codes yields byte-for-byte the --no-color report (columns intact)" \
  || bad "colour → coloured and plain reports differ beyond the escapes:
$(diff <(printf '%s\n' "$CLR_OFF_N") <(printf '%s\n' "$CLR_STRIPPED") || true)"
[ "$CLR_BAD_RC" -ne 0 ] && grep -q 'usage \[--no-refresh\] \[--json\] \[--verbose\] \[--color|--no-color\]' <<<"$CLR_BAD" \
  && ok "colour → an unknown flag still fails with the real usage line, now listing the new flags" \
  || bad "colour → usage line lists the new flags (got $CLR_BAD_RC: $CLR_BAD)"

# --- 41. --verbose restores every relocated detail, and only under --verbose ----
# Nothing was deleted in the redesign; the dense extras MOVED. This is the pair of
# assertions that keeps that promise honest in both directions.
set +e
V_OUT="$(FAKE_NEW_EMAIL=primary@example.com "$SCRIPT" usage --verbose 2>/dev/null)"
V_SHORT="$(FAKE_NEW_EMAIL=primary@example.com "$SCRIPT" usage 2>/dev/null)"
V_RC=$?
set -e
[ "$V_RC" -eq 0 ] && ok "verbose → usage --verbose exits 0" || bad "verbose → exits 0 (got $V_RC: $V_OUT)"
[ "$(grep -c '^      slot    ' <<<"$V_OUT")" -eq 3 ] \
  && ok "verbose → the slot path comes back, one per configured account" \
  || bad "verbose → slot paths restored (got: $V_OUT)"
grep -q '^      note    same credential as the shared ~/.claude' <<<"$V_OUT" \
  && ok "verbose → the provenance note comes back" \
  || bad "verbose → note restored (got: $V_OUT)"
grep -q 'identity: ~/.claude.json oauthAccount' <<<"$V_OUT" \
  && ok "verbose → the identity/fingerprint line comes back" \
  || bad "verbose → identity line restored (got: $V_OUT)"
grep -q '^      resets  weekly resets ' <<<"$V_OUT" \
  && ok "verbose → the absolute reset stamps come back alongside the countdowns" \
  || bad "verbose → absolute resets restored (got: $V_OUT)"
[ "$(grep -c '^      ' <<<"$V_SHORT")" -eq 0 ] \
  && ok "verbose → and NONE of it appears in the default view, which stays scannable" \
  || bad "verbose → detail must stay behind the flag (got: $V_SHORT)"
# -v is the short form of the same flag
set +e
V_SHORTFLAG="$(FAKE_NEW_EMAIL=primary@example.com "$SCRIPT" usage -v 2>/dev/null)"
set -e
[ "$V_SHORTFLAG" != "$V_SHORT" ] && [ "$(grep -c '^      slot    ' <<<"$V_SHORTFLAG")" -eq 3 ] \
  && ok "verbose → -v is the same flag" \
  || bad "verbose → -v short form (got: $V_SHORTFLAG)"

# --- 42. the PANES block: the cross-link between the two meanings of "session" --
# The operator, 2026-08-07: "I think of it mostly as the account view when I
# think about which account to switch to, so I'm not sure if I should be using
# that or sessions." The root cause is that "session" names two unrelated things
# a tmux PANE and the 5-HOUR USAGE BLOCK (the statusline's "Session: 93%",
# which is what `rota usage` reports). The account view now ends with a PANE
# summary so the two are answered together, and it must:
#   - render in `accounts`/`usage` AND in `switch`, from ONE renderer
#   - NOT render under `switch --quiet` (the scripting path)
#   - be a SILENT no-op wherever the configured tmux session does not exist
#   - count claude panes only, split idle/working by the same "mid-work" rule
#     --restart-idle skips on
#   - count "may still be on the previous account" from the credential's change
#     time vs each claude process's start time, a HEURISTIC, worded as one
US=$'\037'
# `date -r <epoch>` renders exactly the `ps -o lstart=` shape pane_claude_started
# parses back, so the fixture can never drift from the format the real ps emits.
ps_row() { printf '%s     %s\n' "$(date -r "$1" '+%a %b %e %H:%M:%S %Y')" "$2"; }

panes_fixture() {  # panes_fixture <name>
  explains_fixture "$1"
  # The credential file is (re)written by explains_fixture just now, so "now" IS
  # its change time: a claude process from an hour ago predates it (may still be
  # on the previous account), one from an hour ahead does not.
  local now before after
  now="$(date +%s)"; before=$((now - 3600)); after=$((now + 3600))
  # %1 idle + predates the credential · %2 MID-WORK (esc to interrupt) + predates
  # it · %3 idle, EMPTY title, started after it · %4 WAITING ON BACKGROUND WORK,
  # the quiet kind of busy · %9 is a plain shell and must not be counted at all.
  { ps_row "$before" zsh; ps_row "$before" claude.exe; } > "$FAKE_STATE/ps-ttys001.txt"
  { ps_row "$before" claude.exe; }                     > "$FAKE_STATE/ps-ttys002.txt"
  { ps_row "$after"  claude.exe; }                     > "$FAKE_STATE/ps-ttys003.txt"
  { ps_row "$before" claude.exe; }                     > "$FAKE_STATE/ps-ttys004.txt"
  FAKE_TMUX_PANES="%1${US}/dev/ttys001${US}claude.exe${US}✳ rainbow rush game
%2${US}/dev/ttys002${US}claude.exe${US}⠂ liquity agm
%3${US}/dev/ttys003${US}claude.exe${US}
%4${US}/dev/ttys004${US}claude.exe${US}✳ ahv case edgar
%9${US}/dev/ttys009${US}zsh${US}shell"
  export FAKE_TMUX_PANES
  export FAKE_TMUX_WORKING="%2"
  export FAKE_TMUX_BACKGROUND="%4"
}
panes_teardown() { unset FAKE_TMUX_PANES FAKE_TMUX_WORKING FAKE_TMUX_BACKGROUND; }

panes_fixture panes
set +e
PB_ACC="$(FAKE_NEW_EMAIL=primary@example.com "$SCRIPT" accounts 2>/dev/null)"
PB_ACC_RC=$?
PB_USAGE="$(FAKE_NEW_EMAIL=primary@example.com "$SCRIPT" usage 2>/dev/null)"
PB_SW="$(FAKE_NEW_EMAIL=primary@example.com "$SCRIPT" switch-auto --dry-run 2>&1)"
PB_SWQ="$(FAKE_NEW_EMAIL=primary@example.com "$SCRIPT" switch-auto --dry-run --quiet 2>&1)"
PB_JSON="$(FAKE_NEW_EMAIL=primary@example.com "$SCRIPT" usage --json 2>/dev/null)"
set -e

[ "$PB_ACC_RC" -eq 0 ] && ok "panes → accounts still exits 0 with the block attached" \
  || bad "panes → accounts exits 0 (got $PB_ACC_RC: $PB_ACC)"
grep -q '^  PANES  4 total · 2 idle · 2 working$' <<<"$PB_ACC" \
  && ok "panes → accounts ends with the PANE summary, counting CLAUDE panes only (the zsh pane is not one)" \
  || bad "panes → accounts renders the summary (got: $PB_ACC)"
grep -q '^         3 may still be on the previous account (started before the last switch), restart to adopt$' <<<"$PB_ACC" \
  && ok "panes → the pre-switch count is the two panes whose claude process predates the credential" \
  || bad "panes → pre-switch heuristic count (got: $PB_ACC)"
grep -q '^         rota pane-converge --dry-run for detail$' <<<"$PB_ACC" \
  && ok "panes → and it points at the pane view, which is the whole point of the cross-link" \
  || bad "panes → points at the pane view (got: $PB_ACC)"
grep -q 'may still be' <<<"$PB_ACC" \
  && ok "panes → the wording stays a HEURISTIC ('may still be'), never an assertion of fact" \
  || bad "panes → hedged wording (got: $PB_ACC)"
# separate runs, so the countdowns tick between them, norm_clock on both sides,
# same convention as the colour comparison above
[ "$(norm_clock <<<"$PB_USAGE")" = "$(norm_clock <<<"$PB_ACC")" ] \
  && ok "panes → \`usage\` and \`accounts\` are the same command, block included" \
  || bad "panes → usage == accounts:
$(diff <(norm_clock <<<"$PB_ACC") <(norm_clock <<<"$PB_USAGE") || true)"
# the SAME block, from the SAME renderer, on the switch surface
grep -q '^  PANES  4 total · 2 idle · 2 working$' <<<"$PB_SW" \
  && ok "panes → switch prints the same block (one renderer, two surfaces)" \
  || bad "panes → switch renders the summary (got: $PB_SW)"
# ordering: on switch it lands AFTER the switch result, where "restart to adopt"
# is the next action rather than a footnote
[ "$(grep -n '^(dry-run, no switch performed)$' <<<"$PB_SW" | cut -d: -f1)" \
  -lt "$(grep -n '^  PANES ' <<<"$PB_SW" | cut -d: -f1)" ] \
  && ok "panes → on switch the block comes AFTER the switch result, not before it" \
  || bad "panes → block ordering on switch (got: $PB_SW)"
# --quiet is the scripting path: the pick + dry-run lines stay the FIRST two
# lines and the PANES block stays suppressed. The RESTART IDLE block is the one
# addition (2026-08-12, restart-by-default): it reports ACTIONS the switch now
# takes, so quiet keeps it, pass --new-only for a restart-free quiet switch.
! grep -q 'PANES' <<<"$PB_SWQ" \
  && grep -q '^optimizer pick: ' <<<"$(sed -n '1p' <<<"$PB_SWQ")" \
  && [ "$(sed -n '2p' <<<"$PB_SWQ")" = "(dry-run, no switch performed)" ] \
  && ok "panes → switch --quiet keeps the terse pick+dry lines first, with NO PANES block" \
  || bad "panes → --quiet structure (got: $PB_SWQ)"
grep -q 'RESTART IDLE' <<<"$PB_SWQ" \
  && ok "panes → --quiet still reports the default restart actions (they are actions, not decoration)" \
  || bad "panes → --quiet restart block (got: $PB_SWQ)"
# and the machine surface is untouched, the dashboard parses this
printf '%s' "$PB_JSON" | jq -e 'type=="object"' >/dev/null 2>&1 \
  && ! grep -q 'PANES' <<<"$PB_JSON" \
  && ok "panes → usage --json is still ONE object and carries no block" \
  || bad "panes → --json unchanged (got: $PB_JSON)"

# colour gating: the block obeys the same rule as everything else around it
set +e
PB_COL="$(FAKE_NEW_EMAIL=primary@example.com "$SCRIPT" accounts --color 2>/dev/null)"
PB_NOCOL="$(FAKE_NEW_EMAIL=primary@example.com "$SCRIPT" accounts --no-color 2>/dev/null)"
set -e
grep 'PANES' <<<"$PB_COL" | grep -q "$ESC" \
  && ok "panes → --color paints the block too" \
  || bad "panes → --color reaches the block (got: $(grep 'PANES' <<<"$PB_COL"))"
! grep 'PANES' <<<"$PB_NOCOL" | grep -q "$ESC" \
  && ok "panes → with colour off the block emits zero escape bytes (auto-off when piped is the default)" \
  || bad "panes → --no-color block has escapes"
! grep 'PANES' <<<"$PB_ACC" | grep -q "$ESC" \
  && ok "panes → auto mode leaves the block uncoloured when stdout is not a TTY" \
  || bad "panes → auto-off block has escapes"

# --- 43. restarting idle panes: the rules that were paid for once already ------
# THE DEFAULT since 2026-08-12 (it was opt-in as --restart-idle; that flag is
# now the accepted no-op spelling and --new-only is the opt-out). Every skip
# below is a scar:
#   - a MID-WORK pane restarted mid-tool-call loses that work
#   - `claude --continue` resumes the newest conversation FOR THE WORKING
#     DIRECTORY, and every pane is in ~/code, so it loads the WRONG one
#     (2026-08-06)
#   - `claude --resume ""` drops the pane to a bare shell (same day)
set +e
RI_DRY="$(FAKE_NEW_EMAIL=primary@example.com "$SCRIPT" switch-auto --dry-run --restart-idle 2>&1)"
RI_DRY_RC=$?
# the SAME plan without any flag: restarting is the default now
RI_DEF="$(FAKE_NEW_EMAIL=primary@example.com "$SCRIPT" switch-auto --dry-run 2>&1)"
RI_DEF_RC=$?
# and --new-only opts out entirely
RI_NEW="$(FAKE_NEW_EMAIL=primary@example.com "$SCRIPT" switch-auto --dry-run --new-only 2>&1)"
RI_NEW_RC=$?
set -e
# Since 2026-08-16 every restart line is PINNED: it carries an explicit
# CLAUDE_CONFIG_DIR=<the active account's pool dir>, so it can never again
# depend on the pane shell's PATH reaching the shim (the five dead "Please run
# /login" panes were bare lines resolved past it). The claim here is primary.
[ "$RI_DEF_RC" -eq 0 ] \
  && grep -q "%1 *would restart → CLAUDE_CONFIG_DIR=\"$RUN/.claude-pool/primary\" claude --resume \"rainbow rush game\"" <<<"$RI_DEF" \
  && ok "restart default → a BARE switch lists the restart plan (no flag needed any more), PINNED to the active pool dir" \
  || bad "restart default → bare switch restarts idle panes, pinned (got $RI_DEF_RC: $RI_DEF)"
grep -q 'RESTART IDLE' <<<"$RI_DEF" \
  && ok "restart default → the block announces itself on the bare switch too" \
  || bad "restart default → block header (got: $RI_DEF)"
[ "$RI_NEW_RC" -eq 0 ] && ! grep -q 'RESTART IDLE' <<<"$RI_NEW" && ! grep -q 'would restart' <<<"$RI_NEW" \
  && ok "--new-only → no restart block, no restart plan: only new launches adopt the account" \
  || bad "--new-only → must skip the restarts (got $RI_NEW_RC: $RI_NEW)"
[ "$RI_DRY_RC" -eq 0 ] \
  && ok "--restart-idle → still accepted (the explicit spelling of the default)" \
  || bad "--restart-idle → alias accepted (got $RI_DRY_RC: $RI_DRY)"
[ "$RI_DRY_RC" -eq 0 ] && ok "restart-idle → --dry-run exits 0" \
  || bad "restart-idle → --dry-run exits 0 (got $RI_DRY_RC: $RI_DRY)"
grep -q "%1 *would restart → CLAUDE_CONFIG_DIR=\"$RUN/.claude-pool/primary\" claude --resume \"rainbow rush game\"" <<<"$RI_DRY" \
  && ok "restart-idle → lists the idle pane, glyph stripped, line pinned to the active pool dir (2026-08-16)" \
  || bad "restart-idle → lists the idle pane (got: $RI_DRY)"
grep -qE '%2 +skipped, mid-work' <<<"$RI_DRY" \
  && ok "restart-idle → EXCLUDES the mid-work pane and says why (the rule that protects work in flight)" \
  || bad "restart-idle → excludes the working pane (got: $RI_DRY)"
grep -qE '%3 +skipped, empty pane title' <<<"$RI_DRY" \
  && ok "restart-idle → a pane with an empty title is skipped and REPORTED, never resumed blind" \
  || bad "restart-idle → empty title skipped (got: $RI_DRY)"
# the QUIET kind of busy: no "esc to interrupt" on screen, but /quit-ing it kills
# the background subagents just as dead, so it counts as working and is skipped
grep -qE '%4 +skipped, mid-work' <<<"$RI_DRY" \
  && ok "restart-idle → a pane WAITING ON BACKGROUND WORK is mid-work too, and is skipped" \
  || bad "restart-idle → background-work pane skipped (got: $RI_DRY)"
! grep -q 'resume ""' <<<"$RI_DRY" \
  && ok "restart-idle → never proposes \`claude --resume \"\"\` (which drops a pane to a bare shell)" \
  || bad "restart-idle → proposed an empty --resume (got: $RI_DRY)"
! grep -q -- '--continue' <<<"$RI_DRY" \
  && ok "restart-idle → never proposes \`claude --continue\` (it resumes by CWD, so it loads the wrong session)" \
  || bad "restart-idle → proposed --continue (got: $RI_DRY)"
# a dry run must not touch tmux beyond READING it
RI_DRY_LOG="$ROOT/tmux-dry.log"
set +e
TMUX_LOG="$RI_DRY_LOG" FAKE_NEW_EMAIL=primary@example.com \
  "$SCRIPT" switch-auto --dry-run --restart-idle >/dev/null 2>&1
set -e
! grep -q 'send-keys' "$RI_DRY_LOG" \
  && ok "restart-idle → --dry-run sends not one keystroke (no send-keys reached tmux at all)" \
  || bad "restart-idle → --dry-run stayed read-only ($(grep 'send-keys' "$RI_DRY_LOG"))"

# the real thing: switch, then restart the panes that are safe to restart
panes_fixture restartlive
RI_LOG="$ROOT/tmux-live.log"
set +e
RI_LIVE="$(TMUX_LOG="$RI_LOG" FAKE_NEW_EMAIL=wk@example.com FAKE_LAG=0 \
  "$SCRIPT" switch-auto --restart-idle 2>&1)"
RI_LIVE_RC=$?
set -e
[ "$RI_LIVE_RC" -eq 0 ] && ok "restart-idle → a real switch + restart exits 0" \
  || bad "restart-idle → live run exits 0 (got $RI_LIVE_RC: $RI_LIVE)"
grep -q 'tmux send-keys -t %1 /quit Enter' "$RI_LOG" \
  && ok "restart-idle → the idle pane is asked to /quit" \
  || bad "restart-idle → /quit sent to %1 ($(cat "$RI_LOG"))"
# the switch just moved the claim to wk, so the pin resolves AFTER the move:
# the restarted pane must land on the account just switched TO, explicitly
grep -q "tmux send-keys -t %1 CLAUDE_CONFIG_DIR=\"$RUN/.claude-pool/wk\" claude --resume \"rainbow rush game\" Enter" "$RI_LOG" \
  && ok "restart-idle → then resumed BY NAME, pinned to the account just switched to (not PATH-dependent)" \
  || bad "restart-idle → pinned resume-by-name sent to %1 ($(cat "$RI_LOG"))"
! grep -q -- '--continue' "$RI_LOG" \
  && ok "restart-idle → \`claude --continue\` is never issued, on any pane" \
  || bad "restart-idle → issued --continue ($(grep -- '--continue' "$RI_LOG"))"
! grep -qE 'send-keys -t (%2|%3|%4)' "$RI_LOG" \
  && ok "restart-idle → the two mid-work panes and the untitled pane are never sent anything" \
  || bad "restart-idle → touched a pane it must not ($(grep -E 'send-keys -t (%2|%3|%4)' "$RI_LOG"))"
grep -qE "%1 +restarted → CLAUDE_CONFIG_DIR=\"$RUN/.claude-pool/wk\" claude --resume \"rainbow rush game\"" <<<"$RI_LIVE" \
  && ok "restart-idle → every pane gets a per-pane result line, showing the pinned line actually sent" \
  || bad "restart-idle → per-pane result lines (got: $RI_LIVE)"
grep -q 'idle panes restarted (default; --new-only to skip)' <<<"$RI_LIVE" \
  && ok "restart-idle → the block header NAMES the default and its opt-out" \
  || bad "restart-idle → header names the default (got: $RI_LIVE)"

# a BARE switch-all (no flag at all) restarts idle panes too, the default is
# the leaf verb's, not something switch-auto layers on top
panes_fixture swbare
SWB_LOG="$ROOT/tmux-swbare.log"
set +e
SWB_OUT="$(TMUX_LOG="$SWB_LOG" FAKE_LAG=0 FAKE_KEYCHAIN=none \
  "$SCRIPT" switch-all wk@example.com 2>&1)"
SWB_RC=$?
set -e
[ "$SWB_RC" -eq 0 ] && ok "bare switch-all → exits 0" \
  || bad "bare switch-all → exit 0 (got $SWB_RC: $SWB_OUT)"
grep -q 'tmux send-keys -t %1 /quit Enter' "$SWB_LOG" \
  && grep -q "tmux send-keys -t %1 CLAUDE_CONFIG_DIR=\"$RUN/.claude-pool/wk\" claude --resume \"rainbow rush game\" Enter" "$SWB_LOG" \
  && ok "bare switch-all → restarts the idle pane BY DEFAULT (/quit + resume-by-name, pinned to the new claim)" \
  || bad "bare switch-all → default pinned restart ($(cat "$SWB_LOG"))"
! grep -qE 'send-keys -t (%2|%3|%4)' "$SWB_LOG" \
  && ok "bare switch-all → the mid-work and untitled panes still are not touched" \
  || bad "bare switch-all → touched a protected pane ($(cat "$SWB_LOG"))"
grep -q 'idle panes (if any) are restarted onto it below (default; --new-only to skip)' <<<"$SWB_OUT" \
  && ok "bare switch-all → the success line says the restarts are coming, and how to skip them" \
  || bad "bare switch-all → success line names the default (got: $SWB_OUT)"

# --new-only on a LIVE switch: the pointer moves, not one keystroke is sent
panes_fixture swnewonly
SWN_LOG="$ROOT/tmux-swnewonly.log"
set +e
SWN_OUT="$(TMUX_LOG="$SWN_LOG" FAKE_LAG=0 FAKE_KEYCHAIN=none \
  "$SCRIPT" switch-all wk@example.com --new-only 2>&1)"
SWN_RC=$?
set -e
[ "$SWN_RC" -eq 0 ] && [ "$(jq -r '.oauthAccount.emailAddress' "$RUN/.claude.json")" = "wk@example.com" ] \
  && ok "--new-only → the switch itself still lands (claim moved)" \
  || bad "--new-only → switch lands (got $SWN_RC: $SWN_OUT)"
! grep -q 'send-keys' "$SWN_LOG" \
  && ok "--new-only → not one keystroke sent to any pane" \
  || bad "--new-only → sent keystrokes ($(grep 'send-keys' "$SWN_LOG"))"
grep -q -- '--new-only: no panes restarted' <<<"$SWN_OUT" \
  && ok "--new-only → the success line says the panes were deliberately left alone" \
  || bad "--new-only → success line (got: $SWN_OUT)"

# the pane the command itself runs in is never restarted, that would kill the switch
panes_fixture restartself
set +e
RI_SELF="$(TMUX_PANE=%1 FAKE_NEW_EMAIL=primary@example.com \
  "$SCRIPT" switch-auto --dry-run --restart-idle 2>&1)"
set -e
grep -qE '%1 +skipped, this is the pane running the switch' <<<"$RI_SELF" \
  && ok "restart-idle → never restarts the pane it is running in" \
  || bad "restart-idle → self-pane skipped (got: $RI_SELF)"

# --- 44. with no configured session the whole thing is a SILENT no-op -----------
# ROTA_TMUX_SESSION has no default: pane convergence is opt-in. Two shapes, both
# silent by default. (a) NOTHING names a session (the laptop that never opted
# in): the promise is not "prints n/a", it is that not one byte is added on any
# surface, and that tmux is never even invoked. (b) a session IS named but the
# server does not hold it: the same silence, and an EXPLICIT --restart-idle
# still explains which of the three tmux failures happened.
panes_teardown
NS_LOG="$ROOT/tmux-nosession.log"
: > "$NS_LOG"
set +e
NS_ACC="$(ROTA_TMUX_SESSION= TMUX_LOG="$NS_LOG" FAKE_NEW_EMAIL=primary@example.com "$SCRIPT" accounts 2>/dev/null)"
NS_ACC_RC=$?
NS_SW="$(ROTA_TMUX_SESSION= TMUX_LOG="$NS_LOG" FAKE_NEW_EMAIL=primary@example.com "$SCRIPT" switch-auto --dry-run 2>&1)"
NS_RI="$(ROTA_TMUX_SESSION= TMUX_LOG="$NS_LOG" FAKE_NEW_EMAIL=primary@example.com "$SCRIPT" switch-auto --dry-run --restart-idle 2>&1)"
NS_PC="$(ROTA_TMUX_SESSION= TMUX_LOG="$NS_LOG" "$SCRIPT" pane-converge 2>&1)"
NS_PC_RC=$?
set -e
[ "$NS_ACC_RC" -eq 0 ] && ok "no session configured → accounts still exits 0" \
  || bad "no session configured → accounts exits 0 (got $NS_ACC_RC: $NS_ACC)"
! grep -q 'PANES' <<<"$NS_ACC" \
  && ok "no session configured → accounts prints NO block at all (not an 'n/a' row)" \
  || bad "no session configured → block must be silent (got: $NS_ACC)"
! grep -q 'PANES' <<<"$NS_SW" \
  && ok "no session configured → switch prints no block either" \
  || bad "no session configured → switch block must be silent (got: $NS_SW)"
! grep -q 'nothing to restart' <<<"$NS_SW" && ! grep -q 'RESTART IDLE' <<<"$NS_SW" \
  && ok "no session configured → the default restart adds not one byte (no nag on laptops)" \
  || bad "no session configured → default restart must be silent (got: $NS_SW)"
grep -q 'no tmux session configured' <<<"$NS_RI" && grep -q 'ROTA_TMUX_SESSION' <<<"$NS_RI" \
  && ok "no session configured → an EXPLICIT --restart-idle says the feature is unset and names the variable that enables it" \
  || bad "no session configured → --restart-idle explains itself (got: $NS_RI)"
[ ! -s "$NS_LOG" ] \
  && ok "no session configured → tmux is never invoked at all (the stub's call log stays empty)" \
  || bad "no session configured → tmux was invoked ($(cat "$NS_LOG"))"
[ "$NS_PC_RC" -eq 0 ] && grep -q 'no tmux session configured' <<<"$NS_PC" \
  && grep -q '^pane-converge: restarted=0 busy=0 divergent=0$' <<<"$NS_PC" \
  && ok "no session configured → pane-converge is one explanatory line + the zeroed summary, exit 0" \
  || bad "no session configured → pane-converge no-op (got $NS_PC_RC: $NS_PC)"

# (b) a configured name the server does not hold
set +e
NB_ACC="$(FAKE_NEW_EMAIL=primary@example.com "$SCRIPT" accounts 2>/dev/null)"
NB_ACC_RC=$?
NB_SW="$(FAKE_NEW_EMAIL=primary@example.com "$SCRIPT" switch-auto --dry-run 2>&1)"
NB_RI="$(FAKE_NEW_EMAIL=primary@example.com "$SCRIPT" switch-auto --dry-run --restart-idle 2>&1)"
set -e
[ "$NB_ACC_RC" -eq 0 ] && ok "missing session → accounts still exits 0" \
  || bad "missing session → accounts exits 0 (got $NB_ACC_RC: $NB_ACC)"
! grep -q 'PANES' <<<"$NB_ACC" \
  && ok "missing session → accounts prints NO block at all (not an 'n/a' row)" \
  || bad "missing session → block must be silent (got: $NB_ACC)"
! grep -q 'PANES' <<<"$NB_SW" \
  && ok "missing session → switch prints no block either" \
  || bad "missing session → switch block must be silent (got: $NB_SW)"
# the DEFAULT restart stays silent when there is nothing to even look at, a
# laptop switch must not nag about a session that was never there
! grep -q 'nothing to restart' <<<"$NB_SW" && ! grep -q 'RESTART IDLE' <<<"$NB_SW" \
  && ok "missing session → the default restart adds not one byte (no nag on laptops)" \
  || bad "missing session → default restart must be silent (got: $NB_SW)"
# keeper polish 2026-08-12: the refusal now DISTINGUISHES binary-not-found /
# server-unreachable / no-such-session. This fixture's stub tmux answers `ls`
# (server reachable) but holds no session, so the third wording is the one.
grep -q "no tmux session named 'rota-test-panes'" <<<"$NB_RI" \
  && ok "missing session → an EXPLICIT --restart-idle says so instead of silently doing nothing" \
  || bad "missing session → --restart-idle explains itself (got: $NB_RI)"

# --- 45. the pre-switch heuristic counts from the credential's CHANGE time -----
# switch-all writes the new credential with `cp -p`, which PRESERVES the source
# pool copy's mtime, so an mtime-only rule would report ZERO stale panes seconds
# after a switch, which is exactly when the answer matters most. cred_changed_at
# takes the later of mtime and ctime; this pins that, by back-dating the mtime an
# hour while every pane's claude process is only ten minutes old.
panes_fixture heuristic
NOW="$(date +%s)"
for t in 001 002 003 004; do ps_row "$((NOW - 600))" claude.exe > "$FAKE_STATE/ps-ttys$t.txt"; done
touch -t "$(date -r "$((NOW - 3600))" '+%Y%m%d%H%M.%S')" "$HOME/.claude/.credentials.json"
set +e
HB_OUT="$(FAKE_NEW_EMAIL=primary@example.com "$SCRIPT" accounts 2>/dev/null)"
set -e
grep -q '^         4 may still be on the previous account' <<<"$HB_OUT" \
  && ok "heuristic → a cp -p-preserved mtime cannot hide panes: ctime still says the file just changed" \
  || bad "heuristic → counts from the credential's CHANGE time (got: $HB_OUT)"
# and the other direction: every claude process newer than the credential = no line
panes_fixture heuristicfresh
NOW="$(date +%s)"
for t in 001 002 003 004; do ps_row "$((NOW + 3600))" claude.exe > "$FAKE_STATE/ps-ttys$t.txt"; done
set +e
HF_OUT="$(FAKE_NEW_EMAIL=primary@example.com "$SCRIPT" accounts 2>/dev/null)"
set -e
grep -q '^  PANES  4 total · 2 idle · 2 working$' <<<"$HF_OUT" \
  && ! grep -q 'may still be' <<<"$HF_OUT" \
  && ok "heuristic → when every claude process postdates the credential the hint is omitted entirely" \
  || bad "heuristic → no false 'may still be' line (got: $HF_OUT)"
panes_teardown

# --- 45b. pane-converge: busy panes catch up with the switch once idle ----------
# The requirement (2026-08-12): after a switch EVERY pane ends up on the active
# account, idle ones immediately (the switch's default restart), mid-work ones
# as soon as they finish. pane-converge is the retry half: it walks each claude
# pane's pinned CLAUDE_CONFIG_DIR (pool_ps), compares the dir's identity to the
# claim, and restarts only the DIVERGENT IDLE panes, through the same /quit +
# resume-by-name machinery, with the same skips. Non-pool pins are never
# touched, and never counted.
#
# UNPINNED panes count as divergent since 2026-08-16. They used to be skipped
# as "identity unknowable", which made converge blind to the day's actual
# failure mode (five boot-created panes whose PATH bypassed the shim ran
# unpinned against the credential-less shared ~/.claude, dead on "Please run
# /login", and converge reported nothing to do, forever). Under pool v2 an
# unpinned claude is on NO account, so idle ones now go through the same
# restart machinery, and every restart line is PINNED (explicit
# CLAUDE_CONFIG_DIR=<active pool dir>), never PATH-dependent again.
explains_fixture converge
FAKE_TMUX_PANES="%1${US}/dev/ttys001${US}claude.exe${US}✳ rainbow rush game
%2${US}/dev/ttys002${US}claude.exe${US}⠂ liquity agm
%3${US}/dev/ttys003${US}claude.exe${US}
%4${US}/dev/ttys004${US}claude.exe${US}✳ ahv case edgar
%5${US}/dev/ttys005${US}claude.exe${US}✳ unpinned legacy
%6${US}/dev/ttys006${US}claude.exe${US}✳ scratch pin"
export FAKE_TMUX_PANES
export FAKE_TMUX_WORKING="%2"
# pid → pinned dir, per tty (the TT column is ps's short "s001" spelling):
#   %1 idle, pinned wk        → DIVERGENT, restartable
#   %2 mid-work, pinned alpha → DIVERGENT, busy, reported, never touched
#   %3 idle, EMPTY title, wk  → DIVERGENT, but nothing to resume, left alone
#   %4 idle, pinned primary   → on the claim already, not divergent
#   %5 idle, NO pin           → DIVERGENT since 2026-08-16 (on no account at
#                               all under v2, the broken-forever shape),
#                               restartable
#   %6 idle, non-pool pin     → scratch/login capture, never touched or counted
cat > "$FAKE_STATE/pool-ps.txt" <<POOLPS
PID TT STAT TIME COMMAND
101 s001 S+ 0:00 /usr/local/bin/claude CLAUDE_CONFIG_DIR=$RUN/.claude-pool/wk HOME=$RUN
102 s002 S+ 0:00 /usr/local/bin/claude CLAUDE_CONFIG_DIR=$RUN/.claude-pool/alpha HOME=$RUN
103 s003 S+ 0:00 /usr/local/bin/claude CLAUDE_CONFIG_DIR=$RUN/.claude-pool/wk
104 s004 S+ 0:00 /usr/local/bin/claude CLAUDE_CONFIG_DIR=$RUN/.claude-pool/primary
105 s005 S+ 0:00 /usr/local/bin/claude HOME=$RUN
106 s006 S+ 0:00 /usr/local/bin/claude CLAUDE_CONFIG_DIR=$RUN/scratch-dir
POOLPS

PC_DRY_LOG="$ROOT/tmux-pcdry.log"
set +e
PC_DRY="$(TMUX_LOG="$PC_DRY_LOG" "$SCRIPT" pane-converge --dry-run 2>&1)"
PC_DRY_RC=$?
set -e
[ "$PC_DRY_RC" -eq 0 ] && ok "pane-converge → --dry-run exits 0" \
  || bad "pane-converge → --dry-run exits 0 (got $PC_DRY_RC: $PC_DRY)"
grep -q "%1 on wk@example.com → would restart (CLAUDE_CONFIG_DIR=\"$RUN/.claude-pool/primary\" claude --resume \"rainbow rush game\")" <<<"$PC_DRY" \
  && ok "pane-converge → names the divergent idle pane, its account, and the PINNED resume it would send" \
  || bad "pane-converge → divergent idle pane listed (got: $PC_DRY)"
grep -q '%2 busy on alpha@example.com, mid-work is never restarted; converges when idle' <<<"$PC_DRY" \
  && ok "pane-converge → a mid-work divergent pane is reported busy, never restarted" \
  || bad "pane-converge → busy pane reported (got: $PC_DRY)"
grep -q '%3 still on wk@example.com, empty pane title' <<<"$PC_DRY" \
  && ok "pane-converge → an untitled divergent pane is reported, never resumed blind" \
  || bad "pane-converge → untitled pane reported (got: $PC_DRY)"
# the 2026-08-16 flip: the UNPINNED pane is now DIVERGENT (it can be on no
# account at all), so it earns a would-restart line like any stale pin
grep -q "%5 on unpinned, no CLAUDE_CONFIG_DIR → would restart (CLAUDE_CONFIG_DIR=\"$RUN/.claude-pool/primary\" claude --resume \"unpinned legacy\")" <<<"$PC_DRY" \
  && ok "pane-converge → an UNPINNED idle pane counts as divergent and gets the pinned restart (2026-08-16)" \
  || bad "pane-converge → unpinned pane must be divergent (got: $PC_DRY)"
! grep -qE '%(4|6) ' <<<"$PC_DRY" \
  && ok "pane-converge → on-claim and non-pool panes earn no line at all" \
  || bad "pane-converge → must ignore %4/%6 (got: $PC_DRY)"
grep -q '^pane-converge: restarted=2 busy=2 divergent=4 claim=primary@example.com (dry-run)$' <<<"$PC_DRY" \
  && ok "pane-converge → the machine-readable summary counts exactly the divergent panes (unpinned included)" \
  || bad "pane-converge → summary line (got: $PC_DRY)"
! grep -q 'send-keys' "$PC_DRY_LOG" \
  && ok "pane-converge → --dry-run sends not one keystroke" \
  || bad "pane-converge → dry run stayed read-only ($(grep 'send-keys' "$PC_DRY_LOG"))"

PC_LOG="$ROOT/tmux-pclive.log"
set +e
PC_LIVE="$(TMUX_LOG="$PC_LOG" "$SCRIPT" pane-converge 2>&1)"
PC_LIVE_RC=$?
set -e
[ "$PC_LIVE_RC" -eq 0 ] && ok "pane-converge → a live run exits 0 (a busy pane is a wait, not an error)" \
  || bad "pane-converge → live exits 0 (got $PC_LIVE_RC: $PC_LIVE)"
grep -q 'tmux send-keys -t %1 /quit Enter' "$PC_LOG" \
  && grep -q "tmux send-keys -t %1 CLAUDE_CONFIG_DIR=\"$RUN/.claude-pool/primary\" claude --resume \"rainbow rush game\" Enter" "$PC_LOG" \
  && ok "pane-converge → the divergent idle pane is restarted through the same /quit + PINNED resume-by-name" \
  || bad "pane-converge → pinned restart sent to %1 ($(cat "$PC_LOG"))"
grep -q "tmux send-keys -t %5 CLAUDE_CONFIG_DIR=\"$RUN/.claude-pool/primary\" claude --resume \"unpinned legacy\" Enter" "$PC_LOG" \
  && ok "pane-converge → the UNPINNED idle pane is restarted too, today's broken-forever shape now heals" \
  || bad "pane-converge → unpinned pane restarted ($(cat "$PC_LOG"))"
! grep -qE 'send-keys -t (%2|%3|%4|%6)' "$PC_LOG" \
  && ok "pane-converge → every other pane is left untouched" \
  || bad "pane-converge → touched a protected pane ($(grep -E 'send-keys' "$PC_LOG"))"
grep -q "%1 restarted onto primary@example.com (was wk@example.com) → CLAUDE_CONFIG_DIR=\"$RUN/.claude-pool/primary\" claude --resume \"rainbow rush game\"" <<<"$PC_LIVE" \
  && ok "pane-converge → the restart line names both accounts (onto the claim, was the stale pin)" \
  || bad "pane-converge → restart line (got: $PC_LIVE)"
grep -q '%5 restarted onto primary@example.com (was unpinned, no CLAUDE_CONFIG_DIR) →' <<<"$PC_LIVE" \
  && ok "pane-converge → the unpinned pane's line names what it was (no pin), not a fake account" \
  || bad "pane-converge → unpinned restart line (got: $PC_LIVE)"
grep -q '^pane-converge: restarted=2 busy=2 divergent=4 claim=primary@example.com$' <<<"$PC_LIVE" \
  && ok "pane-converge → live summary matches the dry-run plan" \
  || bad "pane-converge → live summary (got: $PC_LIVE)"

# nothing to do → says so, with the zeroed summary a keeper can still parse
panes_teardown
rm -f "$FAKE_STATE/pool-ps.txt"
set +e
PC_NONE="$("$SCRIPT" pane-converge 2>&1)"
PC_NONE_RC=$?
set -e
[ "$PC_NONE_RC" -eq 0 ] && grep -q 'nothing to converge' <<<"$PC_NONE" \
  && grep -q '^pane-converge: restarted=0 busy=0 divergent=0$' <<<"$PC_NONE" \
  && ok "pane-converge → no panes: explains itself and still emits the parseable summary" \
  || bad "pane-converge → empty case (got $PC_NONE_RC: $PC_NONE)"

# --- 45c. the husk refusal: never trade a stale pane for a dead one (2026-08-16)
# pane_restart_one now resolves the ACTIVE account before touching a pane. When
# that account's pool credential is a HUSK (or nothing resolvable holds a
# complete credential at all), the restarted claude could only come up on
# "Please run /login", strictly worse than the stale-but-alive pane it
# replaces. So the restart REFUSES (new rc 4) BEFORE even sending /quit, and
# every caller says so loudly, naming the one login command that fixes it.
explains_fixture huskpin
FAKE_TMUX_PANES="%1${US}/dev/ttys001${US}claude.exe${US}✳ rainbow rush game"
export FAKE_TMUX_PANES
cat > "$FAKE_STATE/pool-ps.txt" <<POOLPS
PID TT STAT TIME COMMAND
101 s001 S+ 0:00 /usr/local/bin/claude CLAUDE_CONFIG_DIR=$RUN/.claude-pool/wk HOME=$RUN
POOLPS

# the healthy half first, as its own named assertion: with the active
# (primary) credential COMPLETE, the plan pins the line to its pool dir
set +e
HPOK="$("$SCRIPT" pane-converge --dry-run 2>&1)"
set -e
grep -q "would restart (CLAUDE_CONFIG_DIR=\"$RUN/.claude-pool/primary\" claude --resume \"rainbow rush game\")" <<<"$HPOK" \
  && ok "pinned restart → a complete active credential puts CLAUDE_CONFIG_DIR=<its pool dir> on the sent line" \
  || bad "pinned restart → pin present (got: $HPOK)"

# now gut the ACTIVE account's pool credential to the husk shape (refreshToken
# key with no value, expiresAt gone, the file the CLI leaves after a rejected
# refresh) and watch every restart path refuse rather than relaunch onto it
printf '{"claudeAiOauth":{"accessToken":"","refreshToken":"","refreshTokenExpiresAt":1}}' \
  > "$RUN/.claude-pool/primary/.credentials.json"
HP_LOG="$ROOT/tmux-huskpin.log"
set +e
HP_DRY="$(TMUX_LOG="$HP_LOG" "$SCRIPT" pane-converge --dry-run 2>&1)"
HP_DRY_RC=$?
HP_LIVE="$(TMUX_LOG="$HP_LOG" "$SCRIPT" pane-converge 2>&1)"
HP_LIVE_RC=$?
HP_RI="$(FAKE_NEW_EMAIL=wk@example.com "$SCRIPT" switch-auto --dry-run --restart-idle 2>&1)"
set -e
[ "$HP_DRY_RC" -eq 0 ] && [ "$HP_LIVE_RC" -eq 0 ] \
  && ok "husk refusal → refusing is exit 0 (a guarded pane is a wait, not an error)" \
  || bad "husk refusal → exit codes (dry=$HP_DRY_RC live=$HP_LIVE_RC)"
grep -q '%1 on wk@example.com → would NOT restart, active account credential is a husk' <<<"$HP_DRY" \
  && ok "husk refusal → the dry run says WOULD NOT, per pane, with the reason" \
  || bad "husk refusal → dry-run refusal line (got: $HP_DRY)"
grep -q '^pane-converge: restarted=0 busy=1 divergent=1 claim=primary@example.com (dry-run)$' <<<"$HP_DRY" \
  && ok "husk refusal → the refused pane still counts divergent (it IS), just not restarted" \
  || bad "husk refusal → dry summary (got: $HP_DRY)"
grep -q 'restart would land on a dead slot' <<<"$HP_LIVE" \
  && grep -q 'login needed: CLAUDE_CONFIG_DIR=~/.claude-pool/primary claude' <<<"$HP_LIVE" \
  && ok "husk refusal → the live run names the dead slot AND the exact login command that fixes it" \
  || bad "husk refusal → live refusal line (got: $HP_LIVE)"
! grep -q 'send-keys' "$HP_LOG" \
  && ok "husk refusal → not one keystroke sent, the pane is never even /quit (better stale than dead)" \
  || bad "husk refusal → pane was touched ($(grep 'send-keys' "$HP_LOG"))"
grep -q '^pane-converge: restarted=0 busy=1 divergent=1 claim=primary@example.com$' <<<"$HP_LIVE" \
  && ok "husk refusal → live summary matches the plan" \
  || bad "husk refusal → live summary (got: $HP_LIVE)"
grep -q 'would skip, active account credential is a husk' <<<"$HP_RI" \
  && ok "husk refusal → restart-idle (the switch's default restart) refuses with the same loud reason" \
  || bad "husk refusal → restart-idle refusal (got: $HP_RI)"
panes_teardown
rm -f "$FAKE_STATE/pool-ps.txt"

# --- 45d. the lying-map refusal: an explicit pin must verify identity (2026-08-16)
# pane_pin_resolve used to trust slot_for_email's LABEL match outright, but
# the accounts file is an auto-reconciled cache that can lie (the 2026-08-11
# alpha/work swap), and the restart line built from it is an EXPLICIT
# CLAUDE_CONFIG_DIR pin that bypasses the shim's identity layer entirely: a
# lying row would re-pin every restarted pane onto the wrong account,
# silently billing it. The dir's own .claude.json is its TRUE identity, so a
# mismatch now REFUSES (zero keystrokes), names both accounts and the fix,
# and flags needs-reconcile for the keeper. Same refusal when the map sends
# the claim AT the shared ~/.claude itself, pinning there is the
# nested-config trap, and its config_email answer IS the claim (~/.claude.json),
# so only an explicit guard can catch it.
explains_fixture lyingmap
FAKE_TMUX_PANES="%1${US}/dev/ttys001${US}claude.exe${US}✳ rainbow rush game"
export FAKE_TMUX_PANES
cat > "$FAKE_STATE/pool-ps.txt" <<POOLPS
PID TT STAT TIME COMMAND
101 s001 S+ 0:00 /usr/local/bin/claude CLAUDE_CONFIG_DIR=$RUN/.claude-pool/wk HOME=$RUN
POOLPS
# the map's primary row still points at the primary dir, but that dir now
# ACTUALLY holds a different account (a crossed /login), with a perfectly
# COMPLETE credential: only the identity check can refuse this, the husk
# check would wave it through. A THIRD identity (not wk) deliberately, so the
# optimizer's duplicate-row handling stays out of the switch-auto assertion.
printf '{"oauthAccount":{"emailAddress":"intruder@example.com"}}' > "$RUN/.claude-pool/primary/.claude.json"
LM_LOG="$ROOT/tmux-lyingmap.log"
set +e
LM_DRY="$(TMUX_LOG="$LM_LOG" "$SCRIPT" pane-converge --dry-run 2>&1)"
LM_DRY_RC=$?
LM_LIVE="$(TMUX_LOG="$LM_LOG" "$SCRIPT" pane-converge 2>&1)"
LM_LIVE_RC=$?
LM_RI="$(FAKE_NEW_EMAIL=wk@example.com "$SCRIPT" switch-auto --dry-run --restart-idle 2>&1)"
set -e
[ "$LM_DRY_RC" -eq 0 ] && [ "$LM_LIVE_RC" -eq 0 ] \
  && ok "lying map → refusing is exit 0 (a guarded pane is a wait, not an error)" \
  || bad "lying map → exit codes (dry=$LM_DRY_RC live=$LM_LIVE_RC)"
grep -q 'would NOT restart, accounts map says primary@example.com but ~/.claude-pool/primary actually holds intruder@example.com' <<<"$LM_DRY" \
  && ok "lying map → the refusal names BOTH accounts: the label's claim and the dir's real identity" \
  || bad "lying map → dry-run refusal line (got: $LM_DRY)"
grep -q 'run: rota reconcile' <<<"$LM_DRY" \
  && ok "lying map → and names the one command that repairs the map" \
  || bad "lying map → reconcile pointer (got: $LM_DRY)"
grep -q '^pane-converge: restarted=0 busy=1 divergent=1 claim=primary@example.com$' <<<"$LM_LIVE" \
  && ok "lying map → the live summary shows the pane held back, not restarted" \
  || bad "lying map → live summary (got: $LM_LIVE)"
! grep -q 'send-keys' "$LM_LOG" \
  && ok "lying map → not one keystroke sent, the pane is never even /quit (wrong beats stale, so stale wins)" \
  || bad "lying map → pane was touched ($(grep 'send-keys' "$LM_LOG"))"
[ -f "$RUN/cfg/needs-reconcile" ] \
  && ok "lying map → flags needs-reconcile so the keeper repairs the map itself" \
  || bad "lying map → needs-reconcile flag missing"
grep -q 'would skip, accounts map says' <<<"$LM_RI" \
  && ok "lying map → restart-idle (the switch's default restart) refuses with the same reason" \
  || bad "lying map → restart-idle refusal (got: $LM_RI)"

# the shared-dir shape: the map sends the claim AT ~/.claude, whose credential
# in this fixture is COMPLETE and whose config_email IS the claim, both
# legacy checks would happily "pin" the nested-config trap onto every pane
explains_fixture sharedmap
FAKE_TMUX_PANES="%1${US}/dev/ttys001${US}claude.exe${US}✳ rainbow rush game"
export FAKE_TMUX_PANES
cat > "$FAKE_STATE/pool-ps.txt" <<POOLPS
PID TT STAT TIME COMMAND
101 s001 S+ 0:00 /usr/local/bin/claude CLAUDE_CONFIG_DIR=$RUN/.claude-pool/wk HOME=$RUN
POOLPS
cat > "$RUN/cfg/accounts" <<EOF
primary@example.com|$RUN/.claude
wk@example.com|$RUN/.claude-pool/wk
alpha@example.com|$RUN/.claude-pool/alpha
EOF
SM_LOG="$ROOT/tmux-sharedmap.log"
set +e
SM_DRY="$(TMUX_LOG="$SM_LOG" "$SCRIPT" pane-converge --dry-run 2>&1)"
SM_LIVE="$(TMUX_LOG="$SM_LOG" "$SCRIPT" pane-converge 2>&1)"
set -e
grep -q 'would NOT restart, accounts map sends primary@example.com to the shared ~/.claude' <<<"$SM_DRY" \
  && ok "shared-dir map → refused: pinning AT ~/.claude is the nested-config trap, never a pin target" \
  || bad "shared-dir map → dry-run refusal (got: $SM_DRY)"
grep -q '^pane-converge: restarted=0 busy=1 divergent=1 claim=primary@example.com$' <<<"$SM_LIVE" \
  && ok "shared-dir map → live run holds the pane back too" \
  || bad "shared-dir map → live summary (got: $SM_LIVE)"
! grep -q 'send-keys' "$SM_LOG" \
  && ok "shared-dir map → not one keystroke sent" \
  || bad "shared-dir map → pane was touched ($(grep 'send-keys' "$SM_LOG"))"
panes_teardown
rm -f "$FAKE_STATE/pool-ps.txt"

# ═══ THE HUSK (the always-on box, 2026-08-07) ═══════════════════════════════════
# `rota usage` said "no stored credential" about seat A hours after it had been
# logged in and working: its pool copy was a 1296-byte husk (refreshToken key with
# no value, expiresAt gone), and the personal seat's was gutted identically, while
# both switch-all stashes still held complete credentials.
#
# The first diagnosis blamed this script's own credential copies (freshness-gated,
# never content-gated). A controlled re-run disproved it: both pool copies restored,
# seat A given a FRESH login, then ONE `usage` run and nothing else, seat A survived,
# the personal seat was re-gutted. The variable was token validity, not code path. The corrupting
# write is the CLI's rejected-refresh cleanup, reached through collect_usage's haiku
# nudge. These scenarios pin that mechanism, the loop it can start, and the three
# distinct things an UNAVAILABLE row now has to be able to say.

# A COMPLETE credential: an access token plus the two fields cred_is_complete needs.
# Epochs are computed, never hard-coded, so nothing here expires with the calendar,
# but computed ONCE, so two calls a second apart cannot produce two different files
# and turn a byte-comparison into a coin flip.
EXP_1H="$(date -u -v+1H +%s)"
RT_FUTURE="$(date -u -v+30d +%s)"
RT_PAST="$(date -u -v-1d +%s)"
cred_json() {  # cred_json <token> [dead, give it an EXPIRED refresh token]
  local rt="$RT_FUTURE"; [ "${2:-}" = dead ] && rt="$RT_PAST"
  printf '{"claudeAiOauth":{"accessToken":"%s","refreshToken":"RT-%s","expiresAt":%s000,"refreshTokenExpiresAt":%s000,"scopes":["user:inference"],"subscriptionType":"max"}}' \
    "$1" "$1" "$EXP_1H" "$rt"
}
# The husk, byte-shape for byte-shape: the KEY survives a gutting, the VALUE does not.
husk_json() {
  printf '{"claudeAiOauth":{"accessToken":"","refreshToken":"","refreshTokenExpiresAt":%s000,"scopes":["user:inference"],"subscriptionType":"max"}}' \
    "$RT_FUTURE"
}

# --- 46. cred_is_complete: the ONE predicate, asserted directly -----------------
# Everything else in this block is downstream of this function, so it is tested as a
# function rather than through its effects. The script ends in `main "$@"`; a copy
# with that single last line removed is pure definitions and can be sourced.
LIB="$ROOT/failover-lib.sh"
sed '$d' "$SCRIPT" > "$LIB"
# ⚠️ AND ITS SIBLING. The script sources $ROTA_LIB/rota-ranking.sh (the seat
# ranking it shares with the keeper), and ROTA_LIB is the dirname of whatever
# copy is running, so a copy alone in $ROOT cannot find it and dies at source
# time. Every positive `lib …` assertion below then fails for a reason that has
# nothing to do with what it is testing (and every NEGATED one silently
# "passes"), which is exactly how this was found.
cp "$REPO_ROOT/lib/rota-ranking.sh" "$ROOT/rota-ranking.sh"
lib() { bash -c 'source "$1"; shift; "$@"' _ "$LIB" "$@"; }

new_run credpred
GOOD="$RUN/good.json"; cred_json TOK-GOOD > "$GOOD"
lib cred_is_complete "$GOOD" \
  && ok "cred_is_complete → accepts a complete credential" \
  || bad "cred_is_complete → accepts a complete credential"
! lib cred_is_complete "$RUN/does-not-exist.json" \
  && ok "cred_is_complete → rejects an ABSENT file" \
  || bad "cred_is_complete → rejects an absent file"
printf 'not json at all {{{' > "$RUN/unparseable.json"
! lib cred_is_complete "$RUN/unparseable.json" \
  && ok "cred_is_complete → rejects an UNPARSEABLE file" \
  || bad "cred_is_complete → rejects an unparseable file"
: > "$RUN/empty.json"
! lib cred_is_complete "$RUN/empty.json" \
  && ok "cred_is_complete → rejects an EMPTY file" \
  || bad "cred_is_complete → rejects an empty file"
printf '{"claudeAiOauth":{"accessToken":"A","refreshToken":"","expiresAt":1}}' > "$RUN/emptyrt.json"
! lib cred_is_complete "$RUN/emptyrt.json" \
  && ok "cred_is_complete → rejects an EMPTY refreshToken (the husk keeps the key)" \
  || bad "cred_is_complete → rejects an empty refreshToken"
printf '{"claudeAiOauth":{"accessToken":"A","expiresAt":1}}' > "$RUN/nort.json"
! lib cred_is_complete "$RUN/nort.json" \
  && ok "cred_is_complete → rejects a MISSING refreshToken" \
  || bad "cred_is_complete → rejects a missing refreshToken"
printf '{"claudeAiOauth":{"accessToken":"A","refreshToken":"R"}}' > "$RUN/noexp.json"
! lib cred_is_complete "$RUN/noexp.json" \
  && ok "cred_is_complete → rejects a MISSING expiresAt" \
  || bad "cred_is_complete → rejects a missing expiresAt"
printf '{"claudeAiOauth":{"accessToken":"A","refreshToken":"R","expiresAt":null}}' > "$RUN/nullexp.json"
! lib cred_is_complete "$RUN/nullexp.json" \
  && ok "cred_is_complete → rejects a NULL expiresAt (present is not the same as usable)" \
  || bad "cred_is_complete → rejects a null expiresAt"
husk_json > "$RUN/husk.json"
! lib cred_is_complete "$RUN/husk.json" \
  && ok "cred_is_complete → rejects the actual 2026-08-07 husk shape" \
  || bad "cred_is_complete → rejects the husk shape"
# and the refresh-liveness gate the self-heal depends on
cred_json TOK-DEADRT dead > "$RUN/expiredrt.json"
lib cred_refresh_alive "$GOOD" \
  && ok "cred_refresh_alive → a refresh token still in date passes" \
  || bad "cred_refresh_alive → in-date refresh token passes"
! lib cred_refresh_alive "$RUN/expiredrt.json" \
  && ok "cred_refresh_alive → an EXPIRED refresh token fails" \
  || bad "cred_refresh_alive → expired refresh token fails"
! lib cred_refresh_alive "$RUN/noexp.json" \
  && ok "cred_refresh_alive → 'cannot tell' is not 'in the future'" \
  || bad "cred_refresh_alive → no refreshTokenExpiresAt fails closed"

# --- 47. THE MECHANISM: a rejected refresh guts the file, and must not loop ------
# The hermetic reproduction of the always-on box, 2026-08-07. `deadpool`'s stored credential is
# COMPLETE but its token is not accepted (401), which is the only condition under
# which collect_usage nudges the CLI at a pool dir, and the nudge is what clears it.
# `live` has a working token and must come through untouched, exactly as seat A did.
husk_fixture() {  # husk_fixture <name>
  new_run "$1"
  mkdir -p "$RUN/.claude-pool/live" "$RUN/.claude-pool/deadpool" "$RUN/cfg/creds"
  cred_json TOK-LIVE > "$RUN/.claude/.credentials.json"
  cp "$RUN/.claude/.credentials.json" "$RUN/.claude-pool/live/.credentials.json"
  printf '{"oauthAccount":{"emailAddress":"live@example.com"}}' > "$RUN/.claude-pool/live/.claude.json"
  printf '{"oauthAccount":{"emailAddress":"deadpool@example.com"}}' > "$RUN/.claude-pool/deadpool/.claude.json"
  printf '{"oauthAccount":{"emailAddress":"live@example.com"}}' > "$RUN/.claude.json"
  cat > "$RUN/cfg/accounts" <<EOF
live@example.com|$RUN/.claude-pool/live
deadpool@example.com|$RUN/.claude-pool/deadpool
EOF
  printf '{"seven_day":{"utilization":10,"resets_at":"%s"},"five_hour":{"utilization":10,"resets_at":"%s"}}' \
    "$(iso_in +2d)" "$(iso_in +2H)" > "$RUN/state/usage-TOK-LIVE.json"
  # the pool account's own token is COMPLETE but REVOKED: a real 401, not a dead socket
  printf '401' > "$RUN/state/usage-TOK-DEADPOOL.code"
  # and the CLI clears the credential when it nudges that dir
  printf "%s\n" "$RT_FUTURE" > "$RUN/state/deadrefresh-deadpool"
}
run_usage() {  # run_usage → OUT (stdout) + ERR (stderr)
  set +e
  OUT="$(FAKE_NEW_EMAIL=live@example.com "$SCRIPT" usage --no-color 2>"$RUN/state/err")"
  RC=$?
  set -e
  ERR="$(cat "$RUN/state/err")"
}

husk_fixture gutting
cred_json TOK-DEADPOOL > "$RUN/.claude-pool/deadpool/.credentials.json"
# the stash holds the SAME credential, the alpha situation exactly (cp -p, so size
# and mtime match, which is what the dead-refresh record is keyed on)
cp -p "$RUN/.claude-pool/deadpool/.credentials.json" "$RUN/cfg/creds/deadpool@example.com.json"
run_usage
[ "$RC" -eq 0 ] && ok "husk → usage still exits 0 while an account is being cleared" \
  || bad "husk → usage exits 0 (got $RC: $ERR)"
grep -q 'the refresh token was rejected and the CLI CLEARED the stored credential' <<<"$ERR" \
  && ok "husk → the gutting is DETECTED and named as the CLI clearing a rejected credential" \
  || bad "husk → names the rejected-refresh clearing (got: $ERR)"
grep -q 'needs a re-login' <<<"$ERR" \
  && ok "husk → and the message gives the only fix there is: a re-login" \
  || bad "husk → names the re-login (got: $ERR)"
! lib cred_is_complete "$RUN/.claude-pool/deadpool/.credentials.json" \
  && ok "husk → the reproduction is real: the pool credential really was gutted" \
  || bad "husk → the fixture failed to reproduce the gutting"
lib cred_is_complete "$RUN/.claude-pool/live/.credentials.json" \
  && ok "husk → the account with a LIVE token is untouched (the live control case)" \
  || bad "husk → the live account's credential was damaged"
[ -f "$RUN/cfg/dead-refresh/deadpool@example.com" ] \
  && ok "husk → the rejected refresh is RECORDED, so the next run can know better" \
  || bad "husk → a dead-refresh record is written"
! grep -qE '[A-Za-z0-9_-]{20,}' "$RUN/cfg/dead-refresh/deadpool@example.com" \
  && ok "husk → the record is an identity (bytes:mtime), never any token material" \
  || bad "husk → the record leaked something token-shaped: $(cat "$RUN/cfg/dead-refresh/deadpool@example.com")"
grep -qE '^  ✗ deadpool@example\.com +cleared, needs login' <<<"$(unavail_block <<<"$OUT")" \
  && ok "husk → the UNAVAILABLE row says CLEARED/needs login, never 'no stored credential'" \
  || bad "husk → row reads 'cleared, needs login' (got: $(unavail_block <<<"$OUT"))"

# SECOND RUN, same box: the stash holds the same dead bytes, so restoring from it
# would only feed the next nudge. THE LOOP THIS PREVENTS: heal → probe → 401 → gut →
# heal → … rewriting the credential on every single run, forever.
NUDGES_BEFORE="$(grep -c '^deadpool$' "$RUN/state/nudges" 2>/dev/null || echo 0)"
run_usage
! grep -q 'healed deadpool@example.com' <<<"$ERR" \
  && ok "no-loop → the self-heal REFUSES a stash holding the credential we watched die" \
  || bad "no-loop → self-heal must not restore known-dead bytes (got: $ERR)"
! lib cred_is_complete "$RUN/.claude-pool/deadpool/.credentials.json" \
  && ok "no-loop → the husk is left exactly as it was, not rewritten every run" \
  || bad "no-loop → the pool copy was rewritten"
[ "$(grep -c '^deadpool$' "$RUN/state/nudges" 2>/dev/null || echo 0)" -eq "$NUDGES_BEFORE" ] \
  && ok "no-loop → and no second nudge is spent on an account that cannot refresh" \
  || bad "no-loop → the nudge was repeated"
grep -qE '^  ✗ deadpool@example\.com +cleared, needs login' <<<"$(unavail_block <<<"$OUT")" \
  && ok "no-loop → the row keeps telling the truth on every later run" \
  || bad "no-loop → row still reads 'cleared, needs login' (got: $(unavail_block <<<"$OUT"))"

# --- 48. v2: a gutted pool copy is NEVER healed from the stash any more ---------
# The v1 self-heal restored a complete stash over a gutted pool copy, a
# credential MOVE, which pool v2's invariant 1 forbids (stage-1 review,
# 2026-08-12): stashes are read-only history, and a restored-but-stale
# credential is what arms the spurious nudge→husk cycle. So the exact fixture
# that used to prove the heal now proves its ABSENCE: the husk stays, nothing
# is backed up, and the row names the re-login as the only fix.
husk_fixture heal
husk_json > "$RUN/.claude-pool/deadpool/.credentials.json"
cred_json TOK-DEADPOOL > "$RUN/cfg/creds/deadpool@example.com.json"
rm -f "$RUN/state/deadrefresh-deadpool"
STASH_BYTES="$(cat "$RUN/cfg/creds/deadpool@example.com.json")"
run_usage
! grep -q 'healed deadpool@example.com' <<<"$ERR" \
  && ok "v2 no-heal → a gutted pool copy is NOT restored from its complete stash" \
  || bad "v2 no-heal → usage healed from the stash (got: $ERR)"
[ "$(cat "$RUN/.claude-pool/deadpool/.credentials.json")" = "$(husk_json)" ] \
  && ok "v2 no-heal → the pool credential file is byte-for-byte untouched (still the husk)" \
  || bad "v2 no-heal → the pool credential was rewritten"
[ "$(cat "$RUN/cfg/creds/deadpool@example.com.json")" = "$STASH_BYTES" ] \
  && ok "v2 no-heal → the stash is read-only history, untouched too" \
  || bad "v2 no-heal → the stash changed"
[ ! -e "$RUN/.claude-pool/deadpool/.credentials.json.husk-bak-$(date +%Y-%m-%d)" ] \
  && ok "v2 no-heal → no husk backup either, because nothing was replaced" \
  || bad "v2 no-heal → a husk backup appeared for a heal that must not happen"
grep -qE '^  ✗ deadpool@example\.com +cleared, needs login' <<<"$(unavail_block <<<"$OUT")" \
  && ok "v2 no-heal → the row names the re-login as the only fix" \
  || bad "v2 no-heal → row reports the cleared credential (got: $(unavail_block <<<"$OUT"))"

# --- 49. SELF-HEAL MUST NOT FIRE when the stash cannot help ---------------------
# Three shapes, one rule: a heal is only worth doing when it can actually produce a
# usable credential. Otherwise the row must say so and stop.
husk_fixture healincomplete
husk_json > "$RUN/.claude-pool/deadpool/.credentials.json"
husk_json > "$RUN/cfg/creds/deadpool@example.com.json"   # the stash is gutted too
run_usage
! grep -q 'healed deadpool@example.com' <<<"$ERR" \
  && ok "no-heal → an INCOMPLETE stash is never restored over the pool copy" \
  || bad "no-heal → incomplete stash must not heal (got: $ERR)"
[ ! -e "$RUN/.claude-pool/deadpool/.credentials.json.husk-bak-$(date +%Y-%m-%d)" ] \
  && ok "no-heal → and nothing is backed up, because nothing was replaced" \
  || bad "no-heal → a backup was written for a heal that never happened"
grep -qE '^  ✗ deadpool@example\.com +cleared, needs login' <<<"$(unavail_block <<<"$OUT")" \
  && ok "no-heal → today's behaviour is kept: the row reports it and names the fix" \
  || bad "no-heal → row reports the state (got: $(unavail_block <<<"$OUT"))"
grep -q "CLAUDE_CONFIG_DIR=.*claude-pool/deadpool claude" <<<"$(FAKE_NEW_EMAIL=live@example.com "$SCRIPT" usage --no-color --verbose 2>/dev/null)" \
  && ok "no-heal → --verbose spells out the exact re-login command for that dir" \
  || bad "no-heal → the exact re-login command is available"

husk_fixture healexpired
husk_json > "$RUN/.claude-pool/deadpool/.credentials.json"
cred_json TOK-DEADPOOL dead > "$RUN/cfg/creds/deadpool@example.com.json"   # refresh expired
run_usage
! grep -q 'healed deadpool@example.com' <<<"$ERR" \
  && ok "no-heal → a complete stash whose REFRESH TOKEN has expired is not a rescue" \
  || bad "no-heal → expired refresh token must not heal (got: $ERR)"
! lib cred_is_complete "$RUN/.claude-pool/deadpool/.credentials.json" \
  && ok "no-heal → the pool copy is left alone rather than filled with a dead token" \
  || bad "no-heal → pool copy was overwritten from an expired stash"

# --- 50. THE THREE UNAVAILABLE REASONS, side by side ---------------------------
# One report, three accounts, three genuinely different problems, the distinction
# that did not exist on 2026-08-07, when all of them read "no stored credential" and
# sent the operator looking for a login that had already happened.
new_run reasons
mkdir -p "$RUN/.claude-pool/live" "$RUN/.claude-pool/absent" \
         "$RUN/.claude-pool/gutted" "$RUN/.claude-pool/stale"
cred_json TOK-R-LIVE > "$RUN/.claude/.credentials.json"
cp "$RUN/.claude/.credentials.json" "$RUN/.claude-pool/live/.credentials.json"
printf '{"oauthAccount":{"emailAddress":"live@example.com"}}' > "$RUN/.claude-pool/live/.claude.json"
printf '{"oauthAccount":{"emailAddress":"live@example.com"}}' > "$RUN/.claude.json"
# absent: the dir exists, the credential never did
printf '{"oauthAccount":{"emailAddress":"absent@example.com"}}' > "$RUN/.claude-pool/absent/.claude.json"
# gutted: the file exists and has been cleared, with no stash to heal from
husk_json > "$RUN/.claude-pool/gutted/.credentials.json"
printf '{"oauthAccount":{"emailAddress":"gutted@example.com"}}' > "$RUN/.claude-pool/gutted/.claude.json"
# stale: a COMPLETE credential the API answers 401 for, the third case, and the one
# that is genuinely just old rather than broken
cred_json TOK-R-STALE > "$RUN/.claude-pool/stale/.credentials.json"
printf '{"oauthAccount":{"emailAddress":"stale@example.com"}}' > "$RUN/.claude-pool/stale/.claude.json"
printf '401' > "$RUN/state/usage-TOK-R-STALE.code"
cat > "$RUN/cfg/accounts" <<EOF
live@example.com|$RUN/.claude-pool/live
absent@example.com|$RUN/.claude-pool/absent
gutted@example.com|$RUN/.claude-pool/gutted
stale@example.com|$RUN/.claude-pool/stale
EOF
printf '{"seven_day":{"utilization":10,"resets_at":"%s"},"five_hour":{"utilization":10,"resets_at":"%s"}}' \
  "$(iso_in +2d)" "$(iso_in +2H)" > "$RUN/state/usage-TOK-R-LIVE.json"
set +e
R_OUT="$(FAKE_NEW_EMAIL=live@example.com "$SCRIPT" usage --no-color 2>/dev/null)"
R_JSON="$(FAKE_NEW_EMAIL=live@example.com "$SCRIPT" usage --json 2>/dev/null)"
set -e
R_UNAVAIL="$(unavail_block <<<"$R_OUT")"
grep -qE '^  ✗ absent@example\.com +no stored credential' <<<"$R_UNAVAIL" \
  && ok "reasons → an ABSENT credential still reads 'no stored credential'" \
  || bad "reasons → absent reads 'no stored credential' (got: $R_UNAVAIL)"
grep -qE '^  ✗ gutted@example\.com +cleared, needs login' <<<"$R_UNAVAIL" \
  && ok "reasons → a GUTTED credential reads 'cleared, needs login', not 'no stored credential'" \
  || bad "reasons → gutted reads 'cleared, needs login' (got: $R_UNAVAIL)"
grep -qE '^  ✗ stale@example\.com +stored token stale' <<<"$R_UNAVAIL" \
  && ok "reasons → a COMPLETE credential the API 401s reads 'stored token stale'" \
  || bad "reasons → stale reads 'stored token stale' (got: $R_UNAVAIL)"
[ "$(grep -cE '^  ✗ ' <<<"$R_UNAVAIL")" -eq 3 ] \
  && ok "reasons → all three land in UNAVAILABLE, one row each" \
  || bad "reasons → three unavailable rows (got: $R_UNAVAIL)"
grep -q 'needs a re-login' <<<"$(jq -r '.accounts[]|select(.email=="gutted@example.com").stale_reason' <<<"$R_JSON")" \
  && ok "reasons → the JSON row a phone reads carries the re-login instruction too" \
  || bad "reasons → gutted row's JSON reason names the re-login (got: $(jq -r '.accounts[]|select(.email=="gutted@example.com").stale_reason' <<<"$R_JSON"))"
[ "$(jq -r '.accounts[]|select(.email=="gutted@example.com").loggedIn' <<<"$R_JSON")" = "false" ] \
  && ok "reasons → a cleared credential is not reported as logged in" \
  || bad "reasons → gutted account's loggedIn is false"

# --- 51. NO COPY IN THIS SCRIPT MAY TRADE A GOOD CREDENTIAL FOR A HUSK ----------
# Defence in depth, not the incident's cause: every credential copy here used to be
# gated on FRESHNESS alone, and a newer file is not a better file. sync_live_credential
# _back is the one that runs on every `rota usage`, so it is the one asserted end to end.
sync_fixture() {  # sync_fixture <name> <husk|complete, what the SHARED file holds>
  new_run "$1"
  mkdir -p "$RUN/.claude-pool/solo"
  if [ "$2" = husk ]; then husk_json > "$RUN/.claude/.credentials.json"
  else cred_json TOK-SHAREDNEW > "$RUN/.claude/.credentials.json"; fi
  cred_json TOK-POOL > "$RUN/.claude-pool/solo/.credentials.json"
  printf '{"oauthAccount":{"emailAddress":"solo@example.com"}}' > "$RUN/.claude-pool/solo/.claude.json"
  printf '{"oauthAccount":{"emailAddress":"solo@example.com"}}' > "$RUN/.claude.json"
  printf 'solo@example.com|%s\n' "$RUN/.claude-pool/solo" > "$RUN/cfg/accounts"
  printf '{"seven_day":{"utilization":10,"resets_at":"%s"},"five_hour":{"utilization":10,"resets_at":"%s"}}' \
    "$(iso_in +2d)" "$(iso_in +2H)" > "$RUN/state/usage-TOK-POOL.json"
  # the shared file must be the strictly NEWER of the pair, freshness was the only
  # gate there ever was. Back-date the pool copy rather than touching the shared one:
  # two files written in the same second TIE, and a tie is its own (correct) no-op.
  touch -t "$(date -r "$(( $(date +%s) - 120 ))" '+%Y%m%d%H%M.%S')" \
    "$RUN/.claude-pool/solo/.credentials.json"
}
# v2: shared slot is credential-free, `usage` no longer syncs the shared
# credential back into a pool dir AT ALL, in either direction. What v1 asserted
# here (the husk-refusal warning, the healthy sync) must now simply NOT happen:
# no copy attempt, no warning, and the pool copy stays byte-for-byte untouched.
sync_fixture syncrefuse husk
POOL_BEFORE="$(cat "$RUN/.claude-pool/solo/.credentials.json")"
set +e
S_ERR="$(FAKE_NEW_EMAIL=solo@example.com "$SCRIPT" usage --no-color 2>&1 >/dev/null)"
set -e
! grep -q 'REFUSED' <<<"$S_ERR" \
  && ok "v2 usage → no sync-back attempt against a husked shared file (nothing to refuse)" \
  || bad "v2 usage → sync-back guard fired, so a copy was attempted (got: $S_ERR)"
[ "$(cat "$RUN/.claude-pool/solo/.credentials.json")" = "$POOL_BEFORE" ] \
  && ok "v2 usage → the pool credential is byte-for-byte untouched" \
  || bad "v2 usage → pool copy was modified"

sync_fixture syncproceed complete
POOL_BEFORE="$(cat "$RUN/.claude-pool/solo/.credentials.json")"
set +e
S_ERR="$(FAKE_NEW_EMAIL=solo@example.com "$SCRIPT" usage --no-color 2>&1 >/dev/null)"
set -e
! grep -q 'synced live credential back into' <<<"$S_ERR" \
  && ok "v2 usage → a complete NEWER shared credential is still never copied into the pool" \
  || bad "v2 usage → sync-back ran (got: $S_ERR)"
[ "$(cat "$RUN/.claude-pool/solo/.credentials.json")" = "$POOL_BEFORE" ] \
  && ok "v2 usage → the pool copy stays exactly as it was" \
  || bad "v2 usage → pool copy updated from the shared credential"

# --- 52. switch-all: the stash and the live credential are guarded too ----------
# The stash is the last-resort copy, on the live box it was the only complete credential
# left on the box, so a husk must never be written over it, and a switch must never
# put a husk where the working live credential is.
new_run switchguard
mkdir -p "$RUN/.claude-pool/from" "$RUN/.claude-pool/to" "$RUN/cfg/creds"
husk_json > "$RUN/.claude/.credentials.json"        # the live file has been cleared
cred_json TOK-FROM > "$RUN/cfg/creds/from@example.com.json"   # …but its stash is good
cred_json TOK-FROM > "$RUN/.claude-pool/from/.credentials.json"
printf '{"oauthAccount":{"emailAddress":"from@example.com"}}' > "$RUN/.claude-pool/from/.claude.json"
husk_json > "$RUN/.claude-pool/to/.credentials.json"           # the target is gutted
printf '{"oauthAccount":{"emailAddress":"to@example.com"}}' > "$RUN/.claude-pool/to/.claude.json"
printf '{"oauthAccount":{"emailAddress":"from@example.com"}}' > "$RUN/.claude.json"
cat > "$RUN/cfg/accounts" <<EOF
from@example.com|$RUN/.claude-pool/from
to@example.com|$RUN/.claude-pool/to
EOF
STASH_BEFORE="$(cat "$RUN/cfg/creds/from@example.com.json")"
set +e
SW_OUT="$(FAKE_LAG=0 FAKE_KEYCHAIN=none "$SCRIPT" switch-all to@example.com 2>&1)"
SW_RC=$?
set -e
[ "$(cat "$RUN/cfg/creds/from@example.com.json")" = "$STASH_BEFORE" ] \
  && ok "switch-all → the outgoing account's good STASH is not overwritten by a husk" \
  || bad "switch-all → stash was clobbered by the cleared live credential"
[ "$SW_RC" -ne 0 ] \
  && ok "switch-all → a husked target is refused outright (v2: no stash to fall back on)" \
  || bad "switch-all → must refuse a husked target (got $SW_RC: $SW_OUT)"

new_run switchguard2
mkdir -p "$RUN/.claude-pool/from" "$RUN/.claude-pool/to" "$RUN/cfg/creds"
cred_json TOK-LIVE-GOOD > "$RUN/.claude/.credentials.json"    # the live credential works
cred_json TOK-LIVE-GOOD > "$RUN/.claude-pool/from/.credentials.json"
printf '{"oauthAccount":{"emailAddress":"from@example.com"}}' > "$RUN/.claude-pool/from/.claude.json"
husk_json > "$RUN/.claude-pool/to/.credentials.json"          # the target has been cleared
printf '{"oauthAccount":{"emailAddress":"to@example.com"}}' > "$RUN/.claude-pool/to/.claude.json"
printf '{"oauthAccount":{"emailAddress":"from@example.com"}}' > "$RUN/.claude.json"
cat > "$RUN/cfg/accounts" <<EOF
from@example.com|$RUN/.claude-pool/from
to@example.com|$RUN/.claude-pool/to
EOF
LIVE_BEFORE="$(cat "$RUN/.claude/.credentials.json")"
set +e
SW_OUT="$(FAKE_LAG=0 FAKE_KEYCHAIN=none "$SCRIPT" switch-all to@example.com 2>&1)"
SW_RC=$?
set -e
[ "$SW_RC" -ne 0 ] \
  && ok "switch-all → refuses to switch ONTO a cleared credential (non-zero exit)" \
  || bad "switch-all → must fail rather than break the working login (got $SW_RC: $SW_OUT)"
[ "$(cat "$RUN/.claude/.credentials.json")" = "$LIVE_BEFORE" ] \
  && ok "switch-all → and the working live credential is left exactly as it was" \
  || bad "switch-all → the live credential was overwritten with a husk"
grep -q 'needs one browser login' <<<"$SW_OUT" \
  && ok "switch-all → the refusal names the login that fixes it, not just the failure" \
  || bad "switch-all → refusal names the next step (got: $SW_OUT)"

# --- 53. PEER USAGE: read the numbers from the box that holds the credential ----
# THE DEFECT, measured on the laptop 2026-08-27: four of five seats printed `-` in
# every quota column and `[quota none]` in NOTES, because that box holds exactly
# one credential. The rejected fix is copying the other four over: an OAuth
# refresh token is SINGLE-USE, so the second copy husks the first (the 2026-08-07
# incident). The accepted fix is to read the NUMBERS from the box that
# legitimately holds them, over ssh, read-only, with nothing moving.
#
# Everything below runs against the fake `ssh` stubbed at the top of this file, so
# no scenario here can reach a real machine, and the DEFAULT behaviour of that
# stub (refuse) is itself one of the cases under test.

# UTC ISO at a `date -v` offset, e.g. `iso_at -30S` (30 seconds ago), `iso_at -2d`.
# ⚠️ BSD date: uppercase M is MINUTES, lowercase m is MONTHS. The offsets here stay
# in S/H/d for exactly that reason.
iso_at() { date -u -v"$1" '+%Y-%m-%dT%H:%M:%SZ'; }

# A peer payload in the shape `rota accounts --json` publishes (the command the
# peer is actually asked to run). Any number of seats, `<email>:<weekly-left>:<5h-left>`.
peer_json() {  # peer_json <measured-at-iso> <alias> <email:wk:se>...
  local meas="$1" alias="$2"; shift 2
  local rows="[]" spec e wk se
  for spec in "$@"; do
    IFS=: read -r e wk se <<<"$spec"
    rows="$(jq -c --argjson r "$rows" --arg e "$e" --argjson wk "$wk" --argjson se "$se" \
      --arg a "$alias" --arg m "$meas" --arg wr "$(iso_in +3d)" --arg sr "$(iso_in +2H)" \
      -n '$r + [{account:$e, alias:$a, active_now:false,
                 weekly_left_pct:$wk, weekly_resets_at:$wr,
                 five_hour_left_pct:$se, five_hour_resets_at:$sr,
                 quota_data:"cached", quota_source:null, quota_measured_at:$m}]')"
  done
  jq -cn --argjson rows "$rows" --arg g "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    '{generated_at:$g, active:"whoever@example.com", peer:null,
      monthly_total_usd_approx:0, accounts:$rows}'
}

# Two seats: one this box CAN measure (credential + a curl fixture) and one it
# cannot (no credential at all), which is the laptop's real shape in miniature.
peer_fixture() {  # peer_fixture <name> [weekly-utilization for the local seat]
  new_run "$1"
  local lu="${2:-10}"
  mkdir -p "$RUN/.claude-pool/localseat" "$RUN/.claude-pool/remoteseat"
  cred_json TOK-LOCAL > "$RUN/.claude-pool/localseat/.credentials.json"
  printf '{"oauthAccount":{"emailAddress":"local@example.com"}}' > "$RUN/.claude-pool/localseat/.claude.json"
  printf '{"oauthAccount":{"emailAddress":"remote@example.com"}}' > "$RUN/.claude-pool/remoteseat/.claude.json"
  printf '{"oauthAccount":{"emailAddress":"local@example.com"}}' > "$RUN/.claude.json"
  cat > "$RUN/cfg/accounts" <<EOF
local@example.com|$RUN/.claude-pool/localseat
remote@example.com|$RUN/.claude-pool/remoteseat
EOF
  printf '{"seven_day":{"utilization":%s,"resets_at":"%s"},"five_hour":{"utilization":5,"resets_at":"%s"}}' \
    "$lu" "$(iso_in +5d)" "$(iso_in +3H)" > "$RUN/state/usage-TOK-LOCAL.json"
}
prow() { jq -c --arg e "$1" '.accounts[] | select(.email==$e)' <<<"$2" 2>/dev/null; }
ssh_count() { grep -c . "$FAKE_STATE/ssh-calls" 2>/dev/null || echo 0; }
# norm_clock on BOTH sides, plus the day-form countdown it does not collapse
# ("4d23h"): the byte-identity cases below compare two separate runs seconds
# apart, and a reset countdown that legitimately ticks over between them would
# fail the compare once an hour for a reason that has nothing to do with peers.
norm_peer() { sed -E 's/resets in [0-9][0-9dhm]*/resets in <t>/g' | norm_clock; }

# --- 53a. a peer fills the slots this box cannot measure ------------------------
peer_fixture peerfill
peer_json "$(iso_at -30S)" remotealias remote@example.com:73:88 > "$RUN/state/peer-peerbox.json"
# ⚠️ ONE $? PER RUN. Capturing it after the second assignment silently tested the
# --json run twice and never checked the table run's exit code at all.
set +e
P_OUT="$(ROTA_PEERS=peerbox FAKE_NEW_EMAIL=local@example.com "$SCRIPT" usage 2>/dev/null)"
RC=$?
P_JSON="$(ROTA_PEERS=peerbox FAKE_NEW_EMAIL=local@example.com "$SCRIPT" usage --json 2>/dev/null)"
RC_JSON=$?
set -e
P_REMOTE="$(prow remote@example.com "$P_JSON")"
P_LOCAL="$(prow local@example.com "$P_JSON")"
[ "$RC" -eq 0 ] && ok "peer → the TABLE run exits 0 with a peer configured" || bad "peer → table exits 0 (got $RC: $P_OUT)"
[ "$RC_JSON" -eq 0 ] && ok "peer → and so does the --json run" || bad "peer → --json exits 0 (got $RC_JSON: $P_JSON)"
[ "$(jq -r '.quota_data' <<<"$P_REMOTE")" = peer ] \
  && ok "peer → the slot this box cannot measure comes back as quota_data=peer" \
  || bad "peer → remote slot is quota_data=peer (got: $P_REMOTE)"
[ "$(jq -r '.quota_source' <<<"$P_REMOTE")" = peerbox ] \
  && ok "peer → quota_source names the box the numbers were read from" \
  || bad "peer → quota_source is the host (got: $(jq -r '.quota_source' <<<"$P_REMOTE"))"
[ "$(jq -r '.weekly.remaining_pct' <<<"$P_REMOTE")" = 73 ] \
  && [ "$(jq -r '.five_hour.remaining_pct' <<<"$P_REMOTE")" = 88 ] \
  && ok "peer → both windows carry the peer's numbers (% LEFT round-trips through % USED)" \
  || bad "peer → windows carry the peer's numbers (got: $(jq -c '.weekly,.five_hour' <<<"$P_REMOTE"))"
[ "$(jq -r '.quota_measured_at' <<<"$P_REMOTE")" != null ] \
  && ok "peer → the row publishes WHEN it was measured, not just that it is borrowed" \
  || bad "peer → quota_measured_at present (got: $P_REMOTE)"
[ "$(jq -r '.peer.host' <<<"$P_JSON")" = peerbox ] \
  && ok "peer (json) → the top-level peer object names the host that answered" \
  || bad "peer (json) → top-level peer object (got: $(jq -c '.peer' <<<"$P_JSON"))"
grep -q 'via peerbox' <<<"$P_OUT" \
  && ok "peer → the rendered row says [via peerbox], a borrowed number never passes as local" \
  || bad "peer → the row is marked [via peerbox] (got: $P_OUT)"
[ "$(jq -r '.quota_data' <<<"$P_LOCAL")" = live ] \
  && [ "$(jq -r '.quota_source' <<<"$P_LOCAL")" = null ] \
  && ok "peer → a locally measured row keeps quota_data=live and a null quota_source" \
  || bad "peer → local row unchanged (got: $P_LOCAL)"
# THE INVARIANT: a peer's numbers are never seeded into THIS box's usage cache.
# That cache means "what this box measured"; a borrowed row written into it would
# come back next run wearing local clothes with the provenance stripped off.
[ "$(jq -r 'has("remote@example.com")' "$RUN/cfg/usage-cache.json" 2>/dev/null)" = false ] \
  && ok "peer → peer numbers are NEVER written into this box's usage-cache.json" \
  || bad "peer → the local cache was polluted with a peer's numbers: $(cat "$RUN/cfg/usage-cache.json" 2>/dev/null)"
# two runs, one round trip: the 90s TTL is what makes `rota accounts` twice in a
# row cost what it costs once, which is exactly how a human uses it
[ "$(ssh_count)" -eq 1 ] \
  && ok "peer → the 90s TTL cache means two consecutive runs pay ONE ssh round trip" \
  || bad "peer → expected 1 ssh call across two runs, got $(ssh_count)"

# --- 53b. R6: a peer row is exactly as (in)eligible as a cached one -------------
# Real data about a real seat, measured somewhere else. It must not become
# eligible for anything a cached row is excluded from, and 73%/88% would clear
# both floors comfortably if it were live, so an accidental promotion shows here.
[ "$(jq -r '.live' <<<"$P_REMOTE")" = false ] \
  && [ "$(jq -r '.stale' <<<"$P_REMOTE")" = true ] \
  && ok "peer (R6) → a peer row is live=false / stale=true, same as a cached row" \
  || bad "peer (R6) → peer row must read as stale, not live (got: $P_REMOTE)"
[ "$(jq -r '.recommendable' <<<"$P_REMOTE")" = false ] \
  && ok "peer (R6) → and it is NOT recommendable on the strict live-only pass" \
  || bad "peer (R6) → a peer row must not be recommendable where a cached row is not"

# --- 53c. a LIVE local fetch always beats a peer row for the same slot ----------
peer_fixture peerlocalwins
peer_json "$(iso_at -30S)" remotealias local@example.com:1:1 remote@example.com:73:88 \
  > "$RUN/state/peer-peerbox.json"
P_JSON="$(ROTA_PEERS=peerbox FAKE_NEW_EMAIL=local@example.com "$SCRIPT" usage --json 2>/dev/null)"
P_LOCAL="$(prow local@example.com "$P_JSON")"
[ "$(jq -r '.quota_data' <<<"$P_LOCAL")" = live ] \
  && [ "$(jq -r '.weekly.remaining_pct' <<<"$P_LOCAL")" = 90 ] \
  && ok "precedence → local LIVE wins outright, the peer's 1% never displaces it" \
  || bad "precedence → local live must win (got: $P_LOCAL)"

# --- 53d. between local cache and peer, the NEWER MEASUREMENT wins --------------
# Both directions, because a rule that only ever prefers one side is not a
# comparison. The remote seat has no credential either way, so the only question
# is which remembered number is younger.
peer_fixture peerfresherlocal
jq -n --arg wr "$(iso_in +3d)" --arg sr "$(iso_in +2H)" --arg te "$(( $(date +%s) - 60 ))" \
  '{"remote@example.com":{wk_u:"40",wk_r:$wr,se_u:"30",se_r:$sr,ts:"a minute ago",ts_epoch:$te}}' \
  > "$RUN/cfg/usage-cache.json"
peer_json "$(iso_at -2d)" remotealias remote@example.com:73:88 > "$RUN/state/peer-peerbox.json"
P_JSON="$(ROTA_PEERS=peerbox FAKE_NEW_EMAIL=local@example.com "$SCRIPT" usage --json 2>/dev/null)"
P_REMOTE="$(prow remote@example.com "$P_JSON")"
[ "$(jq -r '.quota_data' <<<"$P_REMOTE")" = cached ] \
  && [ "$(jq -r '.weekly.remaining_pct' <<<"$P_REMOTE")" = 60 ] \
  && ok "precedence → a MINUTE-old local cache beats a two-day-old peer row" \
  || bad "precedence → fresher local cache must win (got: $P_REMOTE)"

peer_fixture peerfresherpeer
jq -n --arg wr "$(iso_in +3d)" --arg sr "$(iso_in +2H)" --arg te "$(( $(date +%s) - 259200 ))" \
  '{"remote@example.com":{wk_u:"40",wk_r:$wr,se_u:"30",se_r:$sr,ts:"three days ago",ts_epoch:$te}}' \
  > "$RUN/cfg/usage-cache.json"
peer_json "$(iso_at -30S)" remotealias remote@example.com:73:88 > "$RUN/state/peer-peerbox.json"
P_JSON="$(ROTA_PEERS=peerbox FAKE_NEW_EMAIL=local@example.com "$SCRIPT" usage --json 2>/dev/null)"
P_REMOTE="$(prow remote@example.com "$P_JSON")"
[ "$(jq -r '.quota_data' <<<"$P_REMOTE")" = peer ] \
  && [ "$(jq -r '.weekly.remaining_pct' <<<"$P_REMOTE")" = 73 ] \
  && ok "precedence → a fresh peer row beats a three-day-old local cache" \
  || bad "precedence → fresher peer must win (got: $P_REMOTE)"

# --- 53e. AGE IS VISIBLE on anything that is not a live local measurement -------
# 2026-08-27: two seats on the pool host have had dead access tokens for ~17h and
# ~59h, and the keeper cannot rotate them (nothing runs a session on those seats),
# so the staleness is STRUCTURAL. Their rows printed a confident percentage behind
# a bare marker. A 2.5-day-old number shown like a live one is worse than a blank.
peer_fixture peerage
peer_json "$(iso_at -2d)" remotealias remote@example.com:73:88 > "$RUN/state/peer-peerbox.json"
P_OUT="$(ROTA_PEERS=peerbox FAKE_NEW_EMAIL=local@example.com "$SCRIPT" usage 2>/dev/null)"
grep -q 'via peerbox, 2d old' <<<"$P_OUT" \
  && ok "age → a two-day-old peer number says so, in one coarse glanceable unit" \
  || bad "age → a stale peer row shows its age (got: $P_OUT)"
peer_fixture peerageminor
peer_json "$(iso_at -30S)" remotealias remote@example.com:73:88 > "$RUN/state/peer-peerbox.json"
P_OUT="$(ROTA_PEERS=peerbox FAKE_NEW_EMAIL=local@example.com "$SCRIPT" usage 2>/dev/null)"
grep -q 'via peerbox' <<<"$P_OUT" && ! grep -qE 'via peerbox, [0-9]+[mhd] old' <<<"$P_OUT" \
  && ok "age → a number measured 30s ago carries no age: below 120s it IS now" \
  || bad "age → a fresh peer row shows no age (got: $P_OUT)"

# --- 53f. an unreachable peer degrades to BYTE-IDENTICAL output -----------------
# The whole feature is a bonus on top of a table that was already correct. A peer
# problem must never cost the operator a line to read, a stack trace, or a hang.
peer_fixture peerdown
P_NOPEER="$("$SCRIPT" usage 2>/dev/null | norm_peer)"
P_DEAD="$(ROTA_PEERS=deadbox "$SCRIPT" usage 2>"$RUN/peer.err" | norm_peer)"
[ "$P_NOPEER" = "$P_DEAD" ] \
  && ok "unreachable peer → output is byte-identical to having no peer at all" \
  || bad "unreachable peer → output drifted: $(diff <(printf '%s\n' "$P_NOPEER") <(printf '%s\n' "$P_DEAD") || true)"
[ ! -s "$RUN/peer.err" ] \
  && ok "unreachable peer → not one byte on stderr, it is not the operator's problem" \
  || bad "unreachable peer → stderr must stay empty (got: $(cat "$RUN/peer.err"))"
grep -q 'peer deadbox' <<<"$(ROTA_PEERS=deadbox "$SCRIPT" usage --verbose 2>&1 >/dev/null)" \
  && ok "unreachable peer → --verbose, and only --verbose, explains what happened" \
  || bad "unreachable peer → --verbose explains it"
# the same for a peer that answers with something that is not JSON
peer_fixture peerjunk
: > "$RUN/state/peer-junk-peerbox"
P_JUNK="$(ROTA_PEERS=peerbox "$SCRIPT" usage --json 2>/dev/null)"
[ "$(jq -r '.accounts[] | select(.email=="remote@example.com") | .quota_data' <<<"$P_JUNK")" = none ] \
  && ok "junk from a peer → ignored, the row stays honestly empty" \
  || bad "junk from a peer → must be ignored (got: $P_JUNK)"

# a peer that ACCEPTS the connection and then hangs is the case ConnectTimeout
# cannot cover, and the one that would turn `cdt accounts` into a wait. The bound
# is enforced by peer_ssh itself, so the run must come back on its own.
peer_fixture peerhang
: > "$RUN/state/peer-slow-peerbox"
HANG_START="$(date +%s)"
set +e
P_HANG="$(ROTA_PEER_TIMEOUT=1 ROTA_PEERS=peerbox "$SCRIPT" usage --json 2>/dev/null)"
HANG_RC=$?
set -e
HANG_SECS=$(( $(date +%s) - HANG_START ))
[ "$HANG_RC" -eq 0 ] && [ "$HANG_SECS" -lt 15 ] \
  && ok "hanging peer → killed at the bound and the run finishes on its own (${HANG_SECS}s)" \
  || bad "hanging peer → must be bounded (rc=$HANG_RC, took ${HANG_SECS}s)"
[ "$(jq -r '.accounts[] | select(.email=="remote@example.com") | .quota_data' <<<"$P_HANG")" = none ] \
  && ok "hanging peer → and the row falls back to the honest blank, not a half-read payload" \
  || bad "hanging peer → row must stay empty (got: $P_HANG)"

# THE BOUND IS ON THE STEP, NOT ON THE DIAL. With the watchdog inside peer_ssh
# (one call per host) three hanging peers cost 3 × PEER_TIMEOUT: measured at 7s
# with ROTA_PEER_TIMEOUT=2, which is ~30s at the default while the operator sits
# at a prompt. config/peers.example invites a list, so this is reachable as
# shipped. The assertion is on TOTAL WALL TIME, because a per-dial assertion is
# exactly what passed while the step was unbounded.
peer_fixture peerhang3
: > "$RUN/state/peer-slow-hangA"; : > "$RUN/state/peer-slow-hangB"; : > "$RUN/state/peer-slow-hangC"
H3_START="$(date +%s)"
set +e
ROTA_PEER_TIMEOUT=2 ROTA_PEERS="hangA hangB hangC" "$SCRIPT" usage --json >/dev/null 2>&1
H3_RC=$?
set -e
H3_SECS=$(( $(date +%s) - H3_START ))
[ "$H3_RC" -eq 0 ] && [ "$H3_SECS" -le 4 ] \
  && ok "step deadline → THREE hanging peers cost one 2s budget between them, not 2s each (${H3_SECS}s)" \
  || bad "step deadline → the whole step must be bounded (rc=$H3_RC, took ${H3_SECS}s for 3 peers at 2s)"
[ "$(ssh_count)" -eq 1 ] \
  && ok "step deadline → and the peers behind the spent budget are skipped, not dialled" \
  || bad "step deadline → expected 1 dial once the budget was gone, got $(ssh_count)"

# NEGATIVE CACHING. Caching only successes meant an unreachable peer was
# re-dialled on every single invocation, so for as long as ballito was asleep
# every `cdt accounts` on the laptop stalled for the full bound. That is a worse
# daily experience than the blank table this feature exists to fix.
peer_fixture peerfailcache
: > "$RUN/state/peer-slow-peerbox"
NC_START="$(date +%s)"
for _ in 1 2 3; do
  ROTA_PEER_TIMEOUT=2 ROTA_PEERS=peerbox "$SCRIPT" usage --json >/dev/null 2>&1 || true
done
NC_SECS=$(( $(date +%s) - NC_START ))
[ "$(ssh_count)" -eq 1 ] \
  && ok "failure cache → a dead peer is dialled ONCE across three runs, not three times" \
  || bad "failure cache → expected 1 dial across three runs, got $(ssh_count)"
[ "$NC_SECS" -le 4 ] \
  && ok "failure cache → so runs 2 and 3 cost nothing at all (${NC_SECS}s for all three)" \
  || bad "failure cache → runs after the first must not stall (took ${NC_SECS}s)"
[ "$(jq -r '.peerbox.failed' "$RUN/cfg/peer-usage-cache.json" 2>/dev/null)" = true ] \
  && ok "failure cache → the failure is recorded with its own stamp, next to the payload entries" \
  || bad "failure cache → nothing written to peer-usage-cache.json: $(cat "$RUN/cfg/peer-usage-cache.json" 2>/dev/null)"
# ...and it is a COOLING-OFF WINDOW, never a blacklist: with the window at zero
# every run tries again, which is what lets a woken box come back on its own.
peer_fixture peerfailttl
: > "$RUN/state/peer-slow-peerbox"
for _ in 1 2; do
  ROTA_PEER_FAIL_TTL=0 ROTA_PEER_TIMEOUT=1 ROTA_PEERS=peerbox "$SCRIPT" usage --json >/dev/null 2>&1 || true
done
[ "$(ssh_count)" -eq 2 ] \
  && ok "failure cache → it is a cooling-off window, not a blacklist: TTL=0 retries every run" \
  || bad "failure cache → TTL=0 must re-dial each run, got $(ssh_count) dial(s)"
# a suppressed failure must still render exactly the no-peer table
peer_fixture peerfailquiet
: > "$RUN/state/peer-slow-peerbox"
ROTA_PEER_TIMEOUT=1 ROTA_PEERS=peerbox "$SCRIPT" usage >/dev/null 2>&1 || true
FQ_NOPEER="$("$SCRIPT" usage 2>/dev/null | norm_peer)"
FQ_CACHED="$(ROTA_PEERS=peerbox "$SCRIPT" usage 2>"$RUN/fq.err" | norm_peer)"
[ "$FQ_NOPEER" = "$FQ_CACHED" ] && [ ! -s "$RUN/fq.err" ] \
  && ok "failure cache → a suppressed peer still renders byte-identical no-peer output, silently" \
  || bad "failure cache → suppressed peer output drifted: $(diff <(printf '%s\n' "$FQ_NOPEER") <(printf '%s\n' "$FQ_CACHED") || true)"

# --- 53f2. A HOSTILE PAYLOAD: peer percentages are untrusted input --------------
# Reproduced 2026-08-27 against the unvalidated arithmetic that shipped in the
# first draft of this feature:
#   "n/a"                      → `n: unbound variable`, exit 1, no table AND no
#                                JSON, breaking both the degrade-quietly contract
#                                and `usage --json`'s always-one-object promise
#   "U_WKX[$(touch FILE)0]"    → exit 0, a normal-looking table, and the command
#                                RAN: bash evaluates array subscripts inside
#                                $(( )), and `set -u` only blocks the undefined
#                                -array spelling, not a name that exists
#   "85%" / "1e3" / true       → each one aborted the whole command
# The peer is semi-trusted at best (accept-new means a re-imaged box's key is
# taken silently), and one command as Cédric is a categorically different grant
# from reading percentages off a machine.
peer_fixture peerhostile
PWN="$RUN/state/PWNED"     # ⚠️ no dot in the path: ${v%.*} would truncate the probe
for VAL in '"n/a"' 'true' '"85%"' '"1e3"' "\"U_WKX[\$(touch $PWN)0]\""; do
  rm -f "$RUN/cfg/peer-usage-cache.json" "$PWN"
  jq -n --argjson wk "$(jq -n --arg v "$VAL" '$v' >/dev/null 2>&1 && printf '%s' "$VAL" || printf 'null')" \
     --arg g "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" --arg m "$(iso_at -30S)" \
     --arg wr "$(iso_in +3d)" --arg sr "$(iso_in +2H)" \
     '{generated_at:$g, peer:null, accounts:[{account:"remote@example.com",alias:"remotealias",
        weekly_left_pct:$wk, weekly_resets_at:$wr, five_hour_left_pct:88,
        five_hour_resets_at:$sr, quota_data:"cached", quota_source:null,
        quota_measured_at:$m}]}' > "$RUN/state/peer-peerbox.json"
  # FAKE_NEW_EMAIL pins the auth-status stub to the account ~/.claude.json claims;
  # without it the run prints the (correct, unrelated) identity WARNING to stderr
  # and the capture stops being the one parseable object under test.
  set +e
  HOSTILE_OUT="$(ROTA_PEERS=peerbox FAKE_NEW_EMAIL=local@example.com "$SCRIPT" usage --json 2>/dev/null)"
  HOSTILE_RC=$?
  set -e
  [ "$HOSTILE_RC" -eq 0 ] && jq -e 'type=="object"' <<<"$HOSTILE_OUT" >/dev/null 2>&1 \
    && ok "hostile payload → weekly_left_pct=$VAL still answers one parseable object, exit 0" \
    || bad "hostile payload → $VAL broke the command (rc=$HOSTILE_RC): $(head -1 <<<"$HOSTILE_OUT")"
  [ "$(jq -r '.accounts[] | select(.email=="remote@example.com") | .weekly.remaining_pct' <<<"$HOSTILE_OUT" 2>/dev/null)" = null ] \
    && ok "hostile payload → $VAL is treated as 'the peer supplied nothing', never guessed at" \
    || bad "hostile payload → $VAL produced a weekly number: $(jq -c '.accounts[]|select(.email=="remote@example.com")|.weekly' <<<"$HOSTILE_OUT" 2>/dev/null)"
done
[ ! -e "$PWN" ] \
  && ok "hostile payload → NO command ran: a peer cannot execute anything on this box" \
  || bad "hostile payload → the peer executed a command (created $PWN)"
# both windows hostile → the row falls through entirely, as if the peer had no row
rm -f "$RUN/cfg/peer-usage-cache.json"
jq -n --arg g "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" --arg m "$(iso_at -30S)" \
  '{generated_at:$g, peer:null, accounts:[{account:"remote@example.com",
     weekly_left_pct:"n/a", five_hour_left_pct:"n/a", quota_data:"cached",
     quota_measured_at:$m}]}' > "$RUN/state/peer-peerbox.json"
HOSTILE_BOTH="$(ROTA_PEERS=peerbox FAKE_NEW_EMAIL=local@example.com "$SCRIPT" usage --json 2>/dev/null)"
[ "$(jq -r '.accounts[] | select(.email=="remote@example.com") | .quota_data' <<<"$HOSTILE_BOTH")" = none ] \
  && ok "hostile payload → a row with NO usable number at all is not claimed as a peer row" \
  || bad "hostile payload → both-windows-garbage must fall through (got: $HOSTILE_BOTH)"

# --- 53f3. the `rota usage --json` fallback shape --------------------------------
# The peer is asked for `rota accounts --json` first, but that needs a billing.json
# on the peer; without one the same ssh falls back to `rota usage --json`, whose
# field names are entirely different (email / weekly.remaining_pct rather than
# account / weekly_left_pct). Both shapes are accepted precisely so a peer without
# a billing file still contributes, and until now only one of them was exercised.
peer_fixture peerenginshape
jq -n --arg g "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" --arg m "$(iso_at -30S)" \
   --arg wr "$(iso_in +3d)" --arg sr "$(iso_in +2H)" \
  '{generated_at:$g, peer:null, accounts:[{label:"remote@example.com",
     email:"remote@example.com", alias:"remotealias", data:"cached",
     quota_data:"cached", quota_source:null, quota_measured_at:$m,
     weekly:{remaining_pct:64, resets_at:$wr},
     five_hour:{remaining_pct:91, resets_at:$sr}}]}' > "$RUN/state/peer-peerbox.json"
P_ENG="$(ROTA_PEERS=peerbox FAKE_NEW_EMAIL=local@example.com "$SCRIPT" usage --json 2>/dev/null)"
P_ENG_ROW="$(prow remote@example.com "$P_ENG")"
[ "$(jq -r '.quota_data' <<<"$P_ENG_ROW")" = peer ] \
  && [ "$(jq -r '.weekly.remaining_pct' <<<"$P_ENG_ROW")" = 64 ] \
  && [ "$(jq -r '.five_hour.remaining_pct' <<<"$P_ENG_ROW")" = 91 ] \
  && ok "engine-shaped payload → a peer with no billing.json still fills the row" \
  || bad "engine-shaped payload → both windows must parse (got: $P_ENG_ROW)"
[ "$(jq -r '.five_hour.resets_at' <<<"$P_ENG_ROW")" != null ] \
  && ok "engine-shaped payload → and it carries the 5h reset the billing shape used to drop" \
  || bad "engine-shaped payload → 5h resets_at parsed (got: $P_ENG_ROW)"

# --- 53f4. MULTIPLE PEERS: first useful answer wins, and only then stop ----------
# R2 is "one ssh per peer, in configured order, stopping at the FIRST that answers
# usefully". Usefully is the load-bearing word: a peer that answers with nothing
# this box is missing must NOT end the search, or one healthy-but-irrelevant box
# in front of the right one silently disables the feature.
peer_fixture peerfirstwins
peer_json "$(iso_at -30S)" remotealias remote@example.com:73:88 > "$RUN/state/peer-boxA.json"
peer_json "$(iso_at -30S)" remotealias remote@example.com:11:11 > "$RUN/state/peer-boxB.json"
P_MULTI="$(ROTA_PEERS="boxA boxB" FAKE_NEW_EMAIL=local@example.com "$SCRIPT" usage --json 2>/dev/null)"
[ "$(jq -r '.peer.host' <<<"$P_MULTI")" = boxA ] \
  && [ "$(jq -r '.accounts[]|select(.email=="remote@example.com")|.weekly.remaining_pct' <<<"$P_MULTI")" = 73 ] \
  && ok "multi-peer → the FIRST peer that answers usefully wins, in configured order" \
  || bad "multi-peer → boxA must win (got: $(jq -c '.peer' <<<"$P_MULTI"))"
[ "$(ssh_count)" -eq 1 ] \
  && ok "multi-peer → and boxB is never dialled at all once boxA has answered" \
  || bad "multi-peer → expected 1 dial, got $(ssh_count)"

peer_fixture peeruseless
# boxA is up and healthy but knows nothing about the seat this box is missing
peer_json "$(iso_at -30S)" other other@example.com:99:99 > "$RUN/state/peer-boxA.json"
peer_json "$(iso_at -30S)" remotealias remote@example.com:41:55 > "$RUN/state/peer-boxB.json"
P_USELESS="$(ROTA_PEERS="boxA boxB" FAKE_NEW_EMAIL=local@example.com "$SCRIPT" usage --json 2>/dev/null)"
[ "$(jq -r '.peer.host' <<<"$P_USELESS")" = boxB ] \
  && [ "$(jq -r '.accounts[]|select(.email=="remote@example.com")|.weekly.remaining_pct' <<<"$P_USELESS")" = 41 ] \
  && ok "multi-peer → a peer that answers UNUSEFULLY does not end the search" \
  || bad "multi-peer → boxB must be consulted after a useless boxA (got: $(jq -c '.peer' <<<"$P_USELESS"))"
[ "$(ssh_count)" -eq 2 ] \
  && ok "multi-peer → both were dialled, once each, in order" \
  || bad "multi-peer → expected 2 dials, got $(ssh_count)"

# --- 53f5. a corrupt peer cache SELF-HEALS -------------------------------------
# Same rule cache_flush already lives by: a truncated write must never poison
# every later run. Half a JSON object on disk has to cost one re-dial, not the
# feature.
peer_fixture peercorrupt
peer_json "$(iso_at -30S)" remotealias remote@example.com:73:88 > "$RUN/state/peer-peerbox.json"
printf '{"peerbox": {"at": 17562900' > "$RUN/cfg/peer-usage-cache.json"   # truncated mid-write
set +e
P_CORRUPT="$(ROTA_PEERS=peerbox FAKE_NEW_EMAIL=local@example.com "$SCRIPT" usage --json 2>"$RUN/corrupt.err")"
CORRUPT_RC=$?
set -e
[ "$CORRUPT_RC" -eq 0 ] && [ ! -s "$RUN/corrupt.err" ] \
  && ok "corrupt peer cache → exit 0 and silent, exactly as a corrupt usage cache is" \
  || bad "corrupt peer cache → must degrade quietly (rc=$CORRUPT_RC: $(cat "$RUN/corrupt.err"))"
[ "$(jq -r '.accounts[]|select(.email=="remote@example.com")|.quota_data' <<<"$P_CORRUPT")" = peer ] \
  && ok "corrupt peer cache → the run re-dials and the row still fills" \
  || bad "corrupt peer cache → the row must still fill (got: $P_CORRUPT)"
jq -e . "$RUN/cfg/peer-usage-cache.json" >/dev/null 2>&1 \
  && ok "corrupt peer cache → and the junk is replaced with a valid file, not appended to" \
  || bad "corrupt peer cache → the file is still corrupt: $(cat "$RUN/cfg/peer-usage-cache.json")"

# --- 53g. --no-refresh performs NO peer call ------------------------------------
# "no network" is the whole promise of the flag, and ssh is network.
peer_fixture peernorefresh
peer_json "$(iso_at -30S)" remotealias remote@example.com:73:88 > "$RUN/state/peer-peerbox.json"
ROTA_PEERS=peerbox "$SCRIPT" usage --no-refresh --json >/dev/null 2>&1 || true
[ "$(ssh_count)" -eq 0 ] \
  && ok "--no-refresh → not one ssh call: an explicit 'no network' outranks a peer" \
  || bad "--no-refresh → made $(ssh_count) ssh call(s)"

# --- 53h. matching is on EMAIL, never on alias ----------------------------------
# An alias is a per-box DIRECTORY NAME. Two boxes can both call a seat `remote`
# and mean two different logins; cross-matching would print one seat's numbers on
# another seat's line, which is the one failure worse than a blank row.
peer_fixture peeralias
peer_json "$(iso_at -30S)" remoteseat someone-else@example.com:73:88 > "$RUN/state/peer-peerbox.json"
P_JSON="$(ROTA_PEERS=peerbox "$SCRIPT" usage --json 2>/dev/null)"
[ "$(jq -r '.accounts[] | select(.email=="remote@example.com") | .quota_data' <<<"$P_JSON")" = none ] \
  && ok "alias collision → a peer row whose ALIAS matches but whose email does not is ignored" \
  || bad "alias collision → must not cross-match (got: $P_JSON)"
[ "$(jq -r '.peer' <<<"$P_JSON")" = null ] \
  && ok "alias collision → and no peer is claimed, because none was usable" \
  || bad "alias collision → peer must stay null (got: $(jq -c '.peer' <<<"$P_JSON"))"

# --- 53i. the peers FILE, and never dialling yourself ---------------------------
peer_fixture peerfile
peer_json "$(iso_at -30S)" remotealias remote@example.com:73:88 > "$RUN/state/peer-peerbox.json"
printf '# boxes that hold what this one does not\n\n  peerbox  \n' > "$RUN/cfg/peers"
P_JSON="$("$SCRIPT" usage --json 2>/dev/null)"
[ "$(jq -r '.accounts[] | select(.email=="remote@example.com") | .quota_data' <<<"$P_JSON")" = peer ] \
  && ok "peers file → read from \$CFG_DIR/peers, with comments and blank lines ignored" \
  || bad "peers file → the file is read (got: $P_JSON)"

peer_fixture peerself
SELF_HOST="$(hostname -s 2>/dev/null || echo unknown)"
peer_json "$(iso_at -30S)" remotealias remote@example.com:73:88 > "$RUN/state/peer-$SELF_HOST.json"
ROTA_PEERS="$SELF_HOST" "$SCRIPT" usage --json >/dev/null 2>&1 || true
[ "$(ssh_count)" -eq 0 ] \
  && ok "self as peer → skipped, never a round trip to our own sshd for numbers we have" \
  || bad "self as peer → dialled itself $(ssh_count) time(s)"

# ...INCLUDING the fully-qualified spelling, which is the case the $HOSTNAME
# comparison was added for and the one it was getting wrong: only the SELF side
# was truncated at the first dot, so HOSTNAME=peerbox.local plus `peerbox.local`
# in the peers file matched nothing and the box dialled its own sshd. The fixture
# is armed, so a failure to skip fills the row and is visible twice over.
peer_fixture peerselffqdn
peer_json "$(iso_at -30S)" remotealias remote@example.com:73:88 > "$RUN/state/peer-peerbox.local.json"
P_FQDN="$(HOSTNAME=peerbox.local ROTA_PEERS=peerbox.local "$SCRIPT" usage --json 2>/dev/null)"
[ "$(ssh_count)" -eq 0 ] \
  && ok "self as peer → the FQDN spelling is skipped too (HOSTNAME=peerbox.local vs peerbox.local)" \
  || bad "self as peer → dialled its own FQDN $(ssh_count) time(s)"
[ "$(jq -r '.peer' <<<"$P_FQDN")" = null ] \
  && ok "self as peer → and no peer is claimed, so the row stays this box's own answer" \
  || bad "self as peer → peer must stay null (got: $(jq -c '.peer' <<<"$P_FQDN"))"

# --- 53j. R6 in the switch path: peer rides with cached, in both directions -----
# switch-auto's STRICT first pass demands live rows and must refuse a peer row
# exactly as it refuses a cached one; its SECOND pass (the cached fallback that
# exists so a bare `rota switch` never dead-ends) must then accept it, and say
# out loud that the pick was not measured here.
peer_fixture peerswitch 98      # the active seat is down to 2% weekly left
peer_json "$(iso_at -30S)" remotealias remote@example.com:73:88 > "$RUN/state/peer-peerbox.json"
set +e
SW_OUT="$(ROTA_PEERS=peerbox FAKE_NEW_EMAIL=local@example.com "$SCRIPT" switch-auto --dry-run 2>&1)"
SW_RC=$?
set -e
[ "$SW_RC" -eq 0 ] && ok "peer (R6) → switch-auto --dry-run exits 0" || bad "peer (R6) → switch-auto exits 0 (got $SW_RC: $SW_OUT)"
grep -q 'optimizer pick: remote@example.com' <<<"$SW_OUT" \
  && ok "peer (R6) → the cached-fallback pass picks the peer row, exactly as it would a cached one" \
  || bad "peer (R6) → the fallback pass picks the peer seat (got: $SW_OUT)"
grep -q 'no account returned LIVE numbers this run' <<<"$SW_OUT" \
  && ok "peer (R6) → and it says the strict live-only pass found nothing first" \
  || bad "peer (R6) → the fallback says why it fell back (got: $SW_OUT)"
grep -q 'not a live measurement: via peerbox' <<<"$SW_OUT" \
  && ok "peer (R6) → the pick line names the box that measured it, not a borrowed 'cached' age" \
  || bad "peer (R6) → the pick names its source (got: $SW_OUT)"

# --- 54. UNMEASURED × peer: the two changes composed ---------------------------
#
# These two landed independently and answer the same operator question from
# opposite ends, so the interesting cases are the ones NEITHER suite had:
#   the SEAT's lifecycle  (2026-08-25) - unknown quota is not spent quota, and a
#                                        cancelled seat is not a dead seat
#   the PEER fallback     (2026-08-27) - a box with no credential for a seat
#                                        borrows that seat's numbers over ssh
# The bucket rule they have to agree on is one sentence: a row is UNMEASURED when
# THIS REPORT has no number for the window you would spend right now. Not "this
# box failed to fetch" - after a peer fill those are different facts.

# --- 54a. a peer row whose window has ROLLED is UNMEASURED, not spent -----------
# The whole 2026-08-21 harm, arriving by ssh instead of out of the local cache:
# the number describes a window that no longer exists, so it must not render as a
# figure, must not read as an obituary, and must still say WHOSE measurement it
# was and how old.
peer_fixture peerrolled
peer_json "$(iso_at -2d)" remotealias remote@example.com:73:88 \
  | jq -c --arg wr "$(iso_in -2d)" '.accounts[0].weekly_resets_at=$wr' \
  > "$RUN/state/peer-peerbox.json"
jq -n --arg ends "$(date -u -v+5d '+%Y-%m-%d')" \
  '{accounts:{"remote@example.com":{plan:"Max 20x",status:"cancelled",ends:$ends}}}' \
  > "$RUN/billing.json"
set +e
PU_OUT="$(ROTA_PEERS=peerbox FAKE_NEW_EMAIL=local@example.com \
          CLAUDE_BILLING_JSON="$RUN/billing.json" "$SCRIPT" usage 2>/dev/null)"
PU_JSON="$(ROTA_PEERS=peerbox FAKE_NEW_EMAIL=local@example.com \
           CLAUDE_BILLING_JSON="$RUN/billing.json" "$SCRIPT" usage --json 2>/dev/null)"
set -e
PU_REMOTE="$(prow remote@example.com "$PU_JSON")"
grep -q 'remote@example.com' <<<"$(unmeasured_block <<<"$PU_OUT")" \
  && ok "peer × unmeasured → a peer row whose window rolled lands in UNMEASURED" \
  || bad "peer × unmeasured → belongs in UNMEASURED (got: $PU_OUT)"
! grep -q 'remote@example.com' <<<"$(unavail_block <<<"$PU_OUT")" \
  && ok "peer × unmeasured → and NOT in UNAVAILABLE: a rolled window is not a dead seat" \
  || bad "peer × unmeasured → must not be UNAVAILABLE (got: $PU_OUT)"
grep -q 'via peerbox' <<<"$(unmeasured_block <<<"$PU_OUT")" \
  && ok "peer × unmeasured → the UNMEASURED row still names the box that measured it" \
  || bad "peer × unmeasured → the row keeps its provenance (got: $PU_OUT)"
grep -q 'cancelled, quota until' <<<"$(unmeasured_block <<<"$PU_OUT")" \
  && ok "peer × unmeasured → and still names the seat-end deadline that ranks it" \
  || bad "peer × unmeasured → names its end date (got: $PU_OUT)"
[ "$(jq -r '.unmeasured' <<<"$PU_REMOTE")" = true ] \
  && [ "$(jq -r '.quota_data' <<<"$PU_REMOTE")" = peer ] \
  && [ "$(jq -r '.weekly.remaining_pct' <<<"$PU_REMOTE")" = null ] \
  && ok "peer × unmeasured (json) → unmeasured:true, quota_data:peer, and no stale figure" \
  || bad "peer × unmeasured (json) → wrong shape (got: $PU_REMOTE)"

# --- 54b. a peer row with a CURRENT window is MEASURED, whatever this box's own
#          probe did -----------------------------------------------------------
# ⚠️ THE REGRESSION THIS FILE EXISTS FOR. weekly_unknown was written before peer
# rows existed and asked U_WHY, which answers "why did THIS box fail to fetch".
# After a peer fill a row can carry a 429 in U_WHY *and* a real current-window
# number measured over ssh: asking U_WHY alone filed that number under
# UNMEASURED, a bucket that prints no number at all and tells the operator to go
# and read one off the vendor's page. That is the exact inversion the UNMEASURED
# bucket exists to prevent, pointing the other way.
#
# It is also R6: a `peer` row must answer this question exactly as a `cached` one
# would, so the fix is to ask the ROW ("is there a number for the current
# window") rather than the probe.
peer_fixture peer429
cred_json TOK-REMOTE > "$RUN/.claude-pool/remoteseat/.credentials.json"
printf '429' > "$RUN/state/usage-TOK-REMOTE.code"
peer_json "$(iso_at -30S)" remotealias remote@example.com:73:88 > "$RUN/state/peer-peerbox.json"
set +e
P4_OUT="$(ROTA_PEERS=peerbox FAKE_NEW_EMAIL=local@example.com "$SCRIPT" usage 2>/dev/null)"
P4_JSON="$(ROTA_PEERS=peerbox FAKE_NEW_EMAIL=local@example.com "$SCRIPT" usage --json 2>/dev/null)"
set -e
P4_REMOTE="$(prow remote@example.com "$P4_JSON")"
[ "$(jq -r '.quota_data' <<<"$P4_REMOTE")" = peer ] \
  && [ "$(jq -r '.weekly.remaining_pct' <<<"$P4_REMOTE")" = 73 ] \
  && ok "peer × 429 → the local 429 is rescued by the peer, the row carries 73% left" \
  || bad "peer × 429 → the peer must fill the 429'd row (got: $P4_REMOTE)"
[ "$(jq -r '.unmeasured' <<<"$P4_REMOTE")" = false ] \
  && ok "peer × 429 → and it is NOT unmeasured: a number exists for the current window" \
  || bad "peer × 429 → a filled row is measured, whatever the local probe did (got: $P4_REMOTE)"
! grep -q 'remote@example.com' <<<"$(unmeasured_block <<<"$P4_OUT")" \
  && ok "peer × 429 → the table does not park a borrowed number under UNMEASURED" \
  || bad "peer × 429 → must not be UNMEASURED (got: $P4_OUT)"

# --- 54c. R6 on the bucket rule: cached answers it identically to peer ----------
# The same fixture with the number in the LOCAL cache instead of on the peer. If
# these two ever disagree, `peer` has grown an exemption `cached` does not have,
# which is precisely what R6 forbids.
peer_fixture cached429
cred_json TOK-REMOTE > "$RUN/.claude-pool/remoteseat/.credentials.json"
printf '429' > "$RUN/state/usage-TOK-REMOTE.code"
jq -n --arg wr "$(iso_in +3d)" --arg sr "$(iso_in +2H)" --arg te "$(( $(date +%s) - 600 ))" \
  '{"remote@example.com":{wk_u:"27",wk_r:$wr,se_u:"12",se_r:$sr,ts:"ten minutes ago",ts_epoch:$te}}' \
  > "$RUN/cfg/usage-cache.json"
set +e
C4_OUT="$(FAKE_NEW_EMAIL=local@example.com "$SCRIPT" usage 2>/dev/null)"
C4_JSON="$(FAKE_NEW_EMAIL=local@example.com "$SCRIPT" usage --json 2>/dev/null)"
set -e
C4_REMOTE="$(prow remote@example.com "$C4_JSON")"
[ "$(jq -r '.quota_data' <<<"$C4_REMOTE")" = cached ] \
  && [ "$(jq -r '.unmeasured' <<<"$C4_REMOTE")" = false ] \
  && ok "cached × 429 (R6) → a ten-minute-old cached number is measured too, not UNMEASURED" \
  || bad "cached × 429 (R6) → cached must answer as peer does (got: $C4_REMOTE)"
! grep -q 'remote@example.com' <<<"$(unmeasured_block <<<"$C4_OUT")" \
  && ok "cached × 429 (R6) → and the table agrees, byte for byte with the peer case" \
  || bad "cached × 429 (R6) → must not be UNMEASURED (got: $C4_OUT)"

# ⚠️ AND IT MUST BE ABLE TO FAIL. Same 429, same fixture, NO number from anywhere:
# that row IS unmeasured, and this is the case the 429 arm was written for.
peer_fixture nonum429
cred_json TOK-REMOTE > "$RUN/.claude-pool/remoteseat/.credentials.json"
printf '429' > "$RUN/state/usage-TOK-REMOTE.code"
set +e
N4_OUT="$(FAKE_NEW_EMAIL=local@example.com "$SCRIPT" usage 2>/dev/null)"
N4_JSON="$(FAKE_NEW_EMAIL=local@example.com "$SCRIPT" usage --json 2>/dev/null)"
set -e
[ "$(jq -r '.unmeasured' <<<"$(prow remote@example.com "$N4_JSON")")" = true ] \
  && ok "429 with no number at all → still UNMEASURED, the case that arm was written for" \
  || bad "429 with nothing → must stay unmeasured (got: $(prow remote@example.com "$N4_JSON"))"
grep -q 'remote@example.com' <<<"$(unmeasured_block <<<"$N4_OUT")" \
  && ok "429 with no number at all → and the table files it under UNMEASURED" \
  || bad "429 with nothing → belongs in UNMEASURED (got: $N4_OUT)"

# --- 54d. `--record` versus a peer: the NEWER MEASUREMENT wins ------------------
# `--record` predates peers, so this is the precedence the merge had to decide. A
# hand reading is a measurement like any other: no privilege for having been
# typed, and no demotion for it either. It reaches peer_fill already adopted into
# the `cached` slot with its read_at_epoch, so R4 arbitrates it with no special
# case. Both directions, because a rule that only ever prefers one side is not a
# comparison.
peer_fixture recordbeatspeer
printf '%s' '{"accounts":{}}' > "$RUN/cfg/human-usage.json"
jq --arg wr "$(iso_in +3d)" --argjson te "$(date +%s)" \
   '.accounts["remote@example.com"]={weekly_used:8,weekly_resets_at:$wr,five_hour_used:null,
                                     five_hour_resets_at:null,read_at:"just now",read_at_epoch:$te,
                                     source:"vendor usage page, read by hand"}' \
   "$RUN/cfg/human-usage.json" > "$RUN/cfg/hu.json" && mv "$RUN/cfg/hu.json" "$RUN/cfg/human-usage.json"
peer_json "$(iso_at -2d)" remotealias remote@example.com:73:88 > "$RUN/state/peer-peerbox.json"
R1_JSON="$(ROTA_PEERS=peerbox FAKE_NEW_EMAIL=local@example.com \
           CLAUDE_HUMAN_USAGE="$RUN/cfg/human-usage.json" "$SCRIPT" usage --json 2>/dev/null)"
R1_REMOTE="$(prow remote@example.com "$R1_JSON")"
[ "$(jq -r '.weekly.remaining_pct' <<<"$R1_REMOTE")" = 92 ] \
  && [ "$(jq -r '.quota_data' <<<"$R1_REMOTE")" = cached ] \
  && ok "--record × peer → a reading typed just now beats a two-day-old peer row" \
  || bad "--record × peer → the fresh hand reading must win (got: $R1_REMOTE)"

peer_fixture peerbeatsrecord
printf '%s' '{"accounts":{}}' > "$RUN/cfg/human-usage.json"
jq --arg wr "$(iso_in +3d)" --argjson te "$(( $(date +%s) - 259200 ))" \
   '.accounts["remote@example.com"]={weekly_used:8,weekly_resets_at:$wr,five_hour_used:null,
                                     five_hour_resets_at:null,read_at:"three days ago",read_at_epoch:$te,
                                     source:"vendor usage page, read by hand"}' \
   "$RUN/cfg/human-usage.json" > "$RUN/cfg/hu.json" && mv "$RUN/cfg/hu.json" "$RUN/cfg/human-usage.json"
peer_json "$(iso_at -30S)" remotealias remote@example.com:73:88 > "$RUN/state/peer-peerbox.json"
R2_JSON="$(ROTA_PEERS=peerbox FAKE_NEW_EMAIL=local@example.com \
           CLAUDE_HUMAN_USAGE="$RUN/cfg/human-usage.json" "$SCRIPT" usage --json 2>/dev/null)"
R2_REMOTE="$(prow remote@example.com "$R2_JSON")"
[ "$(jq -r '.weekly.remaining_pct' <<<"$R2_REMOTE")" = 73 ] \
  && [ "$(jq -r '.quota_data' <<<"$R2_REMOTE")" = peer ] \
  && ok "--record × peer → a peer that measured 30s ago beats a three-day-old reading" \
  || bad "--record × peer → the fresher peer must win (got: $R2_REMOTE)"

# ⚠️ AND A LIVE LOCAL FETCH STILL BEATS BOTH. The one rule `--record` shipped
# with ("it never displaces a live fetch") must survive the peer precedence being
# layered under it.
peer_fixture recordneverbeatslive
printf '%s' '{"accounts":{}}' > "$RUN/cfg/human-usage.json"
jq --arg wr "$(iso_in +3d)" --argjson te "$(date +%s)" \
   '.accounts["local@example.com"]={weekly_used:99,weekly_resets_at:$wr,five_hour_used:null,
                                    five_hour_resets_at:null,read_at:"just now",read_at_epoch:$te,
                                    source:"vendor usage page, read by hand"}' \
   "$RUN/cfg/human-usage.json" > "$RUN/cfg/hu.json" && mv "$RUN/cfg/hu.json" "$RUN/cfg/human-usage.json"
R3_JSON="$(FAKE_NEW_EMAIL=local@example.com CLAUDE_HUMAN_USAGE="$RUN/cfg/human-usage.json" \
           "$SCRIPT" usage --json 2>/dev/null)"
R3_LOCAL="$(prow local@example.com "$R3_JSON")"
[ "$(jq -r '.quota_data' <<<"$R3_LOCAL")" = live ] \
  && [ "$(jq -r '.weekly.remaining_pct' <<<"$R3_LOCAL")" = 90 ] \
  && ok "--record × live → a typed 99% used never displaces this run's own measurement" \
  || bad "--record × live → the live fetch must win (got: $R3_LOCAL)"

# --- 57. an EXPIRED access token the API answers 429 for is NOT "shared by live sessions"
# Measured on the pool host 2026-08-30 09:43-09:46: with no live session on the seat
# and 150s of quiet before each call, GET /api/oauth/usage answered 429 to a real
# access token whose expiresAt lay five days in the past, and 401 ("OAuth access
# token is invalid") to a garbage token. So a 429 on a seat whose stored token is
# ALREADY EXPIRED is the vendor refusing an expired token, not per-token rate
# limiting from panes that share it: nothing can be sharing a token that expired
# days ago. The engine used to take the 429 at face value, skip the one refresh
# path it has (the haiku nudge, which makes the CLI rotate the credential), and
# tell the operator to "retry in ~1 min", which never came true. Four of five seats
# sat UNMEASURED for up to five days for exactly this reason.
new_run expiredtoken
mkdir -p "$RUN/.claude-pool/live" "$RUN/.claude-pool/expired" "$RUN/.claude-pool/limited"
cred_json TOK-X-LIVE > "$RUN/.claude/.credentials.json"
cp "$RUN/.claude/.credentials.json" "$RUN/.claude-pool/live/.credentials.json"
printf '{"oauthAccount":{"emailAddress":"live@example.com"}}' > "$RUN/.claude-pool/live/.claude.json"
printf '{"oauthAccount":{"emailAddress":"live@example.com"}}' > "$RUN/.claude.json"
# expired: a COMPLETE credential (refresh token in date) whose ACCESS token expired
# five days ago; the API answers 429 to it, the real shape measured above
printf '{"claudeAiOauth":{"accessToken":"TOK-X-EXPIRED","refreshToken":"RT-TOK-X-EXPIRED","expiresAt":%s000,"refreshTokenExpiresAt":%s000,"scopes":["user:inference"],"subscriptionType":"max"}}' \
  "$(date -u -v-5d +%s)" "$RT_FUTURE" > "$RUN/.claude-pool/expired/.credentials.json"
printf '{"oauthAccount":{"emailAddress":"expired@example.com"}}' > "$RUN/.claude-pool/expired/.claude.json"
printf '429' > "$RUN/state/usage-TOK-X-EXPIRED.code"
# limited: a token still in date that the API 429s, the genuine rate-limit case, must
# keep its old behaviour byte for byte (no nudge, "retry in ~1 min")
cred_json TOK-X-LIMITED > "$RUN/.claude-pool/limited/.credentials.json"
printf '{"oauthAccount":{"emailAddress":"limited@example.com"}}' > "$RUN/.claude-pool/limited/.claude.json"
printf '429' > "$RUN/state/usage-TOK-X-LIMITED.code"
cat > "$RUN/cfg/accounts" <<EOF
live@example.com|$RUN/.claude-pool/live
expired@example.com|$RUN/.claude-pool/expired
limited@example.com|$RUN/.claude-pool/limited
EOF
printf '{"seven_day":{"utilization":10,"resets_at":"%s"},"five_hour":{"utilization":10,"resets_at":"%s"}}' \
  "$(iso_in +2d)" "$(iso_in +2H)" > "$RUN/state/usage-TOK-X-LIVE.json"
run_usage
X_JSON="$(FAKE_NEW_EMAIL=live@example.com "$SCRIPT" usage --json 2>/dev/null)"
X_EXPIRED="$(prow expired@example.com "$X_JSON")"
X_LIMITED="$(prow limited@example.com "$X_JSON")"
[ "$(grep -c '^expired$' "$RUN/state/nudges" 2>/dev/null || echo 0)" -ge 1 ] \
  && ok "expired token × 429 → the seat IS nudged (the CLI is the only thing that rotates a stored token)" \
  || bad "expired token × 429 → must nudge (nudges: $(cat "$RUN/state/nudges" 2>/dev/null || echo none))"
! grep -q '^limited$' "$RUN/state/nudges" 2>/dev/null \
  && ok "expired token × 429 → a token still in date that 429s is NOT nudged (real rate limiting, unchanged)" \
  || bad "expired token × 429 → in-date 429 must not nudge (nudges: $(cat "$RUN/state/nudges"))"
grep -q 'access token expired' <<<"$(jq -r '.stale_reason' <<<"$X_EXPIRED")" \
  && ! grep -q 'live sessions share' <<<"$(jq -r '.stale_reason' <<<"$X_EXPIRED")" \
  && ok "expired token × 429 → the reason names the EXPIRED token, never 'live sessions share this token'" \
  || bad "expired token × 429 → honest reason (got: $(jq -r '.stale_reason' <<<"$X_EXPIRED"))"
grep -q 'live sessions share' <<<"$(jq -r '.stale_reason' <<<"$X_LIMITED")" \
  && ok "expired token × 429 → the in-date 429 keeps its 'retry in ~1 min' reason" \
  || bad "expired token × 429 → in-date reason unchanged (got: $(jq -r '.stale_reason' <<<"$X_LIMITED"))"
grep -qE '^  \? expired@example\.com +stored token stale' <<<"$(unmeasured_block <<<"$OUT")" \
  && ok "expired token × 429 → the table reads 'stored token stale' under UNMEASURED (quota unknown, seat fine), not 'usage API rate-limited'" \
  || bad "expired token × 429 → table row (got: $(unmeasured_block <<<"$OUT"))"
[ "$(jq -r '.unmeasured' <<<"$X_EXPIRED")" = true ] \
  && ok "expired token × 429 → the JSON row is unmeasured, not spent" \
  || bad "expired token × 429 → JSON unmeasured (got: $X_EXPIRED)"
# and the probe itself now goes out under the keeper's User-Agent: under curl's
# default UA the vendor answered 429 to an expired token, under claude-code/2.x
# it answered 401 "OAuth access token has expired" (2026-08-30), which is the
# code the whole stale-token branch was written for
[ "$(cat "$RUN/state/ua-TOK-X-LIVE" 2>/dev/null)" = "claude-code/2.x" ] \
  && ok "usage_fetch → probes with the keeper's User-Agent (claude-code/2.x), one probe shape for both" \
  || bad "usage_fetch → User-Agent (got: $(cat "$RUN/state/ua-TOK-X-LIVE" 2>/dev/null || echo none))"

restore_home
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
