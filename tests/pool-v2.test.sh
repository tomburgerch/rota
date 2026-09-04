#!/usr/bin/env bash
# The `[ … ] && ok … || bad …` assertion shape below is deliberate: ok()/bad()
# only printf + bump a counter (always return 0), so the SC2015 "C may run
# when A is true" caveat cannot bite.
# shellcheck disable=SC2015
#
# pool-v2.test.sh, hermetic suite for the account-pool v2 surfaces (the pool
# v2 design): the shim's identity-verified resolution,
# the failover leaf's reconcile / normalize / pointer switch-all, and the
# pool-keeper daemon (keepalive guards, auto-switch threshold + hysteresis,
# session warming).
#
# Runs the REAL scripts against a throwaway $HOME built under ${TMPDIR:-/tmp}
# with stub `claude`, `security`, `osascript`, `tmux` and `curl` binaries first
# on PATH, a CLAUDE_FAILOVER_PS_CMD fixture for "live processes", and a
# CLAUDE_FAILOVER_USAGE_CMD fixture for the usage API. Nothing here touches a
# real credential, the real Keychain, the real account pool, or the network.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
FAILOVER="$REPO_ROOT/lib/rota-engine.sh"
SHIM="$REPO_ROOT/lib/rota-shim.sh"
KEEPER="$REPO_ROOT/lib/rota-keeper.sh"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'ok   - %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL - %s\n' "$1"; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/pool-v2-test.XXXXXX")"
ROOT="$(cd "$ROOT" && pwd)"
REAL_HOME="$HOME"
cleanup() { export HOME="$REAL_HOME"; rm -rf "$ROOT"; }
trap cleanup EXIT

# ── stubs ────────────────────────────────────────────────────────────────────
STUB_DIR="$ROOT/bin"
mkdir -p "$STUB_DIR"

# fake `claude`: logs every invocation ("<CLAUDE_CONFIG_DIR>|<argv>") and
# models the CLI's nudge-time persistence per FAKE_STATE marker:
#   husk-on-nudge-<base>  rejected refresh: the husk shape overwrites the file
#   kc-on-nudge-<base>    GUI-domain refresh: lands in the per-dir KEYCHAIN
#                         item (kc-live/kc-blob for the dir's service name),
#                         file untouched, the 2026-08-12 first-live-tick shape
#   norotate-<base>       CLI ran but persisted nowhere
#   (default)             rotated + persisted into the FILE: expiresAt += 1h
cat > "$STUB_DIR/claude" <<'STUB'
#!/usr/bin/env bash
st="${FAKE_STATE:-/tmp}"
printf '%s|%s\n' "${CLAUDE_CONFIG_DIR:-UNSET}" "$*" >> "$st/claude-calls"
if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
  base="$(basename "$CLAUDE_CONFIG_DIR")"
  cred="$CLAUDE_CONFIG_DIR/.credentials.json"
  if [ -f "$st/husk-on-nudge-$base" ]; then
    printf '{"claudeAiOauth":{"accessToken":"","refreshToken":"","refreshTokenExpiresAt":1}}' \
      > "$cred"
  elif [ -f "$st/kc-on-nudge-$base" ] && [ -f "$cred" ]; then
    slug="$(printf 'Claude Code-credentials-%s' \
      "$(printf '%s' "$CLAUDE_CONFIG_DIR" | shasum -a 256 | cut -c1-8)" | tr -c 'A-Za-z0-9' '_')"
    jq '.claudeAiOauth.expiresAt = ((.claudeAiOauth.expiresAt // 0) + 3600000)' \
      "$cred" > "$st/kc-blob-$slug" 2>/dev/null
    : > "$st/kc-live-$slug"
  elif [ -f "$st/norotate-$base" ]; then
    :
  elif [ -f "$cred" ]; then
    tmpf="$cred.stub.$$"
    jq '.claudeAiOauth.expiresAt = ((.claudeAiOauth.expiresAt // 0) + 3600000)' \
      "$cred" > "$tmpf" 2>/dev/null && mv "$tmpf" "$cred" || rm -f "$tmpf"
  fi
fi
echo ok
STUB
chmod +x "$STUB_DIR/claude"

# fake `security`: STATEFUL. An item "exists" while $FAKE_STATE/kc-live-<slug>
# exists (its CONTENT, when numeric, is the duplicate count, empty file = 1);
# `-w` serves $FAKE_STATE/kc-blob-<slug>; delete decrements/removes and drops
# a kc-deleted-<slug> marker; every find/delete is logged to kc-calls. No real
# Keychain is ever consulted.
cat > "$STUB_DIR/security" <<'STUB'
#!/usr/bin/env bash
st="${FAKE_STATE:-/tmp}"
svc=""; prev=""; want_w=0
for a in "$@"; do
  [ "$prev" = "-s" ] && svc="$a"
  [ "$a" = "-w" ] && want_w=1
  prev="$a"
done
slug="$(printf '%s' "$svc" | tr -c 'A-Za-z0-9' '_')"
live="$st/kc-live-$slug"
case "${1:-}" in
  find-generic-password)
    printf 'find %s\n' "$slug" >> "$st/kc-calls"
    [ -f "$live" ] || exit 1
    [ "$want_w" = 1 ] && cat "$st/kc-blob-$slug" 2>/dev/null
    exit 0 ;;
  delete-generic-password)
    printf 'delete %s\n' "$slug" >> "$st/kc-calls"
    [ -f "$live" ] || exit 1
    n="$(cat "$live" 2>/dev/null)"
    case "$n" in ''|*[!0-9]*) n=1 ;; esac
    n=$((n - 1))
    if [ "$n" -le 0 ]; then
      rm -f "$live"
      : > "$st/kc-deleted-$slug"
    else
      echo "$n" > "$live"
    fi
    exit 0 ;;
  add-generic-password)    exit 0 ;;
esac
exit 0
STUB
chmod +x "$STUB_DIR/security"

# fake `uname` printing Linux, in its OWN dir: prepended (via
# CLAUDE_KEEPER_PATH_PREFIX) only by the non-Darwin no-op test.
LINUX_DIR="$ROOT/linuxbin"
mkdir -p "$LINUX_DIR"
cat > "$LINUX_DIR/uname" <<'STUB'
#!/usr/bin/env bash
echo Linux
STUB
chmod +x "$LINUX_DIR/uname"

# fake `osascript`: logs the notification text, posts nothing.
cat > "$STUB_DIR/osascript" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FAKE_STATE:-/tmp}/notifications"
exit 0
STUB
chmod +x "$STUB_DIR/osascript"

# fake `tmux`: no session, ever, the panes machinery must be a silent no-op.
cat > "$STUB_DIR/tmux" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
chmod +x "$STUB_DIR/tmux"

# fake `curl`: reads the Bearer token off argv and serves
# $FAKE_STATE/usage-<token>.json + "\n200" when that fixture exists (the old
# suite's shape), else "\n000", a dead socket. Lets a test drive the failover
# leaf's own cache_flush writer without any network.
cat > "$STUB_DIR/curl" <<'STUB'
#!/usr/bin/env bash
token=""; prev=""
for a in "$@"; do
  if [ "$prev" = "-H" ]; then
    case "$a" in Authorization:*) token="${a#Authorization: Bearer }" ;; esac
  fi
  prev="$a"
done
f="${FAKE_STATE:-/nonexistent}/usage-$token.json"
if [ -n "$token" ] && [ -f "$f" ]; then
  printf '%s\n200' "$(cat "$f")"
else
  printf '\n000'
fi
STUB
chmod +x "$STUB_DIR/curl"

# `ps eww -ax` replacement: serves $FAKE_STATE/pool-ps.txt, else a bare header.
# SEQUENCE MODE (stage-2, finding 2): when $FAKE_STATE/pool-ps-seq exists, call
# N serves $FAKE_STATE/pool-ps-<N>.txt instead (missing file → bare header), so
# a test can show a pin only on normalize's POST-swap re-check.
cat > "$STUB_DIR/pool-ps" <<'STUB'
#!/usr/bin/env bash
st="${FAKE_STATE:-/nonexistent}"
if [ -f "$st/pool-ps-seq" ]; then
  n="$(cat "$st/pool-ps-calls" 2>/dev/null || echo 0)"
  n=$((n + 1))
  echo "$n" > "$st/pool-ps-calls"
  f="$st/pool-ps-$n.txt"
  if [ -f "$f" ]; then cat "$f"; else printf 'PID TT STAT TIME COMMAND\n'; fi
  exit 0
fi
f="$st/pool-ps.txt"
if [ -f "$f" ]; then cat "$f"; else printf 'PID TT STAT TIME COMMAND\n'; fi
STUB
chmod +x "$STUB_DIR/pool-ps"

# usage-API replacement for the keeper: `usage-cmd <label> <dir>` serves
# $FAKE_STATE/usage-<label>.json (nothing → no data for that account).
cat > "$STUB_DIR/usage-cmd" <<'STUB'
#!/usr/bin/env bash
f="${FAKE_STATE:-/nonexistent}/usage-$1.json"
[ -f "$f" ] && cat "$f"
exit 0
STUB
chmod +x "$STUB_DIR/usage-cmd"

# the "real" claude binary the SHIM must exec, kept in its OWN dir so the
# shim's CLAUDE_SHIM_DIRS finds exactly this one. Prints the pin it received.
REAL_DIR="$ROOT/realbin"
mkdir -p "$REAL_DIR"
cat > "$REAL_DIR/claude" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "${CLAUDE_CONFIG_DIR:-UNSET}"
STUB
chmod +x "$REAL_DIR/claude"

export PATH="$STUB_DIR:$PATH"
# The keeper re-exports a PATH with the real bin dirs in front (the launchd
# lesson); this prefix keeps the stub dir ahead of them INSIDE the keeper too,
# without it a keeper tick under test would drive the real claude CLI and the
# real `security`.
export CLAUDE_KEEPER_PATH_PREFIX="$STUB_DIR"
export CLAUDE_FAILOVER_PS_CMD="$STUB_DIR/pool-ps"
export CLAUDE_FAILOVER_USAGE_CMD="$STUB_DIR/usage-cmd"
export CLAUDE_FAILOVER_VERIFY_SLEEP=0
export ROTA_TMUX_SESSION="rota-test-none-$$"   # belt for the tmux stub's braces
unset TMUX_PANE CLAUDE_CONFIG_DIR

# ── fixture builders ─────────────────────────────────────────────────────────
EXP_MS=$(( ($(date +%s) + 86400) * 1000 ))          # complete, far-future token
SOON_MS=$(( ($(date +%s) + 600) * 1000 ))           # expiring in 10 min

cred_json() {  # cred_json <token> [exp_ms]
  printf '{"claudeAiOauth":{"accessToken":"%s","refreshToken":"rt-%s","expiresAt":%s,"refreshTokenExpiresAt":%s}}' \
    "$1" "$1" "${2:-$EXP_MS}" "$EXP_MS"
}
husk_json() {
  printf '{"claudeAiOauth":{"accessToken":"","refreshToken":"","refreshTokenExpiresAt":1}}'
}
# The husk shape found LIVE on the always-on box, 2026-08-16: a ~1.1KB file
# that still carries a stale accessToken and scopes, with the
# refreshToken emptied and expiresAt zeroed. Deliberately different from
# husk_json above: `expiresAt` is PRESENT here, so anything that treats it as
# usable has to be caught by the empty refreshToken alone.
live_husk_json() {
  printf '{"claudeAiOauth":{"accessToken":"sk-ant-oat01-%s","refreshToken":"","expiresAt":0,"scopes":["user:inference","user:profile"],"subscriptionType":"max"}}' \
    "$(printf 'x%.0s' $(seq 1 1000))"
}
iso_in() { date -u -v"$1" '+%Y-%m-%dT%H:%M:%S.000000+00:00'; }

ALIASES=(alpha wk team primary)
email_of() { printf '%s@example.com' "$1"; }

# mk_pool <name> [exp_ms], 4 pool dirs, identities matching their aliases,
# complete creds, canonical accounts file (with a comment line reconcile must
# preserve), root claim = alpha, empty shared ~/.claude.
mk_pool() {
  RUN="$ROOT/run.$1"
  local exp="${2:-$EXP_MS}" a
  rm -rf "$RUN"
  mkdir -p "$RUN/.claude" "$RUN/cfg" "$RUN/state"
  {
    printf '# pool accounts, preserved comment line\n'
  } > "$RUN/cfg/accounts"
  for a in "${ALIASES[@]}"; do
    mkdir -p "$RUN/.claude-pool/$a"
    cred_json "TOK-$a" "$exp" > "$RUN/.claude-pool/$a/.credentials.json"
    printf '{"oauthAccount":{"emailAddress":"%s"}}' "$(email_of "$a")" \
      > "$RUN/.claude-pool/$a/.claude.json"
    printf '%s|%s\n' "$(email_of "$a")" "$RUN/.claude-pool/$a" >> "$RUN/cfg/accounts"
  done
  printf '{"oauthAccount":{"emailAddress":"%s"}}' "$(email_of alpha)" > "$RUN/.claude.json"
  export HOME="$RUN" CLAUDE_FAILOVER_HOME="$RUN/cfg" FAKE_STATE="$RUN/state"
  export CLAUDE_FAILOVER_BIN="$FAILOVER"
}

# cross alpha↔wk: each dir holds the OTHER's identity + credential (the shape
# a crossed /login leaves behind, and the 2026-08-11 live incident).
cross_alpha_wk() {
  printf '{"oauthAccount":{"emailAddress":"%s"}}' "$(email_of wk)"    > "$RUN/.claude-pool/alpha/.claude.json"
  printf '{"oauthAccount":{"emailAddress":"%s"}}' "$(email_of alpha)" > "$RUN/.claude-pool/wk/.claude.json"
  cred_json TOK-wk    > "$RUN/.claude-pool/alpha/.credentials.json"
  cred_json TOK-alpha > "$RUN/.claude-pool/wk/.credentials.json"
}

# a ps line with a claude process pinned to <dir>
ps_pin() {  # ps_pin <pid> <dir>
  printf '%s s000 S+ 0:00.42 claude --resume foo TERM=xterm CLAUDE_CONFIG_DIR=%s HOME=%s\n' \
    "$1" "$2" "$RUN"
}

run_keeper() {  # run_keeper [env VAR=... ...], captures OUT/RC
  set +e
  OUT="$(env "$@" bash "$KEEPER" 2>&1)"
  RC=$?
  set -e
}

# ── 1. reconcile ─────────────────────────────────────────────────────────────
mk_pool reconcile
cross_alpha_wk
ACC_BEFORE="$(cat "$RUN/cfg/accounts")"
set +e
OUT="$(bash "$FAILOVER" reconcile 2>&1)"; RC=$?
set -e
[ "$RC" -eq 0 ] && ok "reconcile (bare) → exit 0" || bad "reconcile (bare) → exit 0 (got $RC: $OUT)"
grep -q 'Proposed rewrite' <<<"$OUT" && grep -q -- '--apply' <<<"$OUT" \
  && ok "reconcile (bare) → prints the proposed diff + how to apply it" \
  || bad "reconcile (bare) → proposed diff (got: $OUT)"
[ "$(cat "$RUN/cfg/accounts")" = "$ACC_BEFORE" ] \
  && ok "reconcile (bare) → writes NOTHING" \
  || bad "reconcile (bare) → accounts file changed on a bare run"

set +e
OUT="$(bash "$FAILOVER" reconcile --apply 2>&1)"; RC=$?
set -e
[ "$RC" -eq 0 ] && ok "reconcile --apply → exit 0" || bad "reconcile --apply → exit 0 (got $RC: $OUT)"
grep -q "^$(email_of wk)|$RUN/.claude-pool/alpha\$" "$RUN/cfg/accounts" \
  && grep -q "^$(email_of alpha)|$RUN/.claude-pool/wk\$" "$RUN/cfg/accounts" \
  && ok "reconcile --apply → the swapped mapping is FIXED from dir identities" \
  || bad "reconcile --apply → mapping fixed (got: $(cat "$RUN/cfg/accounts"))"
grep -q '^# pool accounts, preserved comment line$' "$RUN/cfg/accounts" \
  && ok "reconcile --apply → comment lines are preserved" \
  || bad "reconcile --apply → comment preserved (got: $(cat "$RUN/cfg/accounts"))"
grep -q '^# auto-reconciled by rota reconcile at 20' "$RUN/cfg/accounts" \
  && ok "reconcile --apply → appends the timestamped auto-fix comment" \
  || bad "reconcile --apply → auto-fix comment (got: $(cat "$RUN/cfg/accounts"))"
# byte identity of the credentials: reconcile must never move one
cmp -s <(cred_json TOK-wk) "$RUN/.claude-pool/alpha/.credentials.json" \
  && ok "reconcile --apply → not one credential byte moved" \
  || bad "reconcile --apply → a credential changed"
# idempotent second run
set +e
OUT="$(bash "$FAILOVER" reconcile --apply 2>&1)"; RC=$?
set -e
[ "$RC" -eq 0 ] && grep -q 'already matches' <<<"$OUT" \
  && ok "reconcile --apply → second run is a clean no-op" \
  || bad "reconcile --apply → idempotent (got $RC: $OUT)"

# ambiguity: two dirs, one identity → exit 4, no write
mk_pool ambiguous
printf '{"oauthAccount":{"emailAddress":"%s"}}' "$(email_of wk)" > "$RUN/.claude-pool/alpha/.claude.json"
ACC_BEFORE="$(cat "$RUN/cfg/accounts")"
set +e
OUT="$(bash "$FAILOVER" reconcile --apply 2>&1)"; RC=$?
set -e
[ "$RC" -eq 4 ] && ok "reconcile → two dirs holding ONE identity exits 4" \
  || bad "reconcile → ambiguity exit 4 (got $RC: $OUT)"
grep -q 'AMBIGUOUS' <<<"$OUT" && grep -q 'BOTH hold' <<<"$OUT" \
  && ok "reconcile → the ambiguity report names both dirs and the doubled account" \
  || bad "reconcile → ambiguity report (got: $OUT)"
[ "$(cat "$RUN/cfg/accounts")" = "$ACC_BEFORE" ] \
  && ok "reconcile → nothing written on ambiguity" \
  || bad "reconcile → accounts file changed on ambiguity"

# ── 2. normalize ─────────────────────────────────────────────────────────────
mk_pool normpinned
cross_alpha_wk
ps_pin 4242 "$RUN/.claude-pool/alpha" > "$FAKE_STATE/pool-ps.txt"
set +e
OUT="$(bash "$FAILOVER" normalize 2>&1)"; RC=$?
set -e
[ "$RC" -eq 3 ] && ok "normalize → REFUSES (exit 3) while a live process is pinned to either dir" \
  || bad "normalize → pinned refusal exit 3 (got $RC: $OUT)"
grep -q 'REFUSED' <<<"$OUT" && grep -q '4242' <<<"$OUT" \
  && ok "normalize → the refusal names the pinned pid" \
  || bad "normalize → refusal names the pid (got: $OUT)"
grep -q "$(email_of wk)" "$RUN/.claude-pool/alpha/.claude.json" \
  && ok "normalize → nothing moved on refusal" \
  || bad "normalize → files moved despite a pinned process"

mk_pool normfree
cross_alpha_wk
set +e
OUT="$(bash "$FAILOVER" normalize 2>&1)"; RC=$?
set -e
[ "$RC" -eq 0 ] && ok "normalize → swaps when both dirs are process-free (exit 0)" \
  || bad "normalize → free swap exit 0 (got $RC: $OUT)"
grep -q "$(email_of alpha)" "$RUN/.claude-pool/alpha/.claude.json" \
  && grep -q "$(email_of wk)" "$RUN/.claude-pool/wk/.claude.json" \
  && ok "normalize → identities are back in the dirs their names promise" \
  || bad "normalize → identities restored (alpha dir: $(cat "$RUN/.claude-pool/alpha/.claude.json"))"
grep -q 'TOK-alpha' "$RUN/.claude-pool/alpha/.credentials.json" \
  && grep -q 'TOK-wk' "$RUN/.claude-pool/wk/.credentials.json" \
  && ok "normalize → the credential PAIRS moved with their identities" \
  || bad "normalize → credentials swapped back"
grep -q "^$(email_of alpha)|$RUN/.claude-pool/alpha\$" "$RUN/cfg/accounts" \
  && ok "normalize → and the map is reconciled back to canonical afterwards" \
  || bad "normalize → post-swap reconcile (got: $(cat "$RUN/cfg/accounts"))"
if compgen -G "$RUN/.claude-pool/alpha/*.normalize-tmp.*" > /dev/null; then
  bad "normalize → left a *.normalize-tmp.* file behind"
else
  ok "normalize → no temp files left behind"
fi

# nothing to do → clean no-op
set +e
OUT="$(bash "$FAILOVER" normalize 2>&1)"; RC=$?
set -e
[ "$RC" -eq 0 ] && grep -q 'nothing to do' <<<"$OUT" \
  && ok "normalize → healthy pool is a clean no-op" \
  || bad "normalize → healthy no-op (got $RC: $OUT)"

# ── 3. switch-all: the pointer switch ────────────────────────────────────────
mk_pool switch
printf 'STRAY-V1-CREDENTIAL' > "$RUN/.claude/.credentials.json"
: > "$FAKE_STATE/kc-live-Claude_Code_credentials"
HASH8="$(printf '%s' "$RUN/.claude" | shasum -a 256 | cut -c1-8)"
: > "$FAKE_STATE/kc-live-Claude_Code_credentials_$HASH8"
CS_BEFORE="$(cat "$RUN/.claude-pool/wk/.credentials.json")"
set +e
OUT="$(bash "$FAILOVER" switch-all wk 2>&1)"; RC=$?
set -e
[ "$RC" -eq 0 ] && ok "switch-all → exit 0" || bad "switch-all → exit 0 (got $RC: $OUT)"
[ "$(jq -r '.oauthAccount.emailAddress' "$RUN/.claude.json")" = "$(email_of wk)" ] \
  && ok "switch-all → writes the claim (the pointer every shim launch resolves)" \
  || bad "switch-all → claim written (got: $(cat "$RUN/.claude.json"))"
[ ! -e "$RUN/.claude/.credentials.json" ] \
  && ok "switch-all → DELETES the stray shared credential" \
  || bad "switch-all → shared credential still present"
[ -f "$FAKE_STATE/kc-deleted-Claude_Code_credentials" ] \
  && [ -f "$FAKE_STATE/kc-deleted-Claude_Code_credentials_$HASH8" ] \
  && ok "switch-all → deletes BOTH Keychain service-name shapes" \
  || bad "switch-all → keychain shapes deleted ($(find "$FAKE_STATE" -name 'kc-*' -exec basename {} \; | tr '\n' ' '))"
[ "$(cat "$RUN/.claude-pool/wk/.credentials.json")" = "$CS_BEFORE" ] \
  && ok "switch-all → copies NOTHING (the target pool credential is byte-for-byte untouched)" \
  || bad "switch-all → target pool credential changed"
[ ! -d "$RUN/cfg/creds" ] \
  && ok "switch-all → no stash write (creds/ never created)" \
  || bad "switch-all → a stash appeared"
[ ! -f "$FAKE_STATE/claude-calls" ] \
  && ok "switch-all → never execs the claude CLI (verification is file reads)" \
  || bad "switch-all → claude was invoked: $(cat "$FAKE_STATE/claude-calls")"

# husked target → refusal naming the login
mk_pool switchhusk
husk_json > "$RUN/.claude-pool/team/.credentials.json"
set +e
OUT="$(bash "$FAILOVER" switch-all team 2>&1)"; RC=$?
set -e
[ "$RC" -ne 0 ] && grep -q 'needs one browser login' <<<"$OUT" \
  && ok "switch-all → refuses a husked target and names the one login that fixes it" \
  || bad "switch-all → husk refusal (got $RC: $OUT)"
[ "$(jq -r '.oauthAccount.emailAddress' "$RUN/.claude.json")" = "$(email_of alpha)" ] \
  && ok "switch-all → the claim did not move on a refusal" \
  || bad "switch-all → claim moved on refusal"

# ── 3b. restart-by-default flags (2026-08-12) ────────────────────────────────
# Restarting idle panes is now switch-all's DEFAULT. Three contracts:
#   - a BARE switch stays SILENT about an unreachable tmux (no laptop nag) but
#     its success line names the default and the opt-out
#   - --new-only skips the restart entirely (and says so)
#   - --restart-idle is still accepted (FIX 2 below also proves the explicit
#     form is what diagnoses the tmux failure out loud)
mk_pool switchflags
set +e
OUT="$(CLAUDE_FAILOVER_TMUX_BIN=/nonexistent bash "$FAILOVER" switch-all wk 2>&1)"; RC=$?
set -e
[ "$RC" -eq 0 ] && ! grep -q 'tmux' <<<"$OUT" \
  && ok "switch-all (bare) → default restart stays SILENT when tmux is unreachable" \
  || bad "switch-all (bare) → silent default (got $RC: $OUT)"
grep -q 'idle panes (if any) are restarted onto it below (default; --new-only to skip)' <<<"$OUT" \
  && ok "switch-all (bare) → the success line names the default and its opt-out" \
  || bad "switch-all (bare) → success line (got: $OUT)"
set +e
OUT="$(CLAUDE_FAILOVER_TMUX_BIN=/nonexistent bash "$FAILOVER" switch-all alpha --new-only 2>&1)"; RC=$?
set -e
[ "$RC" -eq 0 ] && grep -q -- '--new-only: no panes restarted' <<<"$OUT" \
  && ok "switch-all --new-only → accepted, and says the panes were deliberately left alone" \
  || bad "switch-all --new-only → opt-out (got $RC: $OUT)"

# ── 4. the shim picks the identity-verified dir ──────────────────────────────
mk_pool shim
cross_alpha_wk   # map says alpha→alpha-dir, but alpha's identity lives in wk-dir
set +e
SHIM_OUT="$(CLAUDE_SHIM_DIRS="$REAL_DIR" bash "$SHIM" 2>/dev/null)"; RC=$?
set -e
[ "$RC" -eq 0 ] && ok "shim → exits through the real binary" || bad "shim → exit 0 (got $RC: $SHIM_OUT)"
[ "$SHIM_OUT" = "$RUN/.claude-pool/wk" ] \
  && ok "shim → on mismatch pins the dir that ACTUALLY holds the active identity" \
  || bad "shim → identity-verified pin (got: $SHIM_OUT, wanted $RUN/.claude-pool/wk)"
[ -f "$RUN/cfg/needs-reconcile" ] \
  && ok "shim → touches needs-reconcile so the keeper repairs the map" \
  || bad "shim → needs-reconcile flag missing"

# healthy map → mapped dir, no flag
mk_pool shimok
set +e
SHIM_OUT="$(CLAUDE_SHIM_DIRS="$REAL_DIR" bash "$SHIM" 2>/dev/null)"; RC=$?
set -e
[ "$SHIM_OUT" = "$RUN/.claude-pool/alpha" ] \
  && ok "shim → a healthy map pins the mapped dir exactly as before" \
  || bad "shim → healthy pin (got: $SHIM_OUT)"
[ ! -f "$RUN/cfg/needs-reconcile" ] \
  && ok "shim → no flag when nothing is wrong" \
  || bad "shim → flagged a healthy pool"

# ambiguous identities (two dirs claim alpha) → fall open to the mapped dir + flag
mk_pool shimambig
printf '{"oauthAccount":{"emailAddress":"%s"}}' "$(email_of alpha)" > "$RUN/.claude-pool/wk/.claude.json"
printf '{"oauthAccount":{"emailAddress":"%s"}}' "$(email_of alpha)" > "$RUN/.claude-pool/team/.claude.json"
printf '{"oauthAccount":{"emailAddress":"%s"}}' "$(email_of wk)"    > "$RUN/.claude-pool/alpha/.claude.json"
set +e
SHIM_OUT="$(CLAUDE_SHIM_DIRS="$REAL_DIR" bash "$SHIM" 2>/dev/null)"; RC=$?
set -e
[ "$SHIM_OUT" = "$RUN/.claude-pool/alpha" ] \
  && ok "shim → ambiguous identity match falls open to the mapped dir (current behaviour)" \
  || bad "shim → ambiguous fallback (got: $SHIM_OUT)"
[ -f "$RUN/cfg/needs-reconcile" ] \
  && ok "shim → and still flags needs-reconcile" \
  || bad "shim → ambiguous case not flagged"

# ── 5. keeper: auto-switch threshold + the soonest-reset target policy ───────
usage_fixture() {  # usage_fixture <alias> <weekly-util> <5h-util> <5h-resets-iso ("" = none)> [weekly-resets-iso]
  printf '{"seven_day":{"utilization":%s,"resets_at":"%s"},"five_hour":{"utilization":%s%s}}' \
    "$2" "${5:-$(iso_in +3d)}" "$3" \
    "$([ -n "$4" ] && printf ',"resets_at":"%s"' "$4")" \
    > "$FAKE_STATE/usage-$(email_of "$1").json"
}

keeper_env=(CLAUDE_KEEPER_NOW_HHMM=0200 AUTO_SWITCH_RESTART_IDLE=0)

# THE OPERATOR'S DECISION, 2026-08-16: the target is the SOONEST-EXPIRING account
# that still clears a headroom floor, "always work on the one that expires
# next and burn all those tokens before switching to the one right after".
# The worked example: primary 34% used resetting Thu 20 Aug, wk 6% resetting
# Fri 21, team 49% resetting Fri 21 → PRIMARY. Under the OLD rule (lowest
# utilization) wk won, so this assertion is exactly where the policy changed.
mk_pool k91
usage_fixture alpha   91 50 "$(iso_in +2H)" "$(iso_in +3d)"   # the claim, over the wall
usage_fixture primary 34 10 "$(iso_in +2H)" "$(iso_in +2d)"   # resets FIRST → the pick
usage_fixture wk       6 10 "$(iso_in +2H)" "$(iso_in +3d)"   # emptiest, but resets later
usage_fixture team    49 10 "$(iso_in +2H)" "$(iso_in +3d)"
run_keeper "${keeper_env[@]}"
[ "$RC" -eq 0 ] && ok "keeper → run exits 0" || bad "keeper → exit 0 (got $RC: $OUT)"
grep -q "switch=to:$(email_of primary)" "$RUN/cfg/keeper-status" \
  && ok "keeper → at 91% weekly it auto-switches to the SOONEST-EXPIRING target above the floor (34% used, not the emptiest at 6%)" \
  || bad "keeper → 91% auto-switch soonest-reset pick (status: $(cat "$RUN/cfg/keeper-status"))"
[ "$(jq -r '.oauthAccount.emailAddress' "$RUN/.claude.json")" = "$(email_of primary)" ] \
  && ok "keeper → the switch really landed (claim now the target)" \
  || bad "keeper → claim after auto-switch (got: $(cat "$RUN/.claude.json"))"
[ -f "$RUN/cfg/keeper-last-switch" ] \
  && ok "keeper → records the switch for the 30-min hysteresis" \
  || bad "keeper → keeper-last-switch missing"
grep -q 'Switched to' "$FAKE_STATE/notifications" 2>/dev/null \
  && ok "keeper → notifies ONCE about the switch (osascript path)" \
  || bad "keeper → switch notification missing"

mk_pool k89
usage_fixture alpha   89 50 "$(iso_in +2H)"
usage_fixture wk      40 10 "$(iso_in +2H)"
usage_fixture team    20 10 "$(iso_in +2H)"
usage_fixture primary 70 10 "$(iso_in +2H)"
run_keeper "${keeper_env[@]}"
grep -q 'switch=none' "$RUN/cfg/keeper-status" \
  && ok "keeper → at 89% weekly it does NOT switch" \
  || bad "keeper → 89% no-switch (status: $(cat "$RUN/cfg/keeper-status"))"
[ "$(jq -r '.oauthAccount.emailAddress' "$RUN/.claude.json")" = "$(email_of alpha)" ] \
  && ok "keeper → the claim is untouched below the threshold" \
  || bad "keeper → claim moved below threshold"

# hysteresis: everything above 80% → threshold crossed but NO eligible target
mk_pool knotarget
usage_fixture alpha   95 50 "$(iso_in +2H)"
usage_fixture wk      85 10 "$(iso_in +2H)"
usage_fixture team    90 10 "$(iso_in +2H)"
usage_fixture primary 99 10 "$(iso_in +2H)"
run_keeper "${keeper_env[@]}"
grep -q 'switch=no-target' "$RUN/cfg/keeper-status" \
  && ok "keeper → never switches ONTO an account above 80% (hysteresis ceiling)" \
  || bad "keeper → >80% targets refused (status: $(cat "$RUN/cfg/keeper-status"))"

# ── 5a2. AN UNTOUCHED WINDOW STILL HAS A DEADLINE, AND THIS PICKER SEES IT ───
#
# The usage API answers `resets_at: null` for any weekly window whose
# utilization is 0.0 - i.e. for the seat with a whole untouched week in it. This
# picker fetches the API itself rather than reading `rota usage --json`, so that
# null left `jreset` empty, rota_seat_deadline returned the no-deadline sentinel
# and rota_deadline_beats ranked the seat LAST ("nothing expiring"). Meanwhile
# `rota usage`, `rota billing` and `cl` had learned to rank it by the reset
# projected from the seat's own 7-day cadence, so the unattended 90%-wall switch
# would send him somewhere every interactive surface says is wrong - at 03:00,
# with only the log to explain it afterwards.
#
# primary is untouched (0% used, no reset reported) with a remembered cadence
# putting its next reset ~2 days out; wk has a REAL reset 4 days out. The pick
# must be primary, and the log line must MARK the instant as projected.
proj_cache() {  # proj_cache <alias> <seen-iso>, the row that remembers a seat's cadence
  jq -n --arg e "$(email_of "$1")" --arg wr "$2" \
    '{($e):{wk_u:"12",wk_r:"",se_u:"5",se_r:"",ts:"Sep 04 09:00",ts_epoch:"1",wk_r_seen:$wr}}' \
    > "$RUN/cfg/usage-cache.json"
}
untouched_fixture() {  # untouched_fixture <alias>, the vendor's answer for an unused window
  printf '{"seven_day":{"utilization":0.0,"resets_at":null},"five_hour":{"utilization":0.0,"resets_at":null}}' \
    > "$FAKE_STATE/usage-$(email_of "$1").json"
}
KP_SEEN_EPOCH=$(( $(date -u '+%s') - 5 * 86400 ))
KP_SEEN="$(date -u -r "$KP_SEEN_EPOCH" '+%Y-%m-%dT%H:%M:%S.000000+00:00')"
KP_WANT="$(date -u -r $(( KP_SEEN_EPOCH + 604800 )) '+%Y-%m-%dT%H:%M:%S+00:00')"   # ~2d out
mk_pool kproj
usage_fixture alpha 91 50 "$(iso_in +2H)" "$(iso_in +6d)"   # the claim, over the wall
untouched_fixture primary                                    # 0% used, NO reset reported
usage_fixture wk    40 10 "$(iso_in +2H)" "$(iso_in +4d)"    # a real reset, LATER
usage_fixture team  45 10 "$(iso_in +2H)" "$(iso_in +5d)"
proj_cache primary "$KP_SEEN"
run_keeper "${keeper_env[@]}"
grep -q "switch=to:$(email_of primary)" "$RUN/cfg/keeper-status" \
  && ok "keeper projection → the untouched seat whose week dies FIRST is the pick, not the one with the later real reset" \
  || bad "keeper projection → picks the projected-soonest seat (status: $(cat "$RUN/cfg/keeper-status"), log: $OUT)"
grep -q "resets ~$KP_WANT" <<<"$OUT" \
  && ok "keeper projection → the log line names the projected instant and MARKS it with ~" \
  || bad "keeper projection → log marks the projection (want ~$KP_WANT, got: $OUT)"
grep -q "projected from this seat's own cadence" <<<"$OUT" \
  && ok "keeper projection → and says in words why the API reported none, for whoever reads the log weeks later" \
  || bad "keeper projection → log explains the projection (got: $OUT)"
[ "$(jq -r --arg e "$(email_of primary)" '.[$e].wk_r_seen' "$RUN/cfg/usage-cache.json")" = "$KP_SEEN" ] \
  && ok "keeper projection → the tick's own cache write KEEPS wk_r_seen (it runs every minute; dropping it would erase the memory)" \
  || bad "keeper projection → wk_r_seen survives the keeper's write (got: $(cat "$RUN/cfg/usage-cache.json"))"

# ...and with NOTHING ever seen for that seat the old behaviour is unchanged: no
# cadence to project from, so the untouched seat ranks last and the seat with a
# real reset wins. Nothing is invented.
mk_pool kprojnoseen
usage_fixture alpha 91 50 "$(iso_in +2H)" "$(iso_in +6d)"
untouched_fixture primary
usage_fixture wk    40 10 "$(iso_in +2H)" "$(iso_in +4d)"
usage_fixture team  45 10 "$(iso_in +2H)" "$(iso_in +5d)"
run_keeper "${keeper_env[@]}"
grep -q "switch=to:$(email_of wk)" "$RUN/cfg/keeper-status" \
  && ok "keeper projection → with no remembered cadence the untouched seat still ranks last, exactly as before" \
  || bad "keeper projection → no seen instant means no projection (status: $(cat "$RUN/cfg/keeper-status"), log: $OUT)"
! grep -q 'resets ~' <<<"$OUT" \
  && ok "keeper projection → and no ~ is printed for an instant nobody has" \
  || bad "keeper projection → nothing to mark (got: $OUT)"

# ── 5b. the headroom FLOOR (AUTO_SWITCH_TARGET_MIN_LEFT_PCT, 2026-08-16) ─────
# The soonest reset only wins if the account still has headroom worth burning:
# primary resets first but is 75% spent (25% left, under the 30%-left floor),
# so the pick falls through to the next-soonest that clears it.
mk_pool kfloor
usage_fixture alpha   91 50 "$(iso_in +2H)" "$(iso_in +4d)"   # the claim
usage_fixture primary 75 10 "$(iso_in +2H)" "$(iso_in +1d)"   # soonest, but only 25% left
usage_fixture wk      40 10 "$(iso_in +2H)" "$(iso_in +2d)"   # next-soonest, 60% left
usage_fixture team    10 10 "$(iso_in +2H)" "$(iso_in +3d)"
run_keeper "${keeper_env[@]}"
grep -q "switch=to:$(email_of wk)" "$RUN/cfg/keeper-status" \
  && ok "floor → an account under the 30%-left floor is skipped even though it resets first" \
  || bad "floor → too-spent soonest account excluded (status: $(cat "$RUN/cfg/keeper-status"))"

# and the floor is a KNOB: lower it and the same too-spent account becomes the pick
mk_pool kfloorknob
usage_fixture alpha   91 50 "$(iso_in +2H)" "$(iso_in +4d)"
usage_fixture primary 75 10 "$(iso_in +2H)" "$(iso_in +1d)"
usage_fixture wk      40 10 "$(iso_in +2H)" "$(iso_in +2d)"
usage_fixture team    10 10 "$(iso_in +2H)" "$(iso_in +3d)"
run_keeper "${keeper_env[@]}" AUTO_SWITCH_TARGET_MIN_LEFT_PCT=10
grep -q "switch=to:$(email_of primary)" "$RUN/cfg/keeper-status" \
  && ok "floor → AUTO_SWITCH_TARGET_MIN_LEFT_PCT=10 makes the 75%-spent soonest account eligible again" \
  || bad "floor → floor knob (status: $(cat "$RUN/cfg/keeper-status"))"

# the 80% CEILING still binds under a lowered floor: 85% used clears a 0% floor
# but is still refused, so the later-resetting 60% account wins
mk_pool kceiling
usage_fixture alpha   95 50 "$(iso_in +2H)" "$(iso_in +4d)"
usage_fixture primary 85 10 "$(iso_in +2H)" "$(iso_in +1d)"   # soonest, over the ceiling
usage_fixture wk      60 10 "$(iso_in +2H)" "$(iso_in +2d)"
usage_fixture team    10 10 "$(iso_in +2H)" "$(iso_in +3d)"
run_keeper "${keeper_env[@]}" AUTO_SWITCH_TARGET_MIN_LEFT_PCT=0
grep -q "switch=to:$(email_of wk)" "$RUN/cfg/keeper-status" \
  && ok "ceiling → AUTO_SWITCH_TARGET_MAX_PCT (80) still excludes the soonest account when the floor is opened up" \
  || bad "ceiling → 85% target refused (status: $(cat "$RUN/cfg/keeper-status"))"

# dead-marked and incomplete credentials are still excluded, soonest or not
mk_pool kdeadtarget
husk_json > "$RUN/.claude-pool/primary/.credentials.json"        # incomplete → never a target
mkdir -p "$RUN/cfg/dead-refresh"
CS_CRED="$RUN/.claude-pool/wk/.credentials.json"                 # dead-marked → never a target
printf '%s:%s\n' "$(wc -c < "$CS_CRED" | tr -d ' ')" \
  "$(stat -f %m "$CS_CRED" 2>/dev/null || stat -c %Y "$CS_CRED")" \
  > "$RUN/cfg/dead-refresh/$(email_of wk)"
usage_fixture alpha   95 50 "$(iso_in +2H)" "$(iso_in +4d)"
usage_fixture primary 10 10 "$(iso_in +2H)" "$(iso_in +1d)"      # soonest, but husked
usage_fixture wk      10 10 "$(iso_in +2H)" "$(iso_in +2d)"      # next, but dead-marked
usage_fixture team    10 10 "$(iso_in +2H)" "$(iso_in +3d)"      # the only eligible one
run_keeper "${keeper_env[@]}"
grep -q "switch=to:$(email_of team)" "$RUN/cfg/keeper-status" \
  && ok "target guards → a husked (incomplete) and a dead-marked account are never targets, however soon they reset" \
  || bad "target guards → dead/incomplete exclusion (status: $(cat "$RUN/cfg/keeper-status"))"

# THE LIVE HUSK SHAPE (2026-08-16). On the always-on box one seat's credential
# was a 1173-byte husk, accessToken still there, refreshToken EMPTY, expiresAt
# 0, and on the laptop the same seat's file was MISSING outright. Both are made the most attractive
# targets a picker could see (0% used, soonest resets) and both must still be
# structurally unpickable. NB the dead-refresh marker cannot be leaned on for
# this: it is fingerprint-keyed and stops matching the moment the file is
# rewritten, so `cred_is_complete` is the load-bearing guard (and `fetch_usage`
# short-circuits on the same predicate, so no usage row exists either).
mk_pool khusktarget
live_husk_json > "$RUN/.claude-pool/primary/.credentials.json"   # the always-on box's shape
rm -f "$RUN/.claude-pool/wk/.credentials.json"                    # the laptop's shape
HUSK_BEFORE="$(cat "$RUN/.claude-pool/primary/.credentials.json")"
usage_fixture alpha   95 50 "$(iso_in +2H)" "$(iso_in +4d)"
usage_fixture primary  0  0 "$(iso_in +2H)" "$(iso_in +1d)"      # soonest + emptiest, but husked
usage_fixture wk       0  0 "$(iso_in +2H)" "$(iso_in +2d)"      # next-soonest, but file GONE
usage_fixture team    10 10 "$(iso_in +2H)" "$(iso_in +3d)"      # the only real candidate
run_keeper "${keeper_env[@]}"
grep -q "switch=to:$(email_of team)" "$RUN/cfg/keeper-status" \
  && [ "$(jq -r '.oauthAccount.emailAddress' "$RUN/.claude.json")" = "$(email_of team)" ] \
  && ok "target guards → the live husk shape (empty refreshToken, expiresAt 0) and a MISSING credential file are never auto-switch targets" \
  || bad "target guards → husked/missing target (status: $(cat "$RUN/cfg/keeper-status"))"
[ "$(cat "$RUN/.claude-pool/primary/.credentials.json")" = "$HUSK_BEFORE" ] \
  && [ ! -e "$RUN/.claude-pool/wk/.credentials.json" ] \
  && ok "target guards → and neither the husk nor the missing file is written to (a re-login is the only fix)" \
  || bad "target guards → husk/missing file touched (primary: $(head -c 60 "$RUN/.claude-pool/primary/.credentials.json"); wk: $(ls "$RUN/.claude-pool/wk" 2>/dev/null | tr '\n' ' '))"

# the bounce hysteresis still blocks the pick outright (no second-best fallback)
mk_pool kbounce
usage_fixture alpha   95 50 "$(iso_in +2H)" "$(iso_in +4d)"
usage_fixture primary 10 10 "$(iso_in +2H)" "$(iso_in +1d)"      # the pick…
usage_fixture wk      20 10 "$(iso_in +2H)" "$(iso_in +2d)"
usage_fixture team    30 10 "$(iso_in +2H)" "$(iso_in +3d)"
printf '%s %s %s\n' "$(date +%s)" "$(email_of alpha)" "$(email_of primary)" \
  > "$RUN/cfg/keeper-last-switch"                                # …is the one we just left
run_keeper "${keeper_env[@]}"
grep -q 'bounce hysteresis' <<<"$OUT" \
  && grep -q 'switch=no-target' "$RUN/cfg/keeper-status" \
  && [ "$(jq -r '.oauthAccount.emailAddress' "$RUN/.claude.json")" = "$(email_of alpha)" ] \
  && ok "bounce → AUTO_SWITCH_BOUNCE_SECS still blocks a switch back to the account just left" \
  || bad "bounce → hysteresis (status: $(cat "$RUN/cfg/keeper-status"); out: $OUT)"
run_keeper "${keeper_env[@]}" AUTO_SWITCH_BOUNCE_SECS=0
grep -q "switch=to:$(email_of primary)" "$RUN/cfg/keeper-status" \
  && ok "bounce → and it is a knob: AUTO_SWITCH_BOUNCE_SECS=0 lets the same pick through" \
  || bad "bounce → knob (status: $(cat "$RUN/cfg/keeper-status"))"

# ── 5c. ONE RANKING: the keeper and the engine must name the SAME seat ───────
#
# rota has TWO pickers - the engine's compute_recommendation behind
# `rota usage` / `rota switch`, and this keeper's unattended auto-switch at the
# 90% wall. They were kept in step BY CONVENTION, each carrying a comment saying
# the other ranked the same way. Convention failed the moment one of them
# learned something: on 2026-08-27 the engine moved to min(weekly reset, SEAT
# END) and the keeper did not, so for a CANCELLED seat whose end date falls
# before its next weekly reset the two named DIFFERENT seats. That shape was
# live on the real pool within days (tartare@ ending 1 Sep and thea.hawk@ ending
# 6 Sep, both with their quota resetting first). A picker that disagrees with
# ITSELF is worse than either rule: neither answer can be trusted without
# knowing which code path produced it.
#
# Both now call rota_seat_deadline + rota_deadline_beats (lib/rota-ranking.sh),
# and these scenarios are what stops the two drifting again. THE ASSERTION IS
# AGREEMENT, not "the keeper picks X": a test that only pinned one side would go
# green again the moment the other side moved.
#
# ONE set of numbers is served to BOTH pickers - the keeper reads them through
# its CLAUDE_FAILOVER_USAGE_CMD stub (keyed by EMAIL), the engine through the
# curl stub (keyed by the seat's access TOKEN). Same bytes in both files, so any
# disagreement is the ranking and never the input.
pair_fixture() {  # pair_fixture <alias> <weekly-util> <5h-util> <5h-reset-iso> <weekly-reset-iso ("" = fresh)>
  local wkr body
  # a FRESH weekly window is resets_at:null, the API's own shape for "this
  # window has not started"; an empty string here would be a third state neither
  # picker has ever seen.
  if [ -n "${5:-}" ]; then wkr="\"$5\""; else wkr=null; fi
  body="$(printf '{"seven_day":{"utilization":%s,"resets_at":%s},"five_hour":{"utilization":%s,"resets_at":"%s"}}' \
    "$2" "$wkr" "$3" "$4")"
  printf '%s' "$body" > "$FAKE_STATE/usage-$(email_of "$1").json"
  printf '%s' "$body" > "$FAKE_STATE/usage-TOK-$1.json"
}

# billing.json in $RUN/cfg, i.e. at the DEFAULT path both scripts resolve from
# $CFG_DIR. Passing it by env would prove less: the keeper had never read this
# file before, so "does it find it where the engine finds it" is part of the claim.
seat_fixture() {  # seat_fixture [<alias>:<status>:<ends-date> ...]
  local spec entries="" a
  for spec in "$@"; do
    a="${spec%%:*}"; spec="${spec#*:}"
    entries="$entries$(printf '"%s":{"plan":"Max 20x","status":"%s","ends":"%s"},' \
      "$(email_of "$a")" "${spec%%:*}" "${spec#*:}")"
  done
  printf '{"accounts":{%s}}' "${entries%,}" > "$RUN/cfg/billing.json"
}

# The alias the ENGINE's own picker names, straight out of the surface a human
# reads (`rota usage`), not a re-derivation.
engine_pick() {
  local j
  set +e
  j="$(bash "$FAILOVER" usage --json 2>/dev/null)"
  set -e
  jq -r '.recommendation.alias // ""' <<<"$j" 2>/dev/null
}
keeper_pick() {  # the alias the KEEPER switched to this tick, or ""
  sed -n 's/.*switch=to:\([^@ ]*\)@example\.com.*/\1/p' "$RUN/cfg/keeper-status" 2>/dev/null
}

# THE SHAPE THE WHOLE TASK EXISTS FOR: a cancelled seat whose END DATE precedes
# its weekly reset. Separated by construction, so the two rules cannot both be
# right:
#   wk    CANCELLED, ends in 2 DAYS, weekly resets in 6 DAYS  -> deadline +2d
#   team  active,                    weekly resets in 3 DAYS  -> deadline +3d
# Ranking on the weekly reset alone picks TEAM; ranking on min(reset, seat end)
# picks WK, correctly - whatever is unspent on wk in two days is gone forever,
# while team's window merely rolls.
mk_pool kagree
pair_fixture alpha   91 50 "$(iso_in +2H)" "$(iso_in +4d)"   # the claim, over the wall
pair_fixture wk      40 10 "$(iso_in +2H)" "$(iso_in +6d)"   # ends first, resets LAST
pair_fixture team    40 10 "$(iso_in +2H)" "$(iso_in +3d)"   # resets first, never ends
pair_fixture primary 40 10 "$(iso_in +2H)" "$(iso_in +5d)"
seat_fixture "wk:cancelled:$(date -u -v+2d '+%Y-%m-%d')"
EP="$(engine_pick)"
run_keeper "${keeper_env[@]}"
KP="$(keeper_pick)"
[ -n "$EP" ] && [ "$EP" = "$KP" ] \
  && ok "one ranking → keeper and engine name the SAME seat for a cancelled seat ending before its reset (both: ${EP:-none})" \
  || bad "one ranking → the two pickers disagree (engine: ${EP:-none}, keeper: ${KP:-none})"
[ "$EP" = wk ] \
  && ok "one ranking → and the seat they agree on is the one that ENDS first, not the one that resets first" \
  || bad "one ranking → min(weekly reset, seat end) must pick wk (engine: ${EP:-none}, keeper: ${KP:-none})"
grep -q 'seat ENDS' "$RUN/cfg/keeper.log" \
  && ok "one ranking → the keeper's log names the SEAT END as the reason, not a reset it did not use" \
  || bad "one ranking → keeper log names the binding date (log: $(grep auto-switch "$RUN/cfg/keeper.log" | tail -1))"

# THE ORDINARY CASE, and it has to be able to fail differently: the same seat is
# still cancelled, but now its end is FAR (10 days) and its reset is near (2
# days), so the deadline is its RESET. If min() were reading the seat end here,
# wk would rank last (+10d) and team (+3d) would win, so this pins the min()
# rather than a blanket "cancelled seats first".
mk_pool kagreereset
pair_fixture alpha   91 50 "$(iso_in +2H)" "$(iso_in +4d)"
pair_fixture wk      40 10 "$(iso_in +2H)" "$(iso_in +2d)"   # resets first, ends far away
pair_fixture team    40 10 "$(iso_in +2H)" "$(iso_in +3d)"
pair_fixture primary 40 10 "$(iso_in +2H)" "$(iso_in +5d)"
seat_fixture "wk:cancelled:$(date -u -v+10d '+%Y-%m-%d')"
EP="$(engine_pick)"
run_keeper "${keeper_env[@]}"
KP="$(keeper_pick)"
[ "$EP" = wk ] && [ "$KP" = wk ] \
  && ok "one ranking → a seat whose RESET precedes its end still ranks on the reset, and both pickers agree" \
  || bad "one ranking → reset-bound pick (engine: ${EP:-none}, keeper: ${KP:-none})"
! grep -q 'seat ENDS' "$RUN/cfg/keeper.log" \
  && ok "one ranking → and the log calls it a reset when the reset is what bound it" \
  || bad "one ranking → reset-bound pick must not claim a seat end (log: $(grep auto-switch "$RUN/cfg/keeper.log" | tail -1))"

# ⚠️ THE "NOTHING IS EXPIRING" SENTINEL MUST RANK LAST, NEVER FIRST. It is the
# empty string, and an empty string sorts BEFORE every real ISO timestamp under
# a string compare, so the healthiest seat in the pool would otherwise be
# recommended as the most urgent. wk here has no weekly reset instant at all (a
# window that has not started) and no end date, so it must lose to team's real
# +3d deadline in BOTH pickers.
mk_pool kfresh
pair_fixture alpha   91 50 "$(iso_in +2H)" "$(iso_in +4d)"
pair_fixture wk      40 10 "$(iso_in +2H)" ""                # fresh: nothing expiring
pair_fixture team    40 10 "$(iso_in +2H)" "$(iso_in +3d)"   # a real deadline
pair_fixture primary 40 10 "$(iso_in +2H)" "$(iso_in +5d)"
seat_fixture "alpha:active:"
EP="$(engine_pick)"
run_keeper "${keeper_env[@]}"
KP="$(keeper_pick)"
[ "$EP" = team ] && [ "$KP" = team ] \
  && ok "sentinel → a seat with NO deadline ranks LAST in both pickers, never ahead of a real one" \
  || bad "sentinel → fresh seat must not win (engine: ${EP:-none}, keeper: ${KP:-none})"

# ⚠️ AN EXACT TIE ON THE DEADLINE GOES TO THE LOWEST UTILIZATION. This is the
# keeper's older rule, kept as the tie-break so the pick stays deterministic
# where the newer policy is silent. Without it the tie falls to whatever order
# the accounts file happens to list, which is not a rule anyone chose: wk is
# listed BEFORE team here, so a first-wins tie would name wk.
mk_pool ktie
TIE_RESET="$(iso_in +3d)"
pair_fixture alpha   91 50 "$(iso_in +2H)" "$(iso_in +4d)"
pair_fixture wk      60 10 "$(iso_in +2H)" "$TIE_RESET"      # listed first, but emptier
pair_fixture team    40 10 "$(iso_in +2H)" "$TIE_RESET"      # same instant, more left
pair_fixture primary 40 10 "$(iso_in +2H)" "$(iso_in +5d)"
seat_fixture "alpha:active:"
EP="$(engine_pick)"
run_keeper "${keeper_env[@]}"
KP="$(keeper_pick)"
[ "$EP" = team ] && [ "$KP" = team ] \
  && ok "tie-break → an exact deadline tie goes to the LOWEST utilization in both pickers, not to accounts-file order" \
  || bad "tie-break → lowest utilization on a tie (engine: ${EP:-none}, keeper: ${KP:-none})"

# ── 6. keeper: keepalive is OFF by default (2026-08-16) ──────────────────────
# It husked 23 credential files across two machines in one day and verified
# not one rotation (~201 attempts), so step 2 is a no-op unless
# KEEPALIVE_ENABLED=1. Steps 1/3/4 must be entirely unaffected by the knob.
mk_pool kaoff "$SOON_MS"                                   # every token expiring in 10 min
usage_fixture alpha   91 50 "$(iso_in +2H)" "$(iso_in +3d)"
usage_fixture primary 34 10 "$(iso_in +2H)" "$(iso_in +2d)"
usage_fixture wk       6 10 "$(iso_in +2H)" "$(iso_in +3d)"
usage_fixture team    49 10 "$(iso_in +2H)" "$(iso_in +3d)"
run_keeper "${keeper_env[@]}"
[ ! -f "$FAKE_STATE/claude-calls" ] \
  && ok "keepalive-off → NOT ONE nudge is attempted, even with every token 10 min from expiry" \
  || bad "keepalive-off → nudged anyway (calls: $(cat "$FAKE_STATE/claude-calls" 2>/dev/null))"
grep -q 'nudged=0' "$RUN/cfg/keeper-status" \
  && ok "keepalive-off → status counts zero nudges" \
  || bad "keepalive-off → nudged=0 (status: $(cat "$RUN/cfg/keeper-status"))"
[ "$(grep -c 'keepalive: DISABLED' "$RUN/cfg/keeper.log")" -eq 1 ] \
  && grep -q '23 husked credential files' "$RUN/cfg/keeper.log" \
  && ok "keepalive-off → says ONCE why it is off, with the measured evidence" \
  || bad "keepalive-off → the off notice (log: $(grep 'keepalive' "$RUN/cfg/keeper.log" 2>/dev/null || echo none))"
grep -q 'fetched=4' "$RUN/cfg/keeper-status" \
  && ok "keepalive-off → step 3 (usage) still runs for every account" \
  || bad "keepalive-off → usage fetch (status: $(cat "$RUN/cfg/keeper-status"))"
grep -q "switch=to:$(email_of primary)" "$RUN/cfg/keeper-status" \
  && ok "keepalive-off → step 4 (auto-switch) still runs and picks the soonest-expiring target" \
  || bad "keepalive-off → auto-switch still runs (status: $(cat "$RUN/cfg/keeper-status"))"
run_keeper "${keeper_env[@]}"
[ "$(grep -c 'keepalive: DISABLED' "$RUN/cfg/keeper.log")" -eq 1 ] \
  && ok "keepalive-off → and it does NOT repeat the notice every tick (log_once)" \
  || bad "keepalive-off → notice repeated $(grep -c 'keepalive: DISABLED' "$RUN/cfg/keeper.log") times"

# KEEPALIVE_ENABLED=1 restores the old behaviour, knob-only
run_keeper "${keeper_env[@]}" KEEPALIVE_ENABLED=1
[ -f "$FAKE_STATE/claude-calls" ] \
  && [ "$(grep -c '' "$FAKE_STATE/claude-calls")" -eq 4 ] \
  && grep -q 'nudged=4' "$RUN/cfg/keeper-status" \
  && ok "keepalive-on → KEEPALIVE_ENABLED=1 nudges every expiring chain again" \
  || bad "keepalive-on → nudges restored (calls: $(cat "$FAKE_STATE/claude-calls" 2>/dev/null || echo none))"
run_keeper "${keeper_env[@]}"
[ "$(grep -c 'keepalive: DISABLED' "$RUN/cfg/keeper.log")" -eq 2 ] \
  && ok "keepalive-off → the notice re-arms after an enabled tick (state-change logging)" \
  || bad "keepalive-off → re-arm ($(grep -c 'keepalive: DISABLED' "$RUN/cfg/keeper.log") notices)"

# ── 6b. keeper: keepalive nudge guards (KEEPALIVE_ENABLED=1) ─────────────────
mk_pool nudges "$SOON_MS"          # every token expiring in 10 min
husk_json > "$RUN/.claude-pool/alpha/.credentials.json"          # (a) incomplete → skip
mkdir -p "$RUN/cfg/dead-refresh"                                 # (b) dead-marked → skip
CS_CRED="$RUN/.claude-pool/wk/.credentials.json"
printf '%s:%s\n' "$(wc -c < "$CS_CRED" | tr -d ' ')" \
  "$(stat -f %m "$CS_CRED" 2>/dev/null || stat -c %Y "$CS_CRED")" \
  > "$RUN/cfg/dead-refresh/$(email_of wk)"
ps_pin 777 "$RUN/.claude-pool/primary" > "$FAKE_STATE/pool-ps.txt"   # (c) live pinned → skip
usage_fixture team 10 10 "$(iso_in +2H)"                         # (d) team: healthy → nudge
run_keeper "${keeper_env[@]}" KEEPALIVE_ENABLED=1
grep -c "claude-pool/team|" "$FAKE_STATE/claude-calls" >/dev/null 2>&1 \
  && [ "$(grep -c '' "$FAKE_STATE/claude-calls")" -eq 1 ] \
  && grep -q "claude-pool/team|" "$FAKE_STATE/claude-calls" \
  && ok "keeper → nudges ONLY the healthy expiring chain (husk, dead-marked and live-pinned all skipped)" \
  || bad "keeper → nudge guards (calls: $(cat "$FAKE_STATE/claude-calls" 2>/dev/null || echo none))"
grep -q 'nudged=1' "$RUN/cfg/keeper-status" \
  && ok "keeper → status counts exactly one nudge" \
  || bad "keeper → nudged=1 (status: $(cat "$RUN/cfg/keeper-status"))"

# husk-after-nudge: refresh rejected → dead marker + one notification
mk_pool nudgehusk "$SOON_MS"
husk_json > "$RUN/.claude-pool/alpha/.credentials.json"
husk_json > "$RUN/.claude-pool/wk/.credentials.json"
husk_json > "$RUN/.claude-pool/primary/.credentials.json"
: > "$FAKE_STATE/husk-on-nudge-team"
run_keeper "${keeper_env[@]}" KEEPALIVE_ENABLED=1
[ -f "$RUN/cfg/dead-refresh/$(email_of team)" ] \
  && ok "keeper → a nudge that husks the file marks the chain dead-refresh" \
  || bad "keeper → dead marker after husking nudge"
grep -q 'needs a re-login' "$FAKE_STATE/notifications" 2>/dev/null \
  && ok "keeper → and notifies that a re-login is the only fix" \
  || bad "keeper → husk notification missing"
CALLS_BEFORE="$(grep -c '' "$FAKE_STATE/claude-calls" 2>/dev/null || echo 0)"
run_keeper "${keeper_env[@]}" KEEPALIVE_ENABLED=1
[ "$(grep -c '' "$FAKE_STATE/claude-calls" 2>/dev/null || echo 0)" -eq "$CALLS_BEFORE" ] \
  && ok "keeper → the dead-marked chain is never nudged again (no heal→gut loop)" \
  || bad "keeper → re-nudged a dead chain"

# ── 7. keeper: session warming ───────────────────────────────────────────────
warm_env=(CLAUDE_KEEPER_NOW_HHMM=0400 AUTO_SWITCH_RESTART_IDLE=0)

mk_pool warm                        # far-future tokens: keepalive stays quiet
usage_fixture alpha   10 0  ""                    # five-hour COLD → warm it
usage_fixture wk      10 30 "$(iso_in +2H)"       # spending → open, skip
usage_fixture team    10 0  "$(iso_in +2H)"       # 0 but future reset → open, skip
husk_json > "$RUN/.claude-pool/primary/.credentials.json"   # husked → skip
run_keeper "${warm_env[@]}"
[ -f "$FAKE_STATE/claude-calls" ] \
  && [ "$(grep -c '' "$FAKE_STATE/claude-calls")" -eq 1 ] \
  && grep -q "claude-pool/alpha|" "$FAKE_STATE/claude-calls" \
  && ok "warming → exactly ONE nudge, to the one account whose 5h window is closed" \
  || bad "warming → cold-only nudge (calls: $(cat "$FAKE_STATE/claude-calls" 2>/dev/null || echo none))"
grep -q 'warmed=1' "$RUN/cfg/keeper-status" \
  && ok "warming → status reports warmed=1" \
  || bad "warming → warmed=1 (status: $(cat "$RUN/cfg/keeper-status"))"
ls "$RUN/cfg"/warmed-* >/dev/null 2>&1 \
  && ok "warming → writes the warmed-<date> marker" \
  || bad "warming → marker missing"
run_keeper "${warm_env[@]}"
[ "$(grep -c '' "$FAKE_STATE/claude-calls")" -eq 1 ] \
  && ok "warming → the second tick of the day warms NOTHING (marker holds)" \
  || bad "warming → warmed twice in one day (calls: $(cat "$FAKE_STATE/claude-calls"))"

# before WARM_AT nothing fires
mk_pool warmearly
usage_fixture alpha 10 0 ""
run_keeper CLAUDE_KEEPER_NOW_HHMM=0200 AUTO_SWITCH_RESTART_IDLE=0
[ ! -f "$FAKE_STATE/claude-calls" ] \
  && ok "warming → before WARM_AT (03:00) nothing is warmed" \
  || bad "warming → fired before WARM_AT (calls: $(cat "$FAKE_STATE/claude-calls"))"
ls "$RUN/cfg"/warmed-* >/dev/null 2>&1 \
  && bad "warming → marker written before WARM_AT" \
  || ok "warming → no marker before WARM_AT"

# WARM_ACCOUNTS=active warms only the claim's account
mk_pool warmactive
printf 'WARM_ACCOUNTS=active\n' > "$RUN/cfg/keeper.conf"
usage_fixture alpha 10 0 ""       # active (claim) + cold → warm
usage_fixture wk    10 0 ""       # cold too, but NOT the active account
run_keeper "${warm_env[@]}"
[ -f "$FAKE_STATE/claude-calls" ] \
  && [ "$(grep -c '' "$FAKE_STATE/claude-calls")" -eq 1 ] \
  && grep -q "claude-pool/alpha|" "$FAKE_STATE/claude-calls" \
  && ok "warming → WARM_ACCOUNTS=active warms only the active account" \
  || bad "warming → active-only (calls: $(cat "$FAKE_STATE/claude-calls" 2>/dev/null || echo none))"

# A seat whose stored ACCESS token has already expired can produce no usage data
# until something refreshes it, and with keepalive off the warm nudge IS the only
# thing that does. The old "no usage data → undecided → retry next tick" rule met
# that seat with a loop: no data because the token is expired, no nudge because
# there is no data, 144 log lines a day and the seat unmeasurable for five days
# (the pool host, 2026-08-25 → 08-30, four seats). Expired + no data = COLD, and
# it gets its one nudge; every guard inside nudge_account still applies.
mk_pool warmexpired
usage_fixture wk      10 30 "$(iso_in +2H)"       # open, skip
usage_fixture team    10 30 "$(iso_in +2H)"       # open, skip
usage_fixture primary 10 30 "$(iso_in +2H)"       # open, skip
printf '{"claudeAiOauth":{"accessToken":"TOK-alpha","refreshToken":"rt-TOK-alpha","expiresAt":%s,"refreshTokenExpiresAt":%s}}' \
  "$(( ($(date +%s) - 5 * 86400) * 1000 ))" "$EXP_MS" > "$RUN/.claude-pool/alpha/.credentials.json"
# NO usage fixture for alpha: the API will not answer an expired token
run_keeper "${warm_env[@]}"
[ -f "$FAKE_STATE/claude-calls" ] \
  && [ "$(grep -c '' "$FAKE_STATE/claude-calls")" -eq 1 ] \
  && grep -q "claude-pool/alpha|" "$FAKE_STATE/claude-calls" \
  && ok "warming → a seat with NO usage data and an EXPIRED access token is nudged (it is cold by construction)" \
  || bad "warming → expired-token seat nudged (calls: $(cat "$FAKE_STATE/claude-calls" 2>/dev/null || echo none))"
grep -q 'warmed=1' "$RUN/cfg/keeper-status" \
  && ok "warming → and counts as warmed, not as 'retry'" \
  || bad "warming → warmed=1 (status: $(cat "$RUN/cfg/keeper-status"))"
ls "$RUN/cfg"/warmed-* >/dev/null 2>&1 \
  && ok "warming → the day's marker is stamped, no 144-line retry loop" \
  || bad "warming → marker missing after the expired-token nudge"
grep -q 'access token expired' "$RUN/cfg/keeper.log" \
  && ok "warming → the log names WHY the seat was nudged (expired access token)" \
  || bad "warming → log reason (got: $(grep 'warm' "$RUN/cfg/keeper.log" | tail -3))"

# a RESERVED seat with an expired token: decided (marker stamps), never nudged.
# Its chain is also held on the owner's box; see seat_is_reserved in rota-ranking.sh.
mk_pool warmreserved
usage_fixture wk      10 30 "$(iso_in +2H)"       # open, skip
usage_fixture team    10 30 "$(iso_in +2H)"       # open, skip
usage_fixture primary 10 30 "$(iso_in +2H)"       # open, skip
printf '{"claudeAiOauth":{"accessToken":"TOK-alpha","refreshToken":"rt-TOK-alpha","expiresAt":%s,"refreshTokenExpiresAt":%s}}' \
  "$(( ($(date +%s) - 5 * 86400) * 1000 ))" "$EXP_MS" > "$RUN/.claude-pool/alpha/.credentials.json"
touch "$RUN/.claude-pool/alpha/RESERVED"
run_keeper "${warm_env[@]}"
! grep -q "claude-pool/alpha|" "$FAKE_STATE/claude-calls" 2>/dev/null \
  && ok "warming → a RESERVED seat with an expired token is NOT nudged (its owner's box rotates the chain)" \
  || bad "warming → reserved seat nudged (calls: $(cat "$FAKE_STATE/claude-calls" 2>/dev/null || echo none))"
ls "$RUN/cfg"/warmed-* >/dev/null 2>&1 \
  && ok "warming → and the day's marker still stamps: reserved is DECIDED, not undecided" \
  || bad "warming → marker missing for a reserved seat (status: $(cat "$RUN/cfg/keeper-status"))"
grep -q 'reserved seat' "$RUN/cfg/keeper.log" \
  && ok "warming → the log says WHY it was skipped (reserved seat)" \
  || bad "warming → log reason (got: $(grep 'warm' "$RUN/cfg/keeper.log" | tail -3))"

# ── 8. the reconcile→normalize COMPOSITION (stage-1 review, finding 1) ───────
# reconcile --apply rewrites the labels to match the dirs, which destroys the
# label-mismatch evidence normalize's own detection needs. The pending record
# is what survives, these tests pin the exact composition that was broken.
mk_pool compose
cross_alpha_wk
set +e
OUT="$(bash "$FAILOVER" reconcile --apply 2>&1)"; RC=$?
set -e
[ "$RC" -eq 0 ] && [ -f "$RUN/cfg/normalize-pending" ] \
  && ok "compose → reconcile --apply records the crossed pair in normalize-pending" \
  || bad "compose → pending record written (got $RC: $OUT)"
grep -q "$RUN/.claude-pool/alpha|$(email_of wk)|$RUN/.claude-pool/wk|$(email_of alpha)" "$RUN/cfg/normalize-pending" \
  && ok "compose → the record names both dirs and the identity each holds NOW" \
  || bad "compose → record content (got: $(cat "$RUN/cfg/normalize-pending"))"
# now the map matches the dirs, the old detection alone would dead-end here
set +e
OUT="$(bash "$FAILOVER" normalize 2>&1)"; RC=$?
set -e
[ "$RC" -eq 0 ] && ok "compose → normalize AFTER reconcile still exits 0" \
  || bad "compose → post-reconcile normalize (got $RC: $OUT)"
grep -q "$(email_of alpha)" "$RUN/.claude-pool/alpha/.claude.json" \
  && grep -q 'TOK-alpha' "$RUN/.claude-pool/alpha/.credentials.json" \
  && ok "compose → the pair is PHYSICALLY swapped back (identity + credential)" \
  || bad "compose → pair swapped (alpha dir: $(cat "$RUN/.claude-pool/alpha/.claude.json"))"
[ ! -f "$RUN/cfg/normalize-pending" ] \
  && ok "compose → the pending record is cleared on success" \
  || bad "compose → pending record still present"
grep -q "^$(email_of alpha)|$RUN/.claude-pool/alpha\$" "$RUN/cfg/accounts" \
  && ok "compose → and the map is back to canonical" \
  || bad "compose → canonical map (got: $(cat "$RUN/cfg/accounts"))"

# pinned: the pending record must SURVIVE an exit-3 refusal for the next try
mk_pool composepin
cross_alpha_wk
set +e
bash "$FAILOVER" reconcile --apply >/dev/null 2>&1
ps_pin 555 "$RUN/.claude-pool/alpha" > "$FAKE_STATE/pool-ps.txt"
OUT="$(bash "$FAILOVER" normalize 2>&1)"; RC=$?
set -e
[ "$RC" -eq 3 ] && [ -f "$RUN/cfg/normalize-pending" ] \
  && ok "compose → a pinned refusal keeps the pending record for the next attempt" \
  || bad "compose → pending survives exit 3 (got $RC, pending: $(ls "$RUN/cfg/normalize-pending" 2>/dev/null || echo gone))"
rm -f "$FAKE_STATE/pool-ps.txt"

# pending pair already put right by hand → record cleared, nothing moved.
# The record claims alpha-dir held wk@ (with wk's cred fingerprint), but the
# dirs are already canonical, i.e. both files read as SWAPPED vs the record.
mk_pool composedone
mkdir -p "$RUN/cfg"
fp_of() { printf '%s:%s' "$(wc -c < "$1" | tr -d ' ')" "$(stat -f %m "$1" 2>/dev/null || stat -c %Y "$1")"; }
printf '%s|%s|%s|%s|%s|%s\n' \
  "$RUN/.claude-pool/alpha" "$(email_of wk)" "$RUN/.claude-pool/wk" "$(email_of alpha)" \
  "$(fp_of "$RUN/.claude-pool/wk/.credentials.json")" \
  "$(fp_of "$RUN/.claude-pool/alpha/.credentials.json")" \
  > "$RUN/cfg/normalize-pending"
set +e
OUT="$(bash "$FAILOVER" normalize 2>&1)"; RC=$?
set -e
[ "$RC" -eq 0 ] && [ ! -f "$RUN/cfg/normalize-pending" ] \
  && grep -q 'TOK-alpha' "$RUN/.claude-pool/alpha/.credentials.json" \
  && ok "compose → an already-correct pending pair is cleared without moving a byte" \
  || bad "compose → stale pending cleanup (got $RC: $OUT)"

# a pre-fingerprint (4-field) record is malformed under stage-2, dropped, no move
mk_pool composeold
printf '%s|%s|%s|%s\n' "$RUN/.claude-pool/alpha" "$(email_of wk)" "$RUN/.claude-pool/wk" "$(email_of alpha)" \
  > "$RUN/cfg/normalize-pending"
set +e
OUT="$(bash "$FAILOVER" normalize 2>&1)"; RC=$?
set -e
[ "$RC" -eq 0 ] && [ ! -f "$RUN/cfg/normalize-pending" ] \
  && grep -q 'fingerprint-less' <<<"$OUT" \
  && grep -q 'TOK-alpha' "$RUN/.claude-pool/alpha/.credentials.json" \
  && ok "compose → a fingerprint-less record is dropped, never replayed" \
  || bad "compose → old-format record handling (got $RC: $OUT)"

# ── 8b. the fingerprint-verified replay (stage-2 review, finding 1) ──────────
# The states a crash mid-swap leaves behind, each pinned to its verdict.
# Fixture: crossed pool, reconcile --apply → pending record WITH fingerprints.
crash_fixture() {  # crash_fixture <name>
  mk_pool "$1"
  cross_alpha_wk
  bash "$FAILOVER" reconcile --apply >/dev/null 2>&1
}

# (a) credentials swapped, identities not, the exact re-run-inverts state.
# Fingerprints travel with the files (mv preserves size+mtime), so the record
# proves the creds moved → replay must REFUSE, notify, and touch nothing.
crash_fixture crashcreds
mv "$RUN/.claude-pool/alpha/.credentials.json" "$RUN/state/xfer.$$"
mv "$RUN/.claude-pool/wk/.credentials.json" "$RUN/.claude-pool/alpha/.credentials.json"
mv "$RUN/state/xfer.$$" "$RUN/.claude-pool/wk/.credentials.json"
GM_CRED_BEFORE="$(cat "$RUN/.claude-pool/alpha/.credentials.json")"
set +e
OUT="$(bash "$FAILOVER" normalize 2>&1)"; RC=$?
set -e
[ "$RC" -eq 6 ] && grep -q 'REFUSED' <<<"$OUT" && grep -q 'Manual inspection' <<<"$OUT" \
  && ok "replay → creds-swapped/identities-not REFUSES (exit 6) with the manual-inspection verdict" \
  || bad "replay → half-swap refusal (got $RC: $OUT)"
[ "$(cat "$RUN/.claude-pool/alpha/.credentials.json")" = "$GM_CRED_BEFORE" ] \
  && ok "replay → and NEVER inverts the half that already landed" \
  || bad "replay → credential moved on a refused replay"
[ -f "$RUN/cfg/normalize-pending" ] \
  && ok "replay → the pending record survives as evidence" \
  || bad "replay → pending record dropped on refusal"
grep -q 'manual inspection' "$FAKE_STATE/notifications" 2>/dev/null \
  && ok "replay → and the operator is notified once" \
  || bad "replay → mismatch notification missing (got: $(cat "$FAKE_STATE/notifications" 2>/dev/null || echo none))"

# (b) tmp-stranded: the mid-shuffle die parked a credential under a tmp name.
# Replay must RECOVER it (fingerprint says whose it is), refuse this run,
# notify, and the NEXT run completes from the clean state.
crash_fixture crashtmp
mv "$RUN/.claude-pool/alpha/.credentials.json" "$RUN/.claude-pool/alpha/.credentials.json.normalize-tmp.9999"
set +e
OUT="$(bash "$FAILOVER" normalize 2>&1)"; RC=$?
set -e
[ "$RC" -eq 6 ] && grep -q 'recovered' <<<"$OUT" \
  && ok "replay → a stranded swap temp is RECOVERED and the run refuses (exit 6)" \
  || bad "replay → tmp recovery (got $RC: $OUT)"
[ -f "$RUN/.claude-pool/alpha/.credentials.json" ] \
  && grep -q 'TOK-wk' "$RUN/.claude-pool/alpha/.credentials.json" \
  && ok "replay → the recovered credential is back at its recorded origin (no account left credential-less)" \
  || bad "replay → recovered file missing/wrong"
grep -q 'interrupted pool swap was recovered' "$FAKE_STATE/notifications" 2>/dev/null \
  && ok "replay → recovery is notified" \
  || bad "replay → recovery notification missing"
set +e
OUT="$(bash "$FAILOVER" normalize 2>&1)"; RC=$?
set -e
[ "$RC" -eq 0 ] && grep -q "$(email_of alpha)" "$RUN/.claude-pool/alpha/.claude.json" \
  && grep -q 'TOK-alpha' "$RUN/.claude-pool/alpha/.credentials.json" \
  && [ ! -f "$RUN/cfg/normalize-pending" ] \
  && ok "replay → the NEXT run completes the swap from the recovered clean state" \
  || bad "replay → post-recovery completion (got $RC: $OUT)"

# (c) a VALIDATED partial: identities already swapped, credentials provably
# unmoved, the replay completes ONLY the missing (credential) half.
crash_fixture crashids
mv "$RUN/.claude-pool/alpha/.claude.json" "$RUN/state/idxfer.$$"
mv "$RUN/.claude-pool/wk/.claude.json" "$RUN/.claude-pool/alpha/.claude.json"
mv "$RUN/state/idxfer.$$" "$RUN/.claude-pool/wk/.claude.json"
set +e
OUT="$(bash "$FAILOVER" normalize 2>&1)"; RC=$?
set -e
[ "$RC" -eq 0 ] && grep -q 'completing the credential half only' <<<"$OUT" \
  && ok "replay → a validated partial completes ONLY the missing half" \
  || bad "replay → partial completion (got $RC: $OUT)"
grep -q 'TOK-alpha' "$RUN/.claude-pool/alpha/.credentials.json" \
  && grep -q "$(email_of alpha)" "$RUN/.claude-pool/alpha/.claude.json" \
  && [ ! -f "$RUN/cfg/normalize-pending" ] \
  && ok "replay → and the pair ends fully canonical, record cleared" \
  || bad "replay → post-partial state (alpha cred: $(cat "$RUN/.claude-pool/alpha/.credentials.json"))"

# ── 8c. the post-swap pin re-check (stage-2 review, finding 2) ───────────────
# A shim launch resolving during the swap is invisible to the PRE-gate (its
# CLAUDE_CONFIG_DIR only exists at exec). The swap cannot dodge it, but it
# must SEE it: ps is stubbed to show the pin only on the post-swap re-check
# (calls 1-2 = pre-gate, clean; calls 3-4 = post-check, pinned).
crash_fixture race
: > "$FAKE_STATE/pool-ps-seq"
ps_pin 31337 "$RUN/.claude-pool/alpha" > "$FAKE_STATE/pool-ps-3.txt"
ps_pin 31337 "$RUN/.claude-pool/alpha" > "$FAKE_STATE/pool-ps-4.txt"
set +e
OUT="$(bash "$FAILOVER" normalize 2>&1)"; RC=$?
set -e
[ "$RC" -eq 0 ] && grep -q 'appeared DURING the swap' <<<"$OUT" && grep -q '31337' <<<"$OUT" \
  && ok "race → a pin appearing during the swap is detected and named (pid in the warning)" \
  || bad "race → post-swap pin detection (got $RC: $OUT)"
grep -q 'started during a pool normalize' "$FAKE_STATE/notifications" 2>/dev/null \
  && ok "race → and notified once" \
  || bad "race → race notification missing"
rm -f "$FAKE_STATE/pool-ps-seq" "$FAKE_STATE/pool-ps-calls" "$FAKE_STATE"/pool-ps-*.txt 2>/dev/null || true

# ── 8d. the pool mutation lock (stage-2 review, finding 3) ───────────────────
mk_pool mutlock
cross_alpha_wk
mkdir -p "$RUN/cfg/pool-mutate.lock"
ACC_BEFORE="$(cat "$RUN/cfg/accounts")"
set +e
OUT="$(CLAUDE_FAILOVER_LOCK_RETRY_SLEEP=0 bash "$FAILOVER" reconcile --apply 2>&1)"; RC=$?
set -e
[ "$RC" -eq 7 ] && grep -q 'mutation lock is held' <<<"$OUT" \
  && [ "$(cat "$RUN/cfg/accounts")" = "$ACC_BEFORE" ] \
  && ok "mutate-lock → a held lock refuses reconcile --apply (exit 7, nothing written)" \
  || bad "mutate-lock → interactive refusal (got $RC: $OUT)"
run_keeper "${keeper_env[@]}" CLAUDE_FAILOVER_LOCK_RETRY_SLEEP=0
[ "$RC" -eq 0 ] && grep -q 'reconcile=locked' "$RUN/cfg/keeper-status" \
  && [ "$(cat "$RUN/cfg/accounts")" = "$ACC_BEFORE" ] \
  && ok "mutate-lock → a keeper tick under the lock skips mutation cleanly (reconcile=locked)" \
  || bad "mutate-lock → keeper skip (got $RC, status: $(cat "$RUN/cfg/keeper-status" 2>/dev/null))"
rmdir "$RUN/cfg/pool-mutate.lock"
run_keeper "${keeper_env[@]}"
grep -q "$(email_of alpha)" "$RUN/.claude-pool/alpha/.claude.json" \
  && [ ! -f "$RUN/cfg/normalize-pending" ] \
  && ok "mutate-lock → the tick after the lock clears converges as usual" \
  || bad "mutate-lock → post-lock convergence"

# ── 8e. corrupt usage-cache self-heals in BOTH writers (finding 4) ───────────
mk_pool cachheal
printf 'NOT-JSON{{{' > "$RUN/cfg/usage-cache.json"
usage_fixture alpha 10 10 "$(iso_in +2H)"
run_keeper "${keeper_env[@]}"
jq -e '."alpha@example.com".fetched_at' "$RUN/cfg/usage-cache.json" >/dev/null 2>&1 \
  && ok "cache-heal → the keeper writer replaces a corrupt cache with valid rows" \
  || bad "cache-heal → keeper writer (cache now: $(head -c 120 "$RUN/cfg/usage-cache.json"))"
mk_pool cachheal2
printf 'NOT-JSON{{{' > "$RUN/cfg/usage-cache.json"
printf '{"seven_day":{"utilization":10,"resets_at":"%s"},"five_hour":{"utilization":10,"resets_at":"%s"}}' \
  "$(iso_in +2d)" "$(iso_in +2H)" > "$FAKE_STATE/usage-TOK-alpha.json"
set +e
bash "$FAILOVER" usage --no-color >/dev/null 2>&1
set -e
jq -e . "$RUN/cfg/usage-cache.json" >/dev/null 2>&1 \
  && ok "cache-heal → the failover writer (cache_flush) self-heals too" \
  || bad "cache-heal → failover writer (cache now: $(head -c 120 "$RUN/cfg/usage-cache.json"))"

# ── 8f. move_oauth_account hard-dies BEFORE the deletion step (finding 5) ────
mk_pool switchnooa
printf 'STRAY-SHARED' > "$RUN/.claude/.credentials.json"
rm -f "$RUN/.claude-pool/wk/.claude.json"     # target never completed a login
set +e
OUT="$(bash "$FAILOVER" switch-all wk 2>&1)"; RC=$?
set -e
[ "$RC" -ne 0 ] && grep -q 'no oauthAccount to copy' <<<"$OUT" \
  && [ -f "$RUN/.claude/.credentials.json" ] \
  && ok "pointer-die → a target without oauthAccount dies BEFORE the shared-credential deletion" \
  || bad "pointer-die → no-oauthAccount branch (got $RC: $OUT; shared: $(ls "$RUN/.claude/.credentials.json" 2>/dev/null || echo gone))"
mk_pool switchnoroot
printf 'STRAY-SHARED' > "$RUN/.claude/.credentials.json"
rm -f "$RUN/.claude.json"                      # no claim file at all
set +e
OUT="$(bash "$FAILOVER" switch-all wk 2>&1)"; RC=$?
set -e
# a fresh machine has no ~/.claude.json yet: the switch creates it holding only
# the claim, so the README flow works before the first bare `claude` run
[ "$RC" -eq 0 ] && grep -q 'created ~/.claude.json' <<<"$OUT" \
  && [ "$(jq -r '.oauthAccount.emailAddress' "$RUN/.claude.json" 2>/dev/null)" = "wk@example.com" ] \
  && ok "pointer-die → a missing ~/.claude.json is CREATED with the claim (fresh machine)" \
  || bad "pointer-die → fresh-machine branch (got $RC: $OUT; file: $(cat "$RUN/.claude.json" 2>/dev/null || echo absent))"

# ── 8g. keeper lock takeover needs a DEAD pid (finding 7) ────────────────────
mk_pool lockalive
mkdir -p "$RUN/cfg/keeper.lock"
printf '%s\n' "$$" > "$RUN/cfg/keeper.lock/pid"   # this harness, very much alive
touch -t 202001010000 "$RUN/cfg/keeper.lock"
run_keeper "${keeper_env[@]}"
[ "$RC" -eq 0 ] && grep -q 'STILL LIVE' <<<"$OUT" \
  && [ ! -f "$RUN/cfg/keeper-status" ] \
  && ok "keeper-lock → an old lock with a LIVE pid is never stolen (long tick ≠ crash)" \
  || bad "keeper-lock → live-pid hold (got $RC: $OUT)"
rm -rf "$RUN/cfg/keeper.lock"
mkdir -p "$RUN/cfg/keeper.lock"
printf '999999\n' > "$RUN/cfg/keeper.lock/pid"    # beyond macOS pid_max, dead
touch -t 202001010000 "$RUN/cfg/keeper.lock"
run_keeper "${keeper_env[@]}"
[ "$RC" -eq 0 ] && grep -q 'taking over' <<<"$OUT" && [ -f "$RUN/cfg/keeper-status" ] \
  && ok "keeper-lock → a dead pid's stale lock is taken over (rm + atomic re-mkdir)" \
  || bad "keeper-lock → dead-pid takeover (got $RC: $OUT)"

# ── 8h. the hysteresis knobs are knobs (finding 8) ───────────────────────────
mk_pool knob
usage_fixture alpha   95 50 "$(iso_in +2H)" "$(iso_in +4d)"
usage_fixture wk      85 10 "$(iso_in +2H)" "$(iso_in +1d)"
usage_fixture team    90 10 "$(iso_in +2H)" "$(iso_in +2d)"
usage_fixture primary 99 10 "$(iso_in +2H)" "$(iso_in +3d)"
# the 30%-left floor is opened up here so this test measures the CEILING knob
# alone (every account is >70% spent, i.e. under the default floor)
run_keeper "${keeper_env[@]}" AUTO_SWITCH_TARGET_MAX_PCT=96 AUTO_SWITCH_TARGET_MIN_LEFT_PCT=0
grep -q "switch=to:$(email_of wk)" "$RUN/cfg/keeper-status" \
  && ok "knobs → AUTO_SWITCH_TARGET_MAX_PCT raises the target ceiling (85% now eligible)" \
  || bad "knobs → target ceiling knob (status: $(cat "$RUN/cfg/keeper-status"))"

# ── 9. keeper tick: reconcile→normalize CONVERGES in ONE run when free ───────
mk_pool ktick
cross_alpha_wk
run_keeper "${keeper_env[@]}"
grep -q 'reconcile=fixed' "$RUN/cfg/keeper-status" \
  && ok "keeper → status says the reconcile happened" \
  || bad "keeper → reconcile=fixed (status: $(cat "$RUN/cfg/keeper-status"))"
grep -q 'normalize=swapped' "$RUN/cfg/keeper-status" \
  && ok "keeper → the SAME tick then normalizes off the pending record" \
  || bad "keeper → normalize=swapped (status: $(cat "$RUN/cfg/keeper-status"))"
grep -q "$(email_of alpha)" "$RUN/.claude-pool/alpha/.claude.json" \
  && grep -q "$(email_of wk)" "$RUN/.claude-pool/wk/.claude.json" \
  && grep -q "^$(email_of alpha)|$RUN/.claude-pool/alpha\$" "$RUN/cfg/accounts" \
  && ok "keeper → ONE process-free tick fully converges (dirs canonical, map canonical)" \
  || bad "keeper → one-tick convergence (alpha dir: $(cat "$RUN/.claude-pool/alpha/.claude.json"); map: $(cat "$RUN/cfg/accounts"))"
[ ! -f "$RUN/cfg/normalize-pending" ] \
  && ok "keeper → nothing pending after convergence" \
  || bad "keeper → pending record left behind"

mk_pool kdisabled
run_keeper KEEPER_DISABLE=1
[ "$RC" -eq 0 ] && grep -q 'disabled' "$RUN/cfg/keeper-status" \
  && ok "keeper → KEEPER_DISABLE=1 writes a disabled status and does nothing" \
  || bad "keeper → disable knob (got $RC: $(cat "$RUN/cfg/keeper-status" 2>/dev/null))"
[ ! -f "$FAKE_STATE/claude-calls" ] \
  && ok "keeper → disabled tick makes no claude call" \
  || bad "keeper → disabled tick called claude"

# ── 10. usage NEVER moves a credential (stage-1 review, finding 2) ───────────
mk_pool nohealusage
husk_json > "$RUN/.claude-pool/alpha/.credentials.json"
# the stub CLI now models a real rotation on nudge (expiresAt advances); this
# test is about usage never MOVING credentials, so pin the stub to no-op,
# a self-rotation by the CLI is legitimate and not what is being asserted
for _a in alpha wk team primary; do : > "$FAKE_STATE/norotate-$_a"; done
mkdir -p "$RUN/cfg/creds"
cred_json TOK-STASHED > "$RUN/cfg/creds/$(email_of alpha).json"   # a perfect stash, v1 bait
GM_BEFORE="$(cat "$RUN/.claude-pool/alpha/.credentials.json")"
CS_BEFORE="$(cat "$RUN/.claude-pool/wk/.credentials.json")"
set +e
OUT="$(bash "$FAILOVER" usage --no-color 2>&1)"; RC=$?
set -e
[ "$(cat "$RUN/.claude-pool/alpha/.credentials.json")" = "$GM_BEFORE" ] \
  && [ "$(cat "$RUN/.claude-pool/wk/.credentials.json")" = "$CS_BEFORE" ] \
  && ok "usage → never rewrites a pool .credentials.json (husk stays a husk, stash stays history)" \
  || bad "usage → a pool credential changed under the dashboard"
! grep -q 'healed' <<<"$OUT" \
  && ok "usage → and no heal line is printed (the v1 self-heal is short-circuited)" \
  || bad "usage → heal fired (got: $OUT)"

# ── 11. warming: a fetch failure must not kill the whole day (finding 4) ─────
mk_pool warmretry
usage_fixture wk      10 30 "$(iso_in +2H)"   # decided (open)
usage_fixture team    10 30 "$(iso_in +2H)"   # decided (open)
usage_fixture primary 10 30 "$(iso_in +2H)"   # decided (open)
# …but alpha (eligible: complete cred, not dead) has NO usage fixture → undecided
rm -f "$FAKE_STATE/usage-$(email_of alpha).json" 2>/dev/null || true
run_keeper "${warm_env[@]}"
if compgen -G "$RUN/cfg/warmed-*" > /dev/null; then
  bad "warming-retry → stamped the daily marker despite an undecided account"
else
  ok "warming-retry → an undecided (fetch-failed) account blocks the daily stamp"
fi
grep -q 'warmed=retry' "$RUN/cfg/keeper-status" \
  && ok "warming-retry → status says the pass will retry" \
  || bad "warming-retry → warmed=retry (status: $(cat "$RUN/cfg/keeper-status"))"
# next tick: the fetch works, alpha proves cold → warmed AND stamped
usage_fixture alpha 10 0 ""
run_keeper "${warm_env[@]}"
grep -q "claude-pool/alpha|" "$FAKE_STATE/claude-calls" 2>/dev/null \
  && ok "warming-retry → the next tick (fetch healthy) warms the cold chain" \
  || bad "warming-retry → retry tick warmed nothing (calls: $(cat "$FAKE_STATE/claude-calls" 2>/dev/null || echo none))"
if compgen -G "$RUN/cfg/warmed-*" > /dev/null; then
  ok "warming-retry → and NOW the daily marker is stamped"
else
  bad "warming-retry → marker still missing after a fully-decided pass"
fi

# ── 12. bootstrap: pool-init (fresh machine, e.g. a laptop) ──────────────────
# THE ROSTER IS THE ACCOUNTS FILE: pool-init builds exactly the seats it lists
# and, with no file at all, refuses with instructions (exit 2) rather than
# inventing seats. mk_fresh writes a four-seat accounts file unless told not to.
mk_fresh() {  # mk_fresh <name> [--no-accounts]: one shared login, no pool yet
  RUN="$ROOT/run.$1"
  rm -rf "$RUN"
  mkdir -p "$RUN/.claude" "$RUN/cfg" "$RUN/state"
  printf '{"oauthAccount":{"emailAddress":"%s","accountUuid":"u-al-1"}}' "$(email_of alpha)" \
    > "$RUN/.claude.json"
  if [ "${2:-}" != "--no-accounts" ]; then
    local a
    for a in "${ALIASES[@]}"; do
      printf '%s|%s\n' "$(email_of "$a")" "$RUN/.claude-pool/$a"
    done > "$RUN/cfg/accounts"
  fi
  export HOME="$RUN" CLAUDE_FAILOVER_HOME="$RUN/cfg" FAKE_STATE="$RUN/state"
  export CLAUDE_FAILOVER_BIN="$FAILOVER"
}

# no accounts file → exit 2, the how-to, and NOTHING created
mk_fresh poolinitnone --no-accounts
set +e
OUT="$(bash "$FAILOVER" pool-init 2>&1)"; RC=$?
set -e
[ "$RC" -eq 2 ] && ok "pool-init → with no accounts file it exits 2" \
  || bad "pool-init → no-file exit 2 (got $RC: $OUT)"
grep -q 'no accounts file' <<<"$OUT" && grep -q 'config/accounts.example' <<<"$OUT" \
  && grep -q 'cfg/accounts' <<<"$OUT" \
  && ok "pool-init → the refusal names the file to create and the template that ships with rota" \
  || bad "pool-init → guidance (got: $OUT)"
[ ! -e "$RUN/.claude-pool" ] && [ ! -e "$RUN/cfg/accounts" ] \
  && ok "pool-init → and creates no dir and no accounts file of its own" \
  || bad "pool-init → created something without a roster ($(ls -a "$RUN" "$RUN/cfg"))"
set +e
OUT="$(bash "$FAILOVER" roster 2>/dev/null)"; RC=$?
set -e
[ "$RC" -eq 2 ] && [ -z "$OUT" ] \
  && ok "roster → with no accounts file it exits 2 and prints no rows" \
  || bad "roster → no-file (got $RC: $OUT)"

mk_fresh poolinit
ACC_BEFORE="$(cat "$RUN/cfg/accounts")"
set +e
OUT="$(bash "$FAILOVER" pool-init 2>&1)"; RC=$?
set -e
[ "$RC" -eq 0 ] && ok "pool-init → exit 0 on a fresh box with a roster" || bad "pool-init → exit 0 (got $RC: $OUT)"
PI_OK=1
for a in "${ALIASES[@]}"; do
  [ -d "$RUN/.claude-pool/$a" ] || PI_OK=0
  for t in settings.json commands skills plans projects; do
    [ -L "$RUN/.claude-pool/$a/$t" ] || PI_OK=0
    [ "$(readlink "$RUN/.claude-pool/$a/$t")" = "$RUN/.claude/$t" ] || PI_OK=0
  done
done
[ "$PI_OK" -eq 1 ] \
  && ok "pool-init → one pool dir per accounts row, with the shared link topology (5 symlinks each → ~/.claude/*)" \
  || bad "pool-init → dirs/links (got: $(ls -la "$RUN/.claude-pool/team" 2>/dev/null))"
[ "$(find "$RUN/.claude-pool" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" -eq 4 ] \
  && ok "pool-init → and not one dir more: the accounts file is the whole roster" \
  || bad "pool-init → extra dirs ($(ls "$RUN/.claude-pool"))"
find "$RUN/.claude-pool" -name '.credentials.json' | grep -q . \
  && bad "pool-init → a credential appeared out of nowhere" \
  || ok "pool-init → touches NO credential"
[ "$(cat "$RUN/cfg/accounts")" = "$ACC_BEFORE" ] \
  && ok "pool-init → the accounts file is read, never rewritten" \
  || bad "pool-init → accounts file changed (got: $(cat "$RUN/cfg/accounts"))"
set +e
OUT="$(bash "$FAILOVER" pool-init 2>&1)"; RC=$?
set -e
[ "$RC" -eq 0 ] && grep -q 'already initialized' <<<"$OUT" \
  && [ "$(cat "$RUN/cfg/accounts")" = "$ACC_BEFORE" ] \
  && ok "pool-init → second run is a byte-for-byte no-op" \
  || bad "pool-init → idempotence (got $RC: $OUT)"

# a leading ~/ in the accounts file (what the README and the example use) means $HOME,
# never a literal directory named "~" under the cwd
mk_fresh poolinittilde
for a in "${ALIASES[@]}"; do printf '%s|~/.claude-pool/%s\n' "$(email_of "$a")" "$a"; done > "$RUN/cfg/accounts"
TILDE_CWD="$RUN/cwd"; mkdir -p "$TILDE_CWD"
set +e
OUT="$(cd "$TILDE_CWD" && bash "$FAILOVER" pool-init 2>&1)"; RC=$?
set -e
[ "$RC" -eq 0 ] && [ -d "$RUN/.claude-pool/alpha" ] && [ ! -e "$TILDE_CWD/~" ] \
  && ok "pool-init → a ~/ path in the accounts file expands to \$HOME (no './~' under the cwd)" \
  || bad "pool-init → tilde expansion (rc=$RC, HOME dir: $(ls -d "$RUN/.claude-pool/alpha" 2>&1), cwd: $(ls -a "$TILDE_CWD"))"
ROSTER_OUT="$(bash "$FAILOVER" roster 2>/dev/null)"
grep -q "|$RUN/.claude-pool/alpha\$" <<<"$ROSTER_OUT" \
  && ok "roster → prints the expanded dir, so every consumer sees one spelling" \
  || bad "roster → expanded dir (got: $ROSTER_OUT)"

# a real file where a link would go is left alone; a wrong link is repointed
mk_fresh poolrepoint
mkdir -p "$RUN/.claude-pool/alpha" "$RUN/.claude-pool/wk"
printf '{"real":true}\n' > "$RUN/.claude-pool/alpha/settings.json"
ln -s /nonexistent/skills "$RUN/.claude-pool/wk/skills"
set +e
OUT="$(bash "$FAILOVER" pool-init 2>&1)"; RC=$?
set -e
[ "$RC" -eq 0 ] && [ ! -L "$RUN/.claude-pool/alpha/settings.json" ] \
  && [ "$(cat "$RUN/.claude-pool/alpha/settings.json")" = '{"real":true}' ] \
  && grep -q 'NOT a symlink' <<<"$OUT" \
  && ok "pool-init → real per-dir state outranks the shared link (left alone, reported)" \
  || bad "pool-init → real file preserved (got $RC: $OUT)"
[ "$(readlink "$RUN/.claude-pool/wk/skills")" = "$RUN/.claude/skills" ] \
  && ok "pool-init → a wrong symlink is repointed at the shared target" \
  || bad "pool-init → repoint (got: $(readlink "$RUN/.claude-pool/wk/skills"))"

# ── 13. bootstrap: adopt-shared ──────────────────────────────────────────────
adopt_fixture() {  # adopt_fixture <name>, pool-init'd box, shared login on disk
  mk_fresh "$1"
  bash "$FAILOVER" pool-init >/dev/null 2>&1
  cred_json TOK-SHARED-LOGIN > "$RUN/.claude/.credentials.json"
}

adopt_fixture adopt
: > "$FAKE_STATE/kc-live-Claude_Code_credentials"
AD_HASH="$(printf '%s' "$RUN/.claude" | shasum -a 256 | cut -c1-8)"
: > "$FAKE_STATE/kc-live-Claude_Code_credentials_$AD_HASH"
SHARED_BYTES="$(cat "$RUN/.claude/.credentials.json")"
set +e
OUT="$(bash "$FAILOVER" adopt-shared 2>&1)"; RC=$?
set -e
[ "$RC" -eq 0 ] && ok "adopt-shared → exit 0" || bad "adopt-shared → exit 0 (got $RC: $OUT)"
[ ! -e "$RUN/.claude/.credentials.json" ] \
  && [ "$(cat "$RUN/.claude-pool/alpha/.credentials.json")" = "$SHARED_BYTES" ] \
  && ok "adopt-shared → the credential MOVED (old file gone, new file byte-identical)" \
  || bad "adopt-shared → move semantics (shared still there? $(ls "$RUN/.claude/.credentials.json" 2>/dev/null || echo no))"
[ "$(jq -r '.oauthAccount.accountUuid' "$RUN/.claude-pool/alpha/.claude.json")" = "u-al-1" ] \
  && ok "adopt-shared → the pool dir's .claude.json carries the whole oauthAccount object" \
  || bad "adopt-shared → identity written (got: $(cat "$RUN/.claude-pool/alpha/.claude.json" 2>/dev/null))"
[ "$(jq -r '.oauthAccount.emailAddress' "$RUN/.claude.json")" = "$(email_of alpha)" ] \
  && ok "adopt-shared → ~/.claude.json keeps its oauthAccount (it stays the claim/pointer)" \
  || bad "adopt-shared → claim kept (got: $(cat "$RUN/.claude.json"))"
[ -f "$FAKE_STATE/kc-deleted-Claude_Code_credentials" ] \
  && [ -f "$FAKE_STATE/kc-deleted-Claude_Code_credentials_$AD_HASH" ] \
  && ok "adopt-shared → shared Keychain items purged (both shapes), the moved file is the only source" \
  || bad "adopt-shared → keychain purge"

adopt_fixture adoptpinned
ps_pin 999 "$RUN/.claude-pool/wk" > "$FAKE_STATE/pool-ps.txt"
set +e
OUT="$(bash "$FAILOVER" adopt-shared 2>&1)"; RC=$?
set -e
[ "$RC" -eq 3 ] && grep -q 'REFUSED' <<<"$OUT" \
  && [ -f "$RUN/.claude/.credentials.json" ] \
  && ok "adopt-shared → ANY live claude process refuses the move (exit 3, nothing moved)" \
  || bad "adopt-shared → live-process refusal (got $RC: $OUT)"
rm -f "$FAKE_STATE/pool-ps.txt"

adopt_fixture adopttwin
cred_json TOK-ALREADY > "$RUN/.claude-pool/alpha/.credentials.json"
set +e
OUT="$(bash "$FAILOVER" adopt-shared 2>&1)"; RC=$?
set -e
[ "$RC" -eq 4 ] && grep -q 'twin' <<<"$OUT" \
  && [ -f "$RUN/.claude/.credentials.json" ] \
  && grep -q 'TOK-ALREADY' "$RUN/.claude-pool/alpha/.credentials.json" \
  && ok "adopt-shared → a complete pool credential refuses the move (exit 4, twin chains)" \
  || bad "adopt-shared → twin refusal (got $RC: $OUT)"

adopt_fixture adoptkeychain
rm -f "$RUN/.claude/.credentials.json"          # macOS: login lives ONLY in the Keychain
set +e
OUT="$(bash "$FAILOVER" adopt-shared 2>&1)"; RC=$?
set -e
[ "$RC" -eq 5 ] && grep -q 'CLAUDE_CONFIG_DIR=.*alpha claude auth login --claudeai' <<<"$OUT" \
  && ok "adopt-shared → a Keychain-only login refuses (exit 5) and prints the exact pool-dir login" \
  || bad "adopt-shared → keychain-only refusal (got $RC: $OUT)"

# ── 14. keeper on a freshly pool-init'd box (zero logged-in accounts) ────────
mk_fresh keeperfresh
bash "$FAILOVER" pool-init >/dev/null 2>&1
run_keeper "${keeper_env[@]}"
[ "$RC" -eq 0 ] && ok "keeper → exits 0 on an all-empty pool (right after pool-init)" \
  || bad "keeper → fresh-pool tick (got $RC: $OUT)"
grep -qE 'reconcile=noop nudged=0 fetched=0 switch=none' "$RUN/cfg/keeper-status" \
  && ok "keeper → and writes a sane status line for a roster with zero logged-in accounts" \
  || bad "keeper → fresh-pool status (got: $(cat "$RUN/cfg/keeper-status" 2>/dev/null))"
[ ! -f "$FAKE_STATE/claude-calls" ] \
  && ok "keeper → no nudge is ever attempted against an empty credential" \
  || bad "keeper → nudged an empty pool dir"

# ── 15. macOS Keychain duality: keychain_unify (first live tick, 2026-08-12) ─
# The stub `security` models the per-dir item (kc-live-<slug> exists = item
# present, content = duplicate count, kc-blob-<slug> = what `-w` serves).
kslug() { printf 'Claude_Code_credentials_%s' "$(printf '%s' "$1" | shasum -a 256 | cut -c1-8)"; }

# (a) item NEWER → its blob becomes the file, item drained
mk_pool kcnewer
KSLUG="$(kslug "$RUN/.claude-pool/alpha")"
jq '.claudeAiOauth.expiresAt = (.claudeAiOauth.expiresAt + 7200000)
    | .claudeAiOauth.accessToken = "TOK-FROM-KEYCHAIN"' \
  "$RUN/.claude-pool/alpha/.credentials.json" > "$FAKE_STATE/kc-blob-$KSLUG"
: > "$FAKE_STATE/kc-live-$KSLUG"
run_keeper "${keeper_env[@]}"
grep -q 'TOK-FROM-KEYCHAIN' "$RUN/.claude-pool/alpha/.credentials.json" \
  && ok "unify → a NEWER keychain chain is imported into the file (the item was the live chain)" \
  || bad "unify → newer-item import (cred: $(head -c 80 "$RUN/.claude-pool/alpha/.credentials.json"))"
[ "$(stat -f %Lp "$RUN/.claude-pool/alpha/.credentials.json" 2>/dev/null || stat -c %a "$RUN/.claude-pool/alpha/.credentials.json")" = "600" ] \
  && ok "unify → the imported file lands at mode 600" \
  || bad "unify → import file mode"
[ ! -f "$FAKE_STATE/kc-live-$KSLUG" ] && [ -f "$FAKE_STATE/kc-deleted-$KSLUG" ] \
  && ok "unify → and the item is deleted either way (the dir unifies on the file)" \
  || bad "unify → item not drained"
grep -q 'imported the KEYCHAIN chain' <<<"$OUT" \
  && ok "unify → logs which direction won" \
  || bad "unify → direction log (got: $OUT)"
grep -q 'unify=1' "$RUN/cfg/keeper-status" \
  && ok "unify → keeper-status counts the unified dir" \
  || bad "unify → status count (status: $(cat "$RUN/cfg/keeper-status"))"

# (b) item OLDER → the file stands, item still drained
mk_pool kcolder
KSLUG="$(kslug "$RUN/.claude-pool/alpha")"
printf '{"claudeAiOauth":{"accessToken":"TOK-STALE-ITEM","refreshToken":"rt-old","expiresAt":1000,"refreshTokenExpiresAt":1000}}' \
  > "$FAKE_STATE/kc-blob-$KSLUG"
: > "$FAKE_STATE/kc-live-$KSLUG"
GM_BEFORE="$(cat "$RUN/.claude-pool/alpha/.credentials.json")"
run_keeper "${keeper_env[@]}"
[ "$(cat "$RUN/.claude-pool/alpha/.credentials.json")" = "$GM_BEFORE" ] \
  && grep -q 'kept the FILE' <<<"$OUT" \
  && ok "unify → an OLDER item never touches the file" \
  || bad "unify → older-item skip (got: $OUT)"
[ -f "$FAKE_STATE/kc-deleted-$KSLUG" ] \
  && ok "unify → the stale item is deleted anyway" \
  || bad "unify → stale item survived"

# (c) duplicates under one service name are drained one delete at a time
mk_pool kcdup
KSLUG="$(kslug "$RUN/.claude-pool/alpha")"
printf '{"claudeAiOauth":{"accessToken":"x","refreshToken":"r","expiresAt":1000,"refreshTokenExpiresAt":1000}}' \
  > "$FAKE_STATE/kc-blob-$KSLUG"
printf '3' > "$FAKE_STATE/kc-live-$KSLUG"      # three duplicate items
run_keeper "${keeper_env[@]}"
# 4 delete CALLS = 3 effective drains + the final failing probe that ends the
# bounded loop (the stub logs the attempt before answering "gone")
[ "$(grep -c "delete $KSLUG" "$FAKE_STATE/kc-calls")" -eq 4 ] \
  && [ -f "$FAKE_STATE/kc-deleted-$KSLUG" ] \
  && grep -q 'drained 3 Keychain item' <<<"$OUT" \
  && ok "unify → duplicate items under one name are fully drained (3 drains, loop ends on the empty probe)" \
  || bad "unify → duplicate drain (deletes: $(grep -c "delete $KSLUG" "$FAKE_STATE/kc-calls" 2>/dev/null))"

# (d) honest nudge: success is declared ONLY when the FILE's expiresAt advanced
mk_pool nudgeok
cred_json TOK-alpha "$SOON_MS" > "$RUN/.claude-pool/alpha/.credentials.json"   # only alpha expiring
run_keeper "${keeper_env[@]}" KEEPALIVE_ENABLED=1
grep -q 'nudged alpha@example.com.*verified, the FILE' <<<"$OUT" \
  && ok "nudge → success names the verified FILE advance" \
  || bad "nudge → verified success (got: $OUT)"
! grep -q 'NUDGE INEFFECTIVE' <<<"$OUT" \
  && ok "nudge → no false ineffective on a real rotation" \
  || bad "nudge → spurious ineffective"

# (e) a CLI run that persists NOWHERE is named, and no rotation is claimed
mk_pool nudgebad
cred_json TOK-alpha "$SOON_MS" > "$RUN/.claude-pool/alpha/.credentials.json"
: > "$FAKE_STATE/norotate-alpha"
run_keeper "${keeper_env[@]}" KEEPALIVE_ENABLED=1
grep -q 'NUDGE INEFFECTIVE alpha@example.com' <<<"$OUT" \
  && ok "nudge → a no-op CLI run is logged NUDGE INEFFECTIVE" \
  || bad "nudge → ineffective detection (got: $OUT)"
! grep -q 'nudged alpha@example.com.*verified' <<<"$OUT" \
  && ok "nudge → and rotation is NOT claimed" \
  || bad "nudge → claimed a rotation that never happened"

# (f) the first-live-tick shape: the refresh lands in a just-recreated
# Keychain item, the keeper re-unifies and only then declares success
mk_pool nudgekc
cred_json TOK-alpha "$SOON_MS" > "$RUN/.claude-pool/alpha/.credentials.json"
: > "$FAKE_STATE/kc-on-nudge-alpha"
KSLUG="$(kslug "$RUN/.claude-pool/alpha")"
run_keeper "${keeper_env[@]}" KEEPALIVE_ENABLED=1
grep -q 'unified back into the file, verified' <<<"$OUT" \
  && ok "nudge → a refresh that landed in the Keychain is recovered via re-unify" \
  || bad "nudge → keychain-landed recovery (got: $OUT)"
NEW_EXP="$(jq -r '.claudeAiOauth.expiresAt' "$RUN/.claude-pool/alpha/.credentials.json")"
[ "$NEW_EXP" -gt "$SOON_MS" ] 2>/dev/null \
  && ok "nudge → the FILE really advanced (expiresAt past the pre-nudge value)" \
  || bad "nudge → file did not advance (exp: $NEW_EXP vs $SOON_MS)"
[ -f "$FAKE_STATE/kc-deleted-$KSLUG" ] \
  && ok "nudge → and the recreated item is drained after harvesting" \
  || bad "nudge → recreated item survived"

# (g) non-Darwin: the whole unify machinery is a no-op
mk_pool kclinux
KSLUG="$(kslug "$RUN/.claude-pool/alpha")"
printf '{"claudeAiOauth":{"accessToken":"x","refreshToken":"r","expiresAt":9999999999999,"refreshTokenExpiresAt":9999999999999}}' \
  > "$FAKE_STATE/kc-blob-$KSLUG"
: > "$FAKE_STATE/kc-live-$KSLUG"
GM_BEFORE="$(cat "$RUN/.claude-pool/alpha/.credentials.json")"
run_keeper "${keeper_env[@]}" CLAUDE_KEEPER_PATH_PREFIX="$LINUX_DIR:$STUB_DIR"
[ -f "$FAKE_STATE/kc-live-$KSLUG" ] \
  && [ "$(cat "$RUN/.claude-pool/alpha/.credentials.json")" = "$GM_BEFORE" ] \
  && ! grep -q 'keychain-unify' <<<"$OUT" \
  && grep -q 'unify=0' "$RUN/cfg/keeper-status" \
  && ok "unify → on non-Darwin the step is a complete no-op (item untouched, file untouched)" \
  || bad "unify → non-Darwin no-op (got: $OUT)"

# ── 16. keeper polish (2026-08-12 live observations) ─────────────────────────
fp_now() { printf '%s:%s' "$(wc -c < "$1" | tr -d ' ')" "$(stat -f %m "$1" 2>/dev/null || stat -c %Y "$1")"; }

# FIX 1a, a pending record survives LEGITIMATE in-place rotation: the files'
# fingerprints change but each dir still holds exactly its recorded identity.
crash_fixture polishheal
sleep 1   # a later mtime, so the rotated fingerprints genuinely differ
cred_json TOK-wk-rot    > "$RUN/.claude-pool/alpha/.credentials.json"   # wk's chain, rotated in place
cred_json TOK-alpha-rot > "$RUN/.claude-pool/wk/.credentials.json"      # alpha's chain, rotated in place
ps_pin 4711 "$RUN/.claude-pool/alpha" > "$FAKE_STATE/pool-ps.txt"       # pinned: swap must wait
set +e
OUT="$(bash "$FAILOVER" normalize 2>&1)"; RC=$?
set -e
[ "$RC" -eq 3 ] && grep -q 'pending fingerprints refreshed' <<<"$OUT" \
  && ok "refresh-tolerant → in-place rotation heals the record (and the pinned swap still waits, exit 3)" \
  || bad "refresh-tolerant → record heal (got $RC: $OUT)"
grep -q "$(fp_now "$RUN/.claude-pool/alpha/.credentials.json")" "$RUN/cfg/normalize-pending" \
  && grep -q "$(fp_now "$RUN/.claude-pool/wk/.credentials.json")" "$RUN/cfg/normalize-pending" \
  && ok "refresh-tolerant → the record now carries the ROTATED fingerprints (atomic rewrite)" \
  || bad "refresh-tolerant → record content (got: $(cat "$RUN/cfg/normalize-pending"))"
rm -f "$FAKE_STATE/pool-ps.txt"
set +e
OUT="$(bash "$FAILOVER" normalize 2>&1)"; RC=$?
set -e
[ "$RC" -eq 0 ] && grep -q 'TOK-alpha-rot' "$RUN/.claude-pool/alpha/.credentials.json" \
  && grep -q "$(email_of alpha)" "$RUN/.claude-pool/alpha/.claude.json" \
  && [ ! -f "$RUN/cfg/normalize-pending" ] \
  && ok "refresh-tolerant → the next process-free run COMPLETES the physical swap" \
  || bad "refresh-tolerant → post-heal completion (got $RC: $OUT)"

# FIX 1c, an identity that ALSO changed is a true mismatch: no heal, refuse
crash_fixture polishident
sleep 1
cred_json TOK-wk-rot > "$RUN/.claude-pool/alpha/.credentials.json"
printf '{"oauthAccount":{"emailAddress":"third@example.com"}}' > "$RUN/.claude-pool/alpha/.claude.json"
set +e
OUT="$(bash "$FAILOVER" normalize 2>&1)"; RC=$?
set -e
[ "$RC" -eq 6 ] && grep -q 'REFUSED' <<<"$OUT" && ! grep -q 'pending fingerprints refreshed' <<<"$OUT" \
  && [ -f "$RUN/cfg/normalize-pending" ] \
  && ok "refresh-tolerant → an identity change on top of the rotation still REFUSES (true mismatch)" \
  || bad "refresh-tolerant → identity-change refusal (got $RC: $OUT)"

# FIX 2, the restart-idle refusal names WHICH tmux failure happened
mk_pool tmuxmissing
set +e
OUT="$(CLAUDE_FAILOVER_TMUX_BIN=/nonexistent bash "$FAILOVER" switch-all alpha --restart-idle 2>&1)"; RC=$?
set -e
[ "$RC" -eq 0 ] && grep -q 'tmux binary not found' <<<"$OUT" \
  && ok "tmux → a missing binary is named as such (not 'no session')" \
  || bad "tmux → binary-not-found message (got $RC: $OUT)"
cat > "$ROOT/tmux-dead" <<'DEADSTUB'
#!/usr/bin/env bash
exit 1
DEADSTUB
chmod +x "$ROOT/tmux-dead"
set +e
OUT="$(CLAUDE_FAILOVER_TMUX_BIN="$ROOT/tmux-dead" bash "$FAILOVER" switch-all alpha --restart-idle 2>&1)"; RC=$?
set -e
[ "$RC" -eq 0 ] && grep -q 'tmux server unreachable' <<<"$OUT" \
  && ok "tmux → a present-but-answerless binary is named a SERVER/SOCKET problem" \
  || bad "tmux → server-unreachable message (got $RC: $OUT)"

# ── PANE CONVERGE (keeper step 4b, 2026-08-12) ───────────────────────────────
# After a switch every pane must END UP on the active account: the switch's
# default restart covers idle panes, and this keeper step is the retry that
# picks up the panes that were MID-WORK at the time, every tick, restarting
# only divergent IDLE panes, logging once per still-busy pane+account.

# a FUNCTIONAL tmux stub (the suite-wide one answers "no server" on purpose):
# env-driven panes, logged send-keys, no real tmux anywhere near it.
cat > "$ROOT/tmux-panes" <<'PANESTUB'
#!/usr/bin/env bash
printf 'tmux %s\n' "$*" >> "${TMUX_LOG:-/dev/null}"
case "${1:-}" in
  ls)          exit 0 ;;
  has-session) [ -n "${FAKE_TMUX_PANES:-}" ] && exit 0 || exit 1 ;;
  list-panes)  printf '%s\n' "${FAKE_TMUX_PANES:-}" ;;
  capture-pane)
    pane=""; prev=""
    for a in "$@"; do [ "$prev" = "-t" ] && pane="$a"; prev="$a"; done
    case " ${FAKE_TMUX_WORKING:-} " in
      *" $pane "*) printf 'Frobnicating… (esc to interrupt · 12s)\n'; exit 0 ;;
    esac
    printf '> \n' ;;
  display-message) printf 'zsh\n' ;;
  send-keys)   : ;;
esac
exit 0
PANESTUB
chmod +x "$ROOT/tmux-panes"

US=$'\037'
mk_pool converge
# claim = alpha. %1 idle but pinned to wk (divergent, restartable); %2 pinned
# to team and MID-WORK (divergent, must be waited out); %3 pinned to alpha
# (already converged, no line, no count).
FAKE_TMUX_PANES="%1${US}/dev/ttys001${US}claude${US}✳ alpha work
%2${US}/dev/ttys002${US}claude${US}✳ beta work
%3${US}/dev/ttys003${US}claude${US}✳ gamma work"
export FAKE_TMUX_PANES
export FAKE_TMUX_WORKING="%2"
cat > "$RUN/state/pool-ps.txt" <<POOLPS
PID TT STAT TIME COMMAND
101 s001 S+ 0:00 /usr/local/bin/claude CLAUDE_CONFIG_DIR=$RUN/.claude-pool/wk
102 s002 S+ 0:00 /usr/local/bin/claude CLAUDE_CONFIG_DIR=$RUN/.claude-pool/team
103 s003 S+ 0:00 /usr/local/bin/claude CLAUDE_CONFIG_DIR=$RUN/.claude-pool/alpha
POOLPS
CONV_TMUX_LOG="$ROOT/tmux-converge.log"
: > "$CONV_TMUX_LOG"
export TMUX_LOG="$CONV_TMUX_LOG"
run_keeper CLAUDE_KEEPER_NOW_HHMM=0200 AUTO_SWITCH_RESTART_IDLE=0 \
  CLAUDE_FAILOVER_TMUX_BIN="$ROOT/tmux-panes"
[ "$RC" -eq 0 ] && grep -q 'converge=1+busy:1' "$RUN/cfg/keeper-status" \
  && ok "converge → keeper-status counts the restart AND the still-busy pane" \
  || bad "converge → status (got $RC: $(cat "$RUN/cfg/keeper-status" 2>/dev/null))"
grep -q "pane-converge: %1 restarted onto $(email_of alpha) (was $(email_of wk))" "$RUN/cfg/keeper.log" \
  && ok "converge → one log line per restarted pane, naming both accounts" \
  || bad "converge → restart logged (log: $(tail -5 "$RUN/cfg/keeper.log"))"
grep -q "pane-converge: %2 busy on $(email_of team)" "$RUN/cfg/keeper.log" \
  && ok "converge → the mid-work divergent pane is logged as busy, not touched" \
  || bad "converge → busy logged (log: $(tail -5 "$RUN/cfg/keeper.log"))"
grep -q 'send-keys -t %1 /quit Enter' "$CONV_TMUX_LOG" \
  && grep -q "send-keys -t %1 CLAUDE_CONFIG_DIR=\"$RUN/.claude-pool/alpha\" claude --resume \"alpha work\" Enter" "$CONV_TMUX_LOG" \
  && ok "converge → the divergent idle pane got /quit + a PINNED resume-by-name" \
  || bad "converge → restart keystrokes ($(cat "$CONV_TMUX_LOG"))"
! grep -qE 'send-keys -t (%2|%3)' "$CONV_TMUX_LOG" \
  && ok "converge → the busy pane and the already-converged pane were never touched" \
  || bad "converge → touched a protected pane ($(grep 'send-keys' "$CONV_TMUX_LOG"))"
# tick 2: the busy pane's wall still stands, its line must NOT repeat (log-once
# per pane+account), while the restart (the stub never re-pins, so %1 diverges
# again) logs again because it is an ACTION, not a standing condition
run_keeper CLAUDE_KEEPER_NOW_HHMM=0200 AUTO_SWITCH_RESTART_IDLE=0 \
  CLAUDE_FAILOVER_TMUX_BIN="$ROOT/tmux-panes"
[ "$(grep -c "pane-converge: %2 busy on" "$RUN/cfg/keeper.log")" -eq 1 ] \
  && ok "converge → two ticks with the same busy pane produce ONE log line" \
  || bad "converge → busy logged $(grep -c 'pane-converge: %2 busy on' "$RUN/cfg/keeper.log") times"
[ "$(grep -c "pane-converge: %1 restarted onto" "$RUN/cfg/keeper.log")" -eq 2 ] \
  && ok "converge → restarts log every time they happen (actions, not conditions)" \
  || bad "converge → restart log count $(grep -c 'pane-converge: %1 restarted onto' "$RUN/cfg/keeper.log")"
unset FAKE_TMUX_PANES FAKE_TMUX_WORKING TMUX_LOG

# PANE_CONVERGE=0 turns the step off; the status says so
mk_pool convoff
run_keeper CLAUDE_KEEPER_NOW_HHMM=0200 AUTO_SWITCH_RESTART_IDLE=0 PANE_CONVERGE=0
[ "$RC" -eq 0 ] && grep -q 'converge=off' "$RUN/cfg/keeper-status" \
  && ok "converge → PANE_CONVERGE=0 disables the step (status carries converge=off)" \
  || bad "converge → knob off (got $RC: $(cat "$RUN/cfg/keeper-status" 2>/dev/null))"

# and with the suite's dead tmux the step degrades to converge=none, no error
mk_pool convnone
run_keeper CLAUDE_KEEPER_NOW_HHMM=0200 AUTO_SWITCH_RESTART_IDLE=0
[ "$RC" -eq 0 ] && grep -q 'converge=none' "$RUN/cfg/keeper-status" \
  && ok "converge → no reachable tmux is a quiet converge=none, never an error" \
  || bad "converge → unreachable-tmux degrade (got $RC: $(cat "$RUN/cfg/keeper-status" 2>/dev/null))"

# FIX 3, an identical normalize refusal logs ONCE across consecutive ticks
mk_pool logonce
cross_alpha_wk
bash "$FAILOVER" reconcile --apply >/dev/null 2>&1
mv "$RUN/.claude-pool/alpha/.credentials.json" "$RUN/state/lx.$$"
mv "$RUN/.claude-pool/wk/.credentials.json" "$RUN/.claude-pool/alpha/.credentials.json"
mv "$RUN/state/lx.$$" "$RUN/.claude-pool/wk/.credentials.json"     # movement evidence → rc 6
run_keeper "${keeper_env[@]}"
run_keeper "${keeper_env[@]}"
[ "$(grep -c 'refused pending replay' "$RUN/cfg/keeper.log")" -eq 1 ] \
  && ok "log-once → two ticks with the SAME refusal produce ONE log block" \
  || bad "log-once → refusal logged $(grep -c 'refused pending replay' "$RUN/cfg/keeper.log") times"
grep -q 'normalize=manual' "$RUN/cfg/keeper-status" \
  && ok "log-once → keeper-status still carries normalize=manual every tick" \
  || bad "log-once → status (got: $(cat "$RUN/cfg/keeper-status"))"

# FIX 4, bootstrap grace: shared Keychain items survive while NO pool dir
# holds a credential, and are drained the moment one does
mk_pool grace
for _a in alpha wk team primary; do husk_json > "$RUN/.claude-pool/$_a/.credentials.json"; done
SLUG_PLAIN="$(printf 'Claude Code-credentials' | tr -c 'A-Za-z0-9' '_')"
SLUG_SHARED="$(kslug "$RUN/.claude")"
: > "$FAKE_STATE/kc-live-$SLUG_PLAIN"
: > "$FAKE_STATE/kc-live-$SLUG_SHARED"
run_keeper "${keeper_env[@]}"
[ -f "$FAKE_STATE/kc-live-$SLUG_PLAIN" ] && [ -f "$FAKE_STATE/kc-live-$SLUG_SHARED" ] \
  && grep -q 'bootstrap grace' "$RUN/cfg/keeper.log" \
  && ok "grace → zero pool credentials: shared Keychain items left entirely alone" \
  || bad "grace → items touched or grace not logged (got: $OUT)"
run_keeper "${keeper_env[@]}"
[ "$(grep -c 'bootstrap grace' "$RUN/cfg/keeper.log")" -eq 1 ] \
  && ok "grace → the grace state logs once, not per tick" \
  || bad "grace → grace logged $(grep -c 'bootstrap grace' "$RUN/cfg/keeper.log") times"
cred_json TOK-alpha > "$RUN/.claude-pool/alpha/.credentials.json"    # first pool login lands
run_keeper "${keeper_env[@]}"
[ ! -f "$FAKE_STATE/kc-live-$SLUG_PLAIN" ] && [ ! -f "$FAKE_STATE/kc-live-$SLUG_SHARED" ] \
  && grep -q 'drained' <<<"$OUT" \
  && ok "grace → ONE pool credential ends the grace: shared items drained" \
  || bad "grace → post-grace drain (got: $OUT)"

# FIX 4b, the keeper completes a fresh machine's migration itself
mk_fresh migrate
bash "$FAILOVER" pool-init >/dev/null 2>&1
SLUG_SHARED="$(kslug "$RUN/.claude")"
cred_json TOK-MIGRATED > "$FAKE_STATE/kc-blob-$SLUG_SHARED"          # live chain: Keychain only
: > "$FAKE_STATE/kc-live-$SLUG_SHARED"
run_keeper "${keeper_env[@]}"
grep -q 'TOK-MIGRATED' "$RUN/.claude-pool/alpha/.credentials.json" 2>/dev/null \
  && [ ! -e "$RUN/.claude/.credentials.json" ] \
  && ok "migrate → the GUI-domain keeper harvests the shared Keychain chain and adopts it into the pool dir" \
  || bad "migrate → migration (alpha cred: $(head -c 60 "$RUN/.claude-pool/alpha/.credentials.json" 2>/dev/null || echo missing))"
grep -q 'bootstrap MIGRATED' "$RUN/cfg/keeper.log" \
  && grep -q 'migrated to the pool layout' "$FAKE_STATE/notifications" 2>/dev/null \
  && ok "migrate → logged and notified once" \
  || bad "migrate → migration log/notification missing"
[ ! -f "$FAKE_STATE/kc-live-$SLUG_SHARED" ] \
  && ok "migrate → adopt-shared purged the shared item after the move (file is the only source)" \
  || bad "migrate → shared item survived the migration"
run_keeper "${keeper_env[@]}"
[ "$RC" -eq 0 ] && [ "$(grep -c 'bootstrap grace' "$RUN/cfg/keeper.log")" -le 1 ] \
  && grep -qE 'reconcile=(noop|fixed)' "$RUN/cfg/keeper-status" \
  && ok "migrate → the post-migration tick exits grace and behaves like a normal machine" \
  || bad "migrate → post-migration tick (status: $(cat "$RUN/cfg/keeper-status"))"

# FIX 4b, live claude sessions DEFER the migration (grace continues)
mk_fresh migratepin
bash "$FAILOVER" pool-init >/dev/null 2>&1
SLUG_SHARED="$(kslug "$RUN/.claude")"
cred_json TOK-DEFERRED > "$FAKE_STATE/kc-blob-$SLUG_SHARED"
: > "$FAKE_STATE/kc-live-$SLUG_SHARED"
ps_pin 8080 "$RUN/.claude-pool/alpha" > "$FAKE_STATE/pool-ps.txt"
run_keeper "${keeper_env[@]}"
[ ! -f "$RUN/.claude-pool/alpha/.credentials.json" ] \
  && [ -f "$FAKE_STATE/kc-live-$SLUG_SHARED" ] \
  && grep -q 'deferring adopt-shared' "$RUN/cfg/keeper.log" \
  && ok "migrate → live sessions defer the adopt (pool untouched, items untouched)" \
  || bad "migrate → live-pin defer (log: $(tail -3 "$RUN/cfg/keeper.log" 2>/dev/null))"
rm -f "$FAKE_STATE/pool-ps.txt"

# FIX 5, shim-guard: the shim survives a native auto-update
mk_pool shimguard
mkdir -p "$RUN/.local/share/claude/versions" "$RUN/.local/bin"
printf '#!/usr/bin/env bash\necho native-2.5.0\n' > "$RUN/.local/share/claude/versions/2.5.0"
chmod +x "$RUN/.local/share/claude/versions/2.5.0"
ln -sf "$RUN/.local/share/claude/versions/2.5.0" "$RUN/.local/bin/claude"   # the clobbered state
run_keeper "${keeper_env[@]}"
[ "$(readlink "$RUN/.local/bin/claude")" = "$REPO_ROOT/lib/rota-shim.sh" ] \
  && [ "$(readlink "$RUN/.local/libexec/claude-real")" = "$RUN/.local/share/claude/versions/2.5.0" ] \
  && grep -q 'was NOT the shim' "$RUN/cfg/keeper.log" \
  && ok "shim-guard → a native-update-clobbered link is re-shimmed, real binary parked at libexec/claude-real" \
  || bad "shim-guard → re-link (link: $(readlink "$RUN/.local/bin/claude" 2>/dev/null))"
SG_LOGS="$(grep -c 'shim-guard' "$RUN/cfg/keeper.log")"
run_keeper "${keeper_env[@]}"
[ "$(readlink "$RUN/.local/bin/claude")" = "$REPO_ROOT/lib/rota-shim.sh" ] \
  && [ "$(grep -c 'shim-guard' "$RUN/cfg/keeper.log")" -eq "$SG_LOGS" ] \
  && ok "shim-guard → an up-to-date link is left alone, with no repeat logging" \
  || bad "shim-guard → idempotence (logs: $(grep -c 'shim-guard' "$RUN/cfg/keeper.log") vs $SG_LOGS)"

mk_pool shimbroken
mkdir -p "$RUN/.local/share/claude/versions" "$RUN/.local/bin"
printf '#!/usr/bin/env bash\necho native\n' > "$RUN/.local/share/claude/versions/2.5.0"
chmod +x "$RUN/.local/share/claude/versions/2.5.0"
ln -sf "$RUN/.local/share/claude/versions/2.5.0" "$RUN/.local/bin/claude"
printf 'if [ broken\n' > "$RUN/state/broken-shim.sh"
run_keeper "${keeper_env[@]}" CLAUDE_KEEPER_SHIM_SRC="$RUN/state/broken-shim.sh"
[ "$(readlink "$RUN/.local/bin/claude")" = "$RUN/.local/share/claude/versions/2.5.0" ] \
  && grep -q 'does not parse' "$RUN/cfg/keeper.log" \
  && ok "shim-guard → a broken shim source changes NOTHING (link left on the native binary)" \
  || bad "shim-guard → broken-source safety (link: $(readlink "$RUN/.local/bin/claude"))"

# FIX 5, find_real_claude resolves the native claude-real spelling
mk_pool shimlibexec
mkdir -p "$RUN/.local/libexec"
cat > "$RUN/.local/libexec/claude-real" <<'NATIVE'
#!/usr/bin/env bash
printf '%s\n' "${CLAUDE_CONFIG_DIR:-UNSET}"
NATIVE
chmod +x "$RUN/.local/libexec/claude-real"
set +e
SHIM_OUT="$(CLAUDE_SHIM_DIRS="$RUN/.local/libexec" bash "$SHIM" 2>/dev/null)"; RC=$?
set -e
[ "$RC" -eq 0 ] && [ "$SHIM_OUT" = "$RUN/.claude-pool/alpha" ] \
  && ok "shim → find_real_claude resolves claude-real in libexec (native layout) and still pins" \
  || bad "shim → claude-real resolution (got $RC: $SHIM_OUT)"

# ── 17. the roster verb (consumed by the keeper) ─────────────────────────────
# The roster IS the accounts file, echoed one "email|dir" per line with comments
# stripped, so the keeper's displaced-login detection reads the same truth every
# other verb does.
mk_pool roster
set +e
OUT="$(bash "$FAILOVER" roster 2>&1)"; RC=$?
set -e
[ "$RC" -eq 0 ] && [ "$(grep -c '|' <<<"$OUT")" -eq 4 ] \
  && grep -q "^$(email_of primary)|$RUN/.claude-pool/primary\$" <<<"$OUT" \
  && ! grep -q '^#' <<<"$OUT" \
  && ok "roster → prints every accounts-file row as email|dir, comments stripped" \
  || bad "roster → rows (got $RC: $OUT)"

# ── 18. displaced-login relocation (keeper step 1b) ──────────────────────────
# The twice-lived incident: /login inside a pane pinned to pool dir X writes
# the NEW account's oauthAccount + credential into X, displacing X's canonical
# account (held by NO other dir, not a swap). The keeper relocates it.
LATER_MS=$(( ($(date +%s) + 172800) * 1000 ))        # newer than EXP_MS

# displace_team_into_alpha <name>: team's login landed in alpha's dir; team's
# own canonical dir is EMPTY (no cred, no identity).
displace_team_into_alpha() {
  mk_pool "$1"
  rm -f "$RUN/.claude-pool/team/.credentials.json" "$RUN/.claude-pool/team/.claude.json"
  printf '{"oauthAccount":{"emailAddress":"%s","accountUuid":"u-team-9"}}' "$(email_of team)" \
    > "$RUN/.claude-pool/alpha/.claude.json"
  cred_json TOK-TEAM-FRESH "$LATER_MS" > "$RUN/.claude-pool/alpha/.credentials.json"
}

# (i) empty canonical dir → credential MOVED + both identities restored + map
# fixed, all in ONE tick
displace_team_into_alpha displmove
run_keeper "${keeper_env[@]}"
[ "$RC" -eq 0 ] && ok "displaced → keeper tick exits 0" || bad "displaced → exit 0 (got $RC: $OUT)"
grep -q 'TOK-TEAM-FRESH' "$RUN/.claude-pool/team/.credentials.json" 2>/dev/null \
  && [ ! -e "$RUN/.claude-pool/alpha/.credentials.json" ] \
  && ok "displaced → the fresh credential is MOVED (not copied) into the foreign account's canonical dir" \
  || bad "displaced → credential move (team cred: $(head -c 60 "$RUN/.claude-pool/team/.credentials.json" 2>/dev/null || echo missing))"
[ "$(jq -r '.oauthAccount.accountUuid' "$RUN/.claude-pool/team/.claude.json" 2>/dev/null)" = "u-team-9" ] \
  && ok "displaced → the WHOLE foreign oauthAccount object travels with its credential" \
  || bad "displaced → foreign identity written (got: $(cat "$RUN/.claude-pool/team/.claude.json" 2>/dev/null))"
[ "$(jq -r '.oauthAccount.emailAddress' "$RUN/.claude-pool/alpha/.claude.json" 2>/dev/null)" = "$(email_of alpha)" ] \
  && ok "displaced → the displaced dir's canonical identity is restored (recovered from the claim)" \
  || bad "displaced → identity restore (got: $(cat "$RUN/.claude-pool/alpha/.claude.json" 2>/dev/null))"
grep -q "^$(email_of team)|$RUN/.claude-pool/team\$" "$RUN/cfg/accounts" \
  && grep -q "^$(email_of alpha)|$RUN/.claude-pool/alpha\$" "$RUN/cfg/accounts" \
  && ok "displaced → the map is reconciled back to canonical in the same tick" \
  || bad "displaced → map (got: $(cat "$RUN/cfg/accounts"))"
grep -q 'displaced=fixed:1' "$RUN/cfg/keeper-status" \
  && ok "displaced → keeper-status counts the fix" \
  || bad "displaced → status (got: $(cat "$RUN/cfg/keeper-status"))"
grep -q 'Displaced /login fixed' "$FAKE_STATE/notifications" 2>/dev/null \
  && ok "displaced → and notifies once with the summary" \
  || bad "displaced → notification missing (got: $(cat "$FAKE_STATE/notifications" 2>/dev/null || echo none))"

# (ii) the canonical dir holds a NEWER chain → the displaced file is
# quarantined, the newer chain stands
mk_pool displquar
printf '{"oauthAccount":{"emailAddress":"%s","accountUuid":"u-wk-2"}}' "$(email_of wk)" \
  > "$RUN/.claude-pool/alpha/.claude.json"
cred_json TOK-WK-OLD "$SOON_MS" > "$RUN/.claude-pool/alpha/.credentials.json"   # older than wk dir's
CS_CRED_BEFORE="$(cat "$RUN/.claude-pool/wk/.credentials.json")"
run_keeper "${keeper_env[@]}"
[ "$(cat "$RUN/.claude-pool/wk/.credentials.json")" = "$CS_CRED_BEFORE" ] \
  && ok "displaced-quarantine → the canonical dir's NEWER chain is untouched" \
  || bad "displaced-quarantine → newer chain changed"
if compgen -G "$RUN/.claude-pool/wk/.credentials.displaced-*.json" > /dev/null \
   && grep -q 'TOK-WK-OLD' "$RUN"/.claude-pool/wk/.credentials.displaced-*.json; then
  ok "displaced-quarantine → the displaced (older) file is quarantined as .credentials.displaced-<ts>.json"
else
  bad "displaced-quarantine → quarantine file missing (wk dir: $(ls "$RUN/.claude-pool/wk" 2>/dev/null))"
fi
[ ! -e "$RUN/.claude-pool/alpha/.credentials.json" ] \
  && [ "$(jq -r '.oauthAccount.emailAddress' "$RUN/.claude-pool/alpha/.claude.json" 2>/dev/null)" = "$(email_of alpha)" ] \
  && ok "displaced-quarantine → the displaced dir is cleaned and its identity restored" \
  || bad "displaced-quarantine → displaced dir state (identity: $(cat "$RUN/.claude-pool/alpha/.claude.json" 2>/dev/null))"
grep -q 'displaced=fixed:1' "$RUN/cfg/keeper-status" \
  && ok "displaced-quarantine → status counts the fix" \
  || bad "displaced-quarantine → status (got: $(cat "$RUN/cfg/keeper-status"))"

# (iii) an UNKNOWN account (in neither the map nor the roster) → named,
# notified, skipped, and never given an invented dir
mk_pool displunknown
printf '{"oauthAccount":{"emailAddress":"stranger@example.com"}}' > "$RUN/.claude-pool/alpha/.claude.json"
cred_json TOK-STRANGER "$LATER_MS" > "$RUN/.claude-pool/alpha/.credentials.json"
run_keeper "${keeper_env[@]}"
grep -q 'TOK-STRANGER' "$RUN/.claude-pool/alpha/.credentials.json" \
  && grep -q 'stranger@example.com' "$RUN/.claude-pool/alpha/.claude.json" \
  && ok "displaced-unknown → nothing is moved for an unknown account" \
  || bad "displaced-unknown → files touched"
[ ! -d "$RUN/.claude-pool/stranger" ] \
  && [ "$(find "$RUN/.claude-pool" -maxdepth 1 -type d | grep -c .)" -eq 5 ] \
  && ok "displaced-unknown → no dir is invented for it (pool still 4 dirs + root)" \
  || bad "displaced-unknown → a dir appeared ($(ls "$RUN/.claude-pool"))"
grep -q 'stranger@example.com' "$RUN/cfg/keeper.log" \
  && [ "$(grep -c 'NEITHER the accounts map nor the roster' "$RUN/cfg/keeper.log")" -eq 1 ] \
  && ok "displaced-unknown → logged once, naming the unknown account" \
  || bad "displaced-unknown → log (got: $(tail -3 "$RUN/cfg/keeper.log" 2>/dev/null))"
grep -q 'unknown account stranger@example.com' "$FAKE_STATE/notifications" 2>/dev/null \
  && ok "displaced-unknown → notified, naming the unknown account" \
  || bad "displaced-unknown → notification missing"
grep -q 'displaced=unknown' "$RUN/cfg/keeper-status" \
  && ok "displaced-unknown → status says displaced=unknown" \
  || bad "displaced-unknown → status (got: $(cat "$RUN/cfg/keeper-status"))"

# (iv) a live pin on either dir involved → the pair is untouched this tick
displace_team_into_alpha displpin
ps_pin 6666 "$RUN/.claude-pool/alpha" > "$FAKE_STATE/pool-ps.txt"
run_keeper "${keeper_env[@]}"
grep -q 'TOK-TEAM-FRESH' "$RUN/.claude-pool/alpha/.credentials.json" \
  && grep -q "$(email_of team)" "$RUN/.claude-pool/alpha/.claude.json" \
  && [ ! -e "$RUN/.claude-pool/team/.credentials.json" ] \
  && ok "displaced-pinned → a live pin on either dir leaves the pair untouched" \
  || bad "displaced-pinned → files moved despite a pin"
grep -q 'displaced=pinned' "$RUN/cfg/keeper-status" \
  && ok "displaced-pinned → status says displaced=pinned" \
  || bad "displaced-pinned → status (got: $(cat "$RUN/cfg/keeper-status"))"
run_keeper "${keeper_env[@]}"
[ "$(grep -c 'not touching either dir' "$RUN/cfg/keeper.log")" -eq 1 ] \
  && ok "displaced-pinned → the pinned refusal logs once, not per tick" \
  || bad "displaced-pinned → refusal logged $(grep -c 'not touching either dir' "$RUN/cfg/keeper.log") times"
rm -f "$FAKE_STATE/pool-ps.txt"
run_keeper "${keeper_env[@]}"
grep -q 'TOK-TEAM-FRESH' "$RUN/.claude-pool/team/.credentials.json" 2>/dev/null \
  && grep -q "$(email_of alpha)" "$RUN/.claude-pool/alpha/.claude.json" \
  && ok "displaced-pinned → the first pin-free tick completes the relocation" \
  || bad "displaced-pinned → post-pin completion (team cred: $(head -c 60 "$RUN/.claude-pool/team/.credentials.json" 2>/dev/null || echo missing))"

# (v) identity recovery falls back to the displaced dir's own backup when the
# claim belongs to someone else
displace_team_into_alpha displbackup
printf '{"oauthAccount":{"emailAddress":"%s"}}' "$(email_of wk)" > "$RUN/.claude.json"   # claim ≠ alpha
printf '{"oauthAccount":{"emailAddress":"%s","accountUuid":"u-gm-bak"}}' "$(email_of alpha)" \
  > "$RUN/.claude-pool/alpha/.claude.json.backup"
run_keeper "${keeper_env[@]}"
[ "$(jq -r '.oauthAccount.accountUuid' "$RUN/.claude-pool/alpha/.claude.json" 2>/dev/null)" = "u-gm-bak" ] \
  && ok "displaced-backup → identity restored from the dir's own .claude.json.backup (full object)" \
  || bad "displaced-backup → backup recovery (got: $(cat "$RUN/.claude-pool/alpha/.claude.json" 2>/dev/null))"

# ── 19. local-time display: human-facing stamps carry the UTC offset, no Z ───
mk_pool localtime "$SOON_MS"          # every token expiring → nudges → log lines
run_keeper "${keeper_env[@]}" KEEPALIVE_ENABLED=1
TS_RE='[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{4}'
grep -Eq "^$TS_RE " "$RUN/cfg/keeper-status" \
  && ok "local-time → keeper-status stamps local time with an offset" \
  || bad "local-time → status stamp (got: $(cat "$RUN/cfg/keeper-status"))"
grep -Eq '^[0-9-]+T[0-9:]+Z ' "$RUN/cfg/keeper-status" \
  && bad "local-time → keeper-status still stamps UTC with a trailing Z" \
  || ok "local-time → no trailing Z in the keeper-status stamp"
grep -Eq "^\[$TS_RE\] " "$RUN/cfg/keeper.log" \
  && ok "local-time → keeper.log lines stamp local time with an offset" \
  || bad "local-time → log stamp (got: $(head -1 "$RUN/cfg/keeper.log"))"
if grep -Eq '^\[[0-9-]+T[0-9:]+\] ' "$RUN/cfg/keeper.log"; then
  bad "local-time → an offset-less log stamp survives"
else
  ok "local-time → every keeper.log stamp carries the offset"
fi
run_keeper KEEPER_DISABLE=1
grep -Eq "^$TS_RE disabled" "$RUN/cfg/keeper-status" \
  && ok "local-time → the disabled status line is local-stamped too" \
  || bad "local-time → disabled stamp (got: $(cat "$RUN/cfg/keeper-status"))"

export HOME="$REAL_HOME"
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
