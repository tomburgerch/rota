#!/usr/bin/env bash
#
# rota-keeper.sh: the daemon half of the seat pool (the mental model is in the
# README). Runs every 10 minutes from launchd (com.rota.keeper, StartInterval
# 600) and keeps the pool in the state the pointer-switch design assumes:
#
#   1. RECONCILE   the accounts file is a cache of dir identities; any drift
#                  (a /login into the wrong pinned dir) is repaired by
#                  `rota-engine.sh reconcile --apply`, mapping only,
#                  never a credential byte.
#   1b. DISPLACED-LOGIN RELOCATION (2026-08-12, has happened twice live): a
#                  /login inside a pane pinned to pool dir X writes the NEW
#                  account's oauthAccount + credential into X, displacing X's
#                  canonical account (held by NO other dir, not a swap). The
#                  keeper moves the fresh credential into the foreign
#                  account's canonical dir (or quarantines it when that dir
#                  holds a newer chain), restores X's identity when the
#                  original oauthAccount is recoverable, reconciles, and
#                  notifies once. Unknown accounts are named + skipped, never
#                  given invented dirs. See "displaced-login relocation" below.
#   2. KEEPALIVE   OFF BY DEFAULT since 2026-08-16 (KEEPALIVE_ENABLED=0),
#                  it destroyed credentials instead of preserving them; the
#                  measured numbers and the reasoning are at the step itself,
#                  in main(). When ENABLED, every dormant chain whose access
#                  token is expired or expiring within KEEPALIVE_MIN (90)
#                  minutes gets one haiku nudge so the CLI rotates + persists
#                  the credential itself. Four guards, each one paid for: the
#                  credential must be COMPLETE (nudging a husk is pointless),
#                  NO live process may be pinned to the dir (a live process
#                  refreshes its own chain), the chain must not be MARKED DEAD
#                  (dead-refresh/<label>, re-nudging a rejected refresh token
#                  cannot succeed and CAN destroy the file, a 2026-08-07
#                  incident on one seat), and the token must actually be EXPIRING (a
#                  fresh token needs nothing). A nudge that husks the file
#                  marks the chain dead, keeps the husk quarantined, and
#                  notifies ONCE.
#   3. USAGE       one /api/oauth/usage fetch per account per tick (well under
#                  the ~1 call/min/token budget), with the MANDATORY
#                  claude-code/2.x User-Agent, the default curl UA lands in a
#                  rate-limited bucket. Rows are written into usage-cache.json
#                  in cache_flush's exact shape, fetched_at included, so the
#                  dashboard's staleness rendering and this daemon read one file.
#   4. AUTO-SWITCH at AUTO_SWITCH_PCT (90) on the ACTIVE account's binding
#                  weekly OR five-hour utilization: pick the best target
#                  (logged in, not dead, SOONEST DEADLINE among accounts
#                  with at least AUTO_SWITCH_TARGET_MIN_LEFT_PCT (30) weekly
#                  left; the operator's 2026-08-16 policy: work the account that
#                  expires next and burn it before moving on), `switch-all
#                  <target> [--restart-idle]`, notify once. Hysteresis: never
#                  switch back to the account we just left within 30 min,
#                  never onto an account above 80%. The deadline is
#                  min(weekly reset, SEAT END) and the ordering around it lives
#                  in rota-ranking.sh, SHARED with rota-engine.sh's own picker,
#                  so the unattended switch and the interactive advice cannot
#                  name different seats.
#   4b. PANE CONVERGE (2026-08-12), after a switch, EVERY pane must end up
#                  on the active account without further action: idle panes
#                  immediately (the switch's own default restart), and panes
#                  that were MID-WORK during the switch as soon as they
#                  finish. This step is the retry loop for the second half:
#                  `rota-engine.sh pane-converge` restarts idle panes
#                  whose claude process is pinned (CLAUDE_CONFIG_DIR) to a
#                  POOL dir whose identity differs from the active claim,
#                  same mid-work safety, same /quit + resume-by-name as the
#                  switch's restart; non-pool pins (scratch/login capture)
#                  are never touched. One log line per restarted pane;
#                  still-busy divergent panes log once per pane+account.
#   5. NORMALIZE   opportunistic: `rota-engine.sh normalize` un-swaps
#                  two dirs holding each other's accounts the moment both are
#                  process-free (it refuses with exit 3 otherwise, which is a
#                  wait, not an error).
#   6. WARMING     (requested 2026-08-11) the 5-hour window starts at the
#                  first request, so at the first tick at/after WARM_AT
#                  (03:00) each healthy account whose five-hour window is NOT
#                  currently open gets exactly ONE minimal nudge, a window
#                  opened 03:00 resets 08:00, so morning work runs against a
#                  fresh window. A warmed-<YYYY-MM-DD> marker caps it at once
#                  per day; WARM_ACCOUNTS=all|active picks the population.
#   7. STATUS      one line to keeper-status + a rolling keeper.log (which
#                  also retires the old ad-hoc overnight-switch.log).
#
# Config knobs, ~/.config/claude-failover/keeper.conf (sourced, optional),
# with the ENVIRONMENT winning over the file so a one-off run can override:
#   AUTO_SWITCH_PCT=90  AUTO_SWITCH_RESTART_IDLE=1  KEEPALIVE_MIN=90
#   KEEPER_DISABLE=0    WARM_AT=03:00               WARM_ACCOUNTS=all
#   PANE_CONVERGE=1     0 = never restart divergent idle panes (step 4b)
#   KEEPALIVE_ENABLED=0             1 = restore the pre-2026-08-16 nudging
#   AUTO_SWITCH_TARGET_MAX_PCT=80   never switch ONTO an account above this
#   AUTO_SWITCH_TARGET_MIN_LEFT_PCT=30  never switch onto an account with less
#                                   weekly headroom left than this
#   AUTO_SWITCH_BOUNCE_SECS=1800    no bounce-back to the account just left
#   KEEPER_LOCK_STALE_SECS=1800     lock age before a takeover is considered
#
# Test hooks (the hermetic suite, tests/pool-v2.test.sh):
#   CLAUDE_FAILOVER_HOME       state dir (default ~/.config/claude-failover)
#   CLAUDE_FAILOVER_BIN        the engine (default: sibling lib/rota-engine.sh)
#   CLAUDE_KEEPER_SHIM_SRC     the shim source (default: sibling lib/rota-shim.sh)
#   CLAUDE_FAILOVER_PS_CMD     replaces `ps eww -ax` (same hook the leaf honours)
#   CLAUDE_FAILOVER_USAGE_CMD  executable printing a usage JSON for "<label> <dir>"
#                             , replaces the curl fetch entirely under test
#   CLAUDE_KEEPER_NO_NOTIFY    1 = never post a macOS notification
#   CLAUDE_KEEPER_NOW_HHMM     override "now" for the WARM_AT comparison
#
# NEVER PRINTS A TOKEN. The access token is read into a local used only in an
# Authorization header; every completeness/identity check is jq -e / -r with
# stdout discarded or a non-secret field.

set -euo pipefail

# launchd gives a job PATH=/usr/bin:/bin:/usr/sbin:/sbin, no jq, no shim dir.
# The PREFIX is overridable (CLAUDE_KEEPER_PATH_PREFIX) so the hermetic suite
# can keep its stub `claude`/`security`/`osascript` dir in FRONT, without it
# the export below would put the REAL binaries ahead of every test stub, and a
# test tick would nudge the real CLI and purge the real Keychain.
export PATH="${CLAUDE_KEEPER_PATH_PREFIX:-/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin}:/usr/bin:/bin${PATH:+:$PATH}"

ROTA_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ⚠️ THE AUTO-SWITCH PICKER'S RANKING IS NOT WRITTEN IN THIS FILE. It is
# rota_seat_deadline + rota_deadline_beats, shared with rota-engine.sh's
# compute_recommendation, because the two used to hold the same rule separately
# and drifted the moment one of them learned something (see rota-ranking.sh).
# Sourcing it defines functions and nothing else.
#
# ⚠️ HARD FAIL, never a silent degrade: an unattended daemon that has quietly
# lost its ranking rule would keep switching seats, just to the wrong ones, and
# nobody is watching it at 03:00.
if [[ ! -r "$ROTA_LIB/rota-ranking.sh" ]]; then
  printf 'rota-keeper: %s/rota-ranking.sh is missing; this is an incomplete checkout (it holds the seat ranking, shared with rota-engine.sh)\n' "$ROTA_LIB" >&2
  exit 1
fi
# shellcheck source=lib/rota-ranking.sh
. "$ROTA_LIB/rota-ranking.sh"

CFG_DIR="${CLAUDE_FAILOVER_HOME:-$HOME/.config/claude-failover}"
ACCOUNTS_FILE="$CFG_DIR/accounts"
USAGE_CACHE="$CFG_DIR/usage-cache.json"
# The seat lifecycle (status + end date) the ranking needs. Same default and
# same override as rota-engine.sh's, so both pickers read ONE file; absent, every
# seat is "active with no end date" and the ranking degrades to the weekly reset,
# which is what this picker did before it read the file at all.
BILLING_JSON="${CLAUDE_BILLING_JSON:-$CFG_DIR/billing.json}"
USAGE_API="${CLAUDE_KEEPER_USAGE_API:-https://api.anthropic.com/api/oauth/usage}"
# The UA is load-bearing: the usage API buckets unknown agents into a much
# tighter rate limit (spec §3). Override only in tests.
USAGE_UA="${CLAUDE_KEEPER_USAGE_UA:-claude-code/2.x}"
FAILOVER="${CLAUDE_FAILOVER_BIN:-$ROTA_LIB/rota-engine.sh}"
STATUS_FILE="$CFG_DIR/keeper-status"
LOG_FILE="$CFG_DIR/keeper.log"
LOCK_DIR="$CFG_DIR/keeper.lock"
LAST_SWITCH_FILE="$CFG_DIR/keeper-last-switch"

# ── knobs: defaults ← keeper.conf ← environment ──────────────────────────────
# The env copies are taken BEFORE sourcing: `. keeper.conf` overwrites the
# caller's variables (the sourced-env-clobber trap), so pin first, source,
# re-apply.
_env_AUTO_SWITCH_PCT="${AUTO_SWITCH_PCT:-}"
_env_AUTO_SWITCH_RESTART_IDLE="${AUTO_SWITCH_RESTART_IDLE:-}"
_env_KEEPALIVE_MIN="${KEEPALIVE_MIN:-}"
_env_KEEPALIVE_ENABLED="${KEEPALIVE_ENABLED:-}"
_env_KEEPER_DISABLE="${KEEPER_DISABLE:-}"
_env_WARM_AT="${WARM_AT:-}"
_env_WARM_ACCOUNTS="${WARM_ACCOUNTS:-}"
_env_AUTO_SWITCH_TARGET_MAX_PCT="${AUTO_SWITCH_TARGET_MAX_PCT:-}"
_env_AUTO_SWITCH_TARGET_MIN_LEFT_PCT="${AUTO_SWITCH_TARGET_MIN_LEFT_PCT:-}"
_env_AUTO_SWITCH_BOUNCE_SECS="${AUTO_SWITCH_BOUNCE_SECS:-}"
_env_KEEPER_LOCK_STALE_SECS="${KEEPER_LOCK_STALE_SECS:-}"
_env_PANE_CONVERGE="${PANE_CONVERGE:-}"
AUTO_SWITCH_PCT=90
AUTO_SWITCH_RESTART_IDLE=1
KEEPALIVE_MIN=90
# KEEPALIVE_ENABLED, OFF by default since 2026-08-16. The full evidence and
# the reasoning live at step 2 in main(); the short version is that on both
# live boxes the nudge rotated NOTHING in ~201 attempts and husked 23
# credentials. Set it to 1 in keeper.conf (or the environment) to restore the
# pre-2026-08-16 behaviour.
KEEPALIVE_ENABLED=0
KEEPER_DISABLE=0
WARM_AT="03:00"
WARM_ACCOUNTS="all"
# stage-2 review: the hysteresis numbers are knobs, not literals,
#   AUTO_SWITCH_TARGET_MAX_PCT  never switch ONTO an account above this weekly %
#   AUTO_SWITCH_TARGET_MIN_LEFT_PCT  the headroom FLOOR the soonest-reset pick
#                               must clear (2026-08-16): weekly %-LEFT, so 30
#                               means "never move onto an account more than 70%
#                               spent". With both at their defaults the floor is
#                               the tighter of the two and the MAX_PCT ceiling
#                               only binds once the floor is lowered, both are
#                               kept, because either can be tuned alone.
#   AUTO_SWITCH_BOUNCE_SECS     never bounce back to the account just left within this
#   KEEPER_LOCK_STALE_SECS      a keeper lock older than this is a crashed run's
AUTO_SWITCH_TARGET_MAX_PCT=80
AUTO_SWITCH_TARGET_MIN_LEFT_PCT=30
AUTO_SWITCH_BOUNCE_SECS=1800
KEEPER_LOCK_STALE_SECS=1800
PANE_CONVERGE=1
if [[ -f "$CFG_DIR/keeper.conf" ]]; then
  # shellcheck disable=SC1091
  . "$CFG_DIR/keeper.conf"
fi
[[ -n "$_env_AUTO_SWITCH_PCT" ]] && AUTO_SWITCH_PCT="$_env_AUTO_SWITCH_PCT"
[[ -n "$_env_AUTO_SWITCH_RESTART_IDLE" ]] && AUTO_SWITCH_RESTART_IDLE="$_env_AUTO_SWITCH_RESTART_IDLE"
[[ -n "$_env_KEEPALIVE_MIN" ]] && KEEPALIVE_MIN="$_env_KEEPALIVE_MIN"
[[ -n "$_env_KEEPALIVE_ENABLED" ]] && KEEPALIVE_ENABLED="$_env_KEEPALIVE_ENABLED"
[[ -n "$_env_KEEPER_DISABLE" ]] && KEEPER_DISABLE="$_env_KEEPER_DISABLE"
[[ -n "$_env_WARM_AT" ]] && WARM_AT="$_env_WARM_AT"
[[ -n "$_env_WARM_ACCOUNTS" ]] && WARM_ACCOUNTS="$_env_WARM_ACCOUNTS"
[[ -n "$_env_AUTO_SWITCH_TARGET_MAX_PCT" ]] && AUTO_SWITCH_TARGET_MAX_PCT="$_env_AUTO_SWITCH_TARGET_MAX_PCT"
[[ -n "$_env_AUTO_SWITCH_TARGET_MIN_LEFT_PCT" ]] && AUTO_SWITCH_TARGET_MIN_LEFT_PCT="$_env_AUTO_SWITCH_TARGET_MIN_LEFT_PCT"
[[ -n "$_env_AUTO_SWITCH_BOUNCE_SECS" ]] && AUTO_SWITCH_BOUNCE_SECS="$_env_AUTO_SWITCH_BOUNCE_SECS"
[[ -n "$_env_KEEPER_LOCK_STALE_SECS" ]] && KEEPER_LOCK_STALE_SECS="$_env_KEEPER_LOCK_STALE_SECS"
[[ -n "$_env_PANE_CONVERGE" ]] && PANE_CONVERGE="$_env_PANE_CONVERGE"

tilde() { printf '%s' "${1/#$HOME/~}"; }

# Human-facing timestamps are LOCAL machine time with the UTC offset (the
# operator reads local time, 2026-08-12). Machine-parsed fields (usage-cache.json's
# fetched_at/ts_epoch, the keeper-last-switch epoch) stay exactly as they were;
# nothing parses the keeper-status/keeper.log stamps (`rota keeper-status` only
# cats them).
now_local() { date '+%Y-%m-%dT%H:%M:%S%z'; }

log() {  # log <message>, keeper.log line + stdout (launchd captures stdout)
  local line
  line="[$(now_local)] $*"
  printf '%s\n' "$line"
  mkdir -p "$CFG_DIR" 2>/dev/null || return 0
  printf '%s\n' "$line" >> "$LOG_FILE" 2>/dev/null || true
  # rolling: keep the file bounded without logrotate. tail+mv, best-effort.
  if [[ -f "$LOG_FILE" ]] && [[ "$(wc -l < "$LOG_FILE" 2>/dev/null | tr -d ' ')" -gt 500 ]]; then
    tail -400 "$LOG_FILE" > "$LOG_FILE.tmp.$$" 2>/dev/null && mv "$LOG_FILE.tmp.$$" "$LOG_FILE" || rm -f "$LOG_FILE.tmp.$$"
  fi
}

# State-change notification, cred-guard's mechanism (osascript display
# notification behind a dedupe file): notify only when the message for a key
# CHANGES, never on every tick, the repeating-nudge rule.
notify_once() {  # notify_once <key> <message>
  local key="${1:-}" msg="${2:-}" state prev=""
  state="$CFG_DIR/keeper-notified-$key"
  [[ -f "$state" ]] && prev="$(cat "$state" 2>/dev/null || true)"
  [[ "$prev" == "$msg" ]] && return 0
  printf '%s' "$msg" > "$state" 2>/dev/null || true
  if [[ -z "${CLAUDE_KEEPER_NO_NOTIFY:-}" ]] && command -v osascript >/dev/null 2>&1; then
    osascript -e "display notification \"${msg//\"/\\\"}\" with title \"Claude pool keeper\"" \
      >/dev/null 2>&1 || true
  fi
}

# State-change LOGGING, notify_once's sibling for the log file (keeper polish,
# 2026-08-12): a condition that persists across ticks, a normalize refusal, an
# ambiguous map, a 401ing usage token, is logged ONCE per distinct STATE
# (keyed on whatever the caller folds into <state-string>), then stays quiet
# until the state changes. keeper-status keeps carrying the condition every
# tick; only the LOG stops repeating itself. log_state_clear re-arms a key
# once its condition resolves, so a recurrence logs again.
log_once() {  # log_once <key> <state-string> <message>
  local key="${1:-}" lstate="${2:-}" f prev=""
  f="$CFG_DIR/keeper-lastlog-$key"
  [[ -f "$f" ]] && prev="$(cat "$f" 2>/dev/null || true)"
  [[ "$prev" == "$lstate" ]] && return 0
  mkdir -p "$CFG_DIR" 2>/dev/null || true
  printf '%s' "$lstate" > "$f" 2>/dev/null || true
  shift 2
  log "$@"
}
log_state_clear() { rm -f "$CFG_DIR/keeper-lastlog-${1:-__none__}" 2>/dev/null || true; }

# ── accounts file (same parse as the engine + cred-guard) ────────────────────
LABELS=(); DIRS=()
load_accounts() {
  LABELS=(); DIRS=()
  [[ -f "$ACCOUNTS_FILE" ]] || return 1
  local label dir
  while IFS='|' read -r label dir || [[ -n "${label:-}" ]]; do
    label="${label//[$' \t\r']/}"
    dir="${dir//[$' \t\r']/}"
    [[ -n "$label" ]] || continue
    case "$label" in \#*) continue ;; esac
    [[ -n "$dir" ]] || continue
    # shellcheck disable=SC2088  # literal "~/" data value, expanded by hand
    case "$dir" in "~/"*) dir="$HOME/${dir#\~/}" ;; esac
    LABELS+=("$label"); DIRS+=("$dir")
  done < "$ACCOUNTS_FILE"
  [[ ${#DIRS[@]} -ge 1 ]]
}

# ── credential primitives (jq only; stdout of secret-bearing reads discarded) ─
cred_is_complete() {
  local f="${1:-}"
  [[ -f "$f" && -s "$f" ]] || return 1
  jq -e '(.claudeAiOauth // {}) as $o
         | ($o.refreshToken | type == "string" and length > 0)
           and ($o | has("expiresAt")) and ($o.expiresAt != null)' \
     "$f" >/dev/null 2>&1
}

cred_fingerprint() {  # "<bytes>:<mtime>", identity, never content
  local f="${1:-}" sz mt
  [[ -f "$f" ]] || return 1
  sz="$(wc -c < "$f" 2>/dev/null | tr -d ' ')" || return 1
  mt="$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null)" || return 1
  [[ -n "$sz" && -n "$mt" ]] || return 1
  printf '%s:%s' "$sz" "$mt"
}

refresh_known_dead() {  # refresh_known_dead <label> <cred-file>
  local m="$CFG_DIR/dead-refresh/${1:-}" fp
  [[ -f "$m" ]] || return 1
  fp="$(cred_fingerprint "${2:-}")" || return 1
  [[ -n "$fp" && "$fp" == "$(cat "$m" 2>/dev/null || true)" ]]
}

mark_refresh_dead() {  # mark_refresh_dead <label> <fingerprint>
  [[ -n "${2:-}" ]] || return 0
  mkdir -p "$CFG_DIR/dead-refresh" 2>/dev/null || return 0
  printf '%s\n' "$2" > "$CFG_DIR/dead-refresh/$1" 2>/dev/null || true
}

# Access-token expiry (ms epoch in Claude Code's file; small values accepted as
# seconds so a differently-shaped file cannot misjudge). Prints seconds-to-
# expiry, negative when already expired; nothing when unknowable.
token_expiry_in() {  # token_expiry_in <cred-file>
  local f="${1:-}" exp now
  exp="$(jq -r '.claudeAiOauth.expiresAt // empty' "$f" 2>/dev/null || true)"
  [[ "$exp" =~ ^[0-9]+$ ]] || return 0
  (( exp > 100000000000 )) && exp=$(( exp / 1000 ))
  now="$(date +%s)"
  printf '%s' $(( exp - now ))
}

# ── live pinned processes (same hook the engine honours) ─────────────────────
pool_ps() {
  if [[ -n "${CLAUDE_FAILOVER_PS_CMD:-}" ]]; then
    "${CLAUDE_FAILOVER_PS_CMD}" 2>/dev/null || true
  else
    ps eww -ax 2>/dev/null || true
  fi
}

dir_has_live_process() {  # dir_has_live_process <dir>
  local want="${1:-}" pid dir
  [[ -n "$want" ]] || return 1
  while read -r pid dir; do
    [[ -n "$pid" && -n "$dir" ]] || continue
    if [[ "$dir" == "$want" ]] || { [[ -d "$dir" && -d "$want" ]] && [[ "$dir" -ef "$want" ]]; }; then
      return 0
    fi
  done < <(pool_ps | awk '
    NR == 1 && $1 == "PID" { next }
    {
      cmd = $5; sub(".*/", "", cmd)
      if (cmd != "claude" && cmd != "claude.exe") next
      for (i = 6; i <= NF; i++)
        if ($i ~ /^CLAUDE_CONFIG_DIR=/) {
          sub("CLAUDE_CONFIG_DIR=", "", $i)
          print $1, $i
        }
    }' 2>/dev/null || true)
  return 1
}

# ── displaced-login relocation (pool v2, 2026-08-12) ─────────────────────────
# The incident this automates away (it has happened twice): the operator runs /login
# inside a pane PINNED to pool dir X, the CLI writes the NEW account's
# oauthAccount + credential into X, displacing X's canonical account. The
# shape it leaves is NOT a swap (normalize's territory): X holds a foreign
# identity, and X's canonical account is held by NO dir at all. Until now that
# meant manual surgery; the keeper now relocates it in one tick:
#
#   (a) resolve the foreign identity's canonical dir: accounts-map snapshot
#       (taken BEFORE this tick's reconcile rewrote it) first, then the
#       roster (`rota-engine.sh roster`, read from the accounts file); a roster dir that does
#       not exist yet is created through the pool-init helper. An account in
#       NEITHER place is unknown: log-once + notify naming it and SKIP, never
#       invent dirs for unknown accounts.
#   (b) if the canonical dir's existing credential is absent, incomplete, or
#       OLDER (expiresAt) than the displaced one → MOVE the displaced
#       .credentials.json there (same-filesystem rename) + write the foreign
#       oauthAccount into that dir's .claude.json (other keys preserved).
#       Else the newer existing chain stands and the displaced file is
#       quarantined to <canonical-dir>/.credentials.displaced-<ts>.json.
#   (c) restore X's canonical identity in its .claude.json ONLY when the
#       original oauthAccount object is recoverable, from ~/.claude.json when
#       it is the claim, from X's own backups (.claude.json.backup, backups/),
#       or (identity only) from the cred-guard backup ring's .meta, else the
#       identity is left as-is for reconcile to re-map, and the fact logged.
#   (d) reconcile --apply, so the map matches the repaired dirs.
#   (e) notify_once with the summary.
#
# Guards: the pool-mutate lock is held for the file moves; the whole pair is
# skipped (log-once) while any live process is pinned to EITHER dir; and, like
# normalize, no file is ever moved whose size/mtime changed between the read
# and the mv (fingerprint re-check immediately before each rename). A deferred
# (pinned/locked) relocation is recorded in $CFG_DIR/displaced-pending, the
# same pattern as normalize-pending, and for the same reason: this tick's
# reconcile has already rewritten the map over the evidence, so the record is
# what lets a later process-free tick complete the repair.
DISPLACED=0
ST_DISPLACED="none"
CANON_LBL=(); CANON_DIR=()
R_EMAILS=(); R_DIRS=()

load_roster() {
  R_EMAILS=(); R_DIRS=()
  local e d
  while IFS='|' read -r e d || [[ -n "${e:-}" ]]; do
    [[ -n "$e" && -n "$d" ]] || continue
    R_EMAILS+=("$e"); R_DIRS+=("$d")
  done < <(bash "$FAILOVER" roster 2>/dev/null || true)
  return 0
}

dir_identity() {  # dir_identity <dir> → its .claude.json oauthAccount email
  jq -r '.oauthAccount.emailAddress // empty' "${1:-}/.claude.json" 2>/dev/null || true
}

cred_expires_ms() {  # cred_expires_ms <cred-file> → expiresAt normalized to ms
  local e
  e="$(jq -r '.claudeAiOauth.expiresAt // empty' "${1:-}" 2>/dev/null || true)"
  [[ "$e" =~ ^[0-9]+$ ]] || return 0
  (( e < 100000000000 )) && e=$(( e * 1000 ))   # seconds-shaped → ms
  printf '%s' "$e"
}

write_oauth_account() {  # write_oauth_account <dir> <oauthAccount-json>
  local cfg="${1:-}/.claude.json" tmp
  tmp="$cfg.displaced-tmp.$$"
  if [[ -f "$cfg" ]]; then
    # preserve every other key, only .oauthAccount is replaced
    if jq --argjson oa "${2:-null}" '.oauthAccount = $oa' "$cfg" > "$tmp" 2>/dev/null; then
      mv "$tmp" "$cfg" || { rm -f "$tmp"; return 1; }
    else
      rm -f "$tmp"; return 1
    fi
  else
    printf '{"oauthAccount":%s}\n' "${2:-null}" > "$cfg" 2>/dev/null || return 1
  fi
  return 0
}

# The recoverable spelling of <email>'s oauthAccount, sources in order: the
# ~/.claude.json claim (full object), the displaced dir's own backups (full
# object), the cred-guard ring's .meta (identity only → minimal object).
# Sets ORIG_OA (json or empty) + ORIG_SRC.
ORIG_OA=""; ORIG_SRC=""
recover_oauth_account() {  # recover_oauth_account <dir> <email>
  local cdir="${1:-}" cemail="${2:-}" b m
  ORIG_OA=""; ORIG_SRC=""
  if [[ "$(jq -r '.oauthAccount.emailAddress // empty' "$HOME/.claude.json" 2>/dev/null || true)" == "$cemail" ]]; then
    ORIG_OA="$(jq -c '.oauthAccount' "$HOME/.claude.json" 2>/dev/null || true)"
    [[ -n "$ORIG_OA" && "$ORIG_OA" != "null" ]] && { ORIG_SRC="the ~/.claude.json claim"; return 0; }
    ORIG_OA=""
  fi
  for b in "$cdir/.claude.json.backup" "$cdir"/backups/*.json; do
    [[ -f "$b" ]] || continue
    if [[ "$(jq -r '.oauthAccount.emailAddress // empty' "$b" 2>/dev/null || true)" == "$cemail" ]]; then
      ORIG_OA="$(jq -c '.oauthAccount' "$b" 2>/dev/null || true)"
      [[ -n "$ORIG_OA" && "$ORIG_OA" != "null" ]] && { ORIG_SRC="$(tilde "$b")"; return 0; }
      ORIG_OA=""
    fi
  done
  for m in "$CFG_DIR/backups/$(basename "$cdir")"/*.json.meta; do
    [[ -f "$m" ]] || continue
    if [[ "$(sed -n 's/^identity=//p' "$m" 2>/dev/null | head -1)" == "$cemail" ]]; then
      ORIG_OA="$(jq -cn --arg e "$cemail" '{emailAddress:$e}')"
      ORIG_SRC="the cred-guard backup ring's .meta (identity only)"
    fi
  done
  [[ -n "$ORIG_OA" ]]
}

# RELOC_STATE after each call: "done" (repaired), "deferred" (pinned/locked/
# raced, keep the pending record so a later tick completes it).
RELOC_STATE=""
relocate_displaced() {  # relocate_displaced <cdir> <canonical-email> <foreign-email> <foreign-dir>
  local cdir="${1:-}" cemail="${2:-}" femail="${3:-}" fdir="${4:-}"
  local key="displaced-$(basename "$cdir")" mlock="$CFG_DIR/pool-mutate.lock"
  RELOC_STATE="deferred"
  # guard 1: no live process pinned to EITHER dir, skip entirely, retry later
  if dir_has_live_process "$cdir" || { [[ -d "$fdir" ]] && dir_has_live_process "$fdir"; }; then
    ST_DISPLACED="pinned"
    log_once "$key" "pinned:$femail" "displaced-login: $femail's login sits in $(tilde "$cdir") (displacing $cemail) but a live claude process is pinned to $(tilde "$cdir") or $(tilde "$fdir"), not touching either dir; retrying next tick"
    return 0
  fi
  # guard 2: the pool-mutate lock (same lock every failover mutation takes)
  if ! mkdir "$mlock" 2>/dev/null; then
    ST_DISPLACED="locked"
    log_once "$key" "locked:$femail" "displaced-login: pool-mutate lock held, deferring the $femail relocation out of $(tilde "$cdir") to the next tick"
    return 0
  fi
  printf '%s\n' "$$" > "$mlock/pid" 2>/dev/null || true

  # (a) a roster dir that does not exist yet is created via the pool-init
  # helper (idempotent; roster accounts only, unknowns never reach here)
  if [[ ! -d "$fdir" ]]; then
    bash "$FAILOVER" pool-init >/dev/null 2>&1 || true
    mkdir -p "$fdir" 2>/dev/null || true
  fi

  local dcred="$cdir/.credentials.json" fcred="$fdir/.credentials.json"
  local ts action="(no credential file to relocate)"
  ts="$(date '+%Y%m%d-%H%M%S')"
  # the foreign oauthAccount, captured BEFORE any identity is rewritten
  local foreign_oa
  foreign_oa="$(jq -c '.oauthAccount // empty' "$cdir/.claude.json" 2>/dev/null || true)"

  if [[ -f "$dcred" ]]; then
    # (b) which chain wins? the canonical dir's existing credential loses when
    # absent, incomplete, or older (expiresAt) than the displaced one.
    local d_exp f_exp move=1 pre_fp now_fp
    d_exp="$(cred_expires_ms "$dcred")"
    f_exp="$(cred_expires_ms "$fcred")"
    if cred_is_complete "$fcred" && [[ -n "$f_exp" ]] \
       && { [[ -z "$d_exp" ]] || (( f_exp >= d_exp )); }; then
      move=0
    fi
    pre_fp="$(cred_fingerprint "$dcred" 2>/dev/null || true)"
    if (( move )); then
      # an incomplete/older existing chain is parked, never blind-overwritten
      if [[ -e "$fcred" || -L "$fcred" ]]; then
        mv "$fcred" "$fcred.displaced-bak-$ts" 2>/dev/null || true
      fi
      # fingerprint safety: the displaced file must not have changed since read
      now_fp="$(cred_fingerprint "$dcred" 2>/dev/null || true)"
      if [[ -n "$pre_fp" && "$now_fp" == "$pre_fp" ]] && mv "$dcred" "$fcred" 2>/dev/null; then
        chmod 600 "$fcred" 2>/dev/null || true
        action="moved its fresh credential into $(tilde "$fdir")"
        if [[ -n "$foreign_oa" ]]; then
          write_oauth_account "$fdir" "$foreign_oa" \
            || log "displaced-login: could not write $femail's oauthAccount into $(tilde "$fdir")/.claude.json, reconcile will still map the credential's dir"
        fi
      else
        log "displaced-login: $(tilde "$dcred") changed between read and move, leaving everything in place; retrying next tick"
        rm -rf "$mlock" 2>/dev/null || true
        return 0
      fi
    else
      # the canonical dir already holds a NEWER chain for $femail, quarantine
      now_fp="$(cred_fingerprint "$dcred" 2>/dev/null || true)"
      if [[ -n "$pre_fp" && "$now_fp" == "$pre_fp" ]] \
         && mv "$dcred" "$fdir/.credentials.displaced-$ts.json" 2>/dev/null; then
        chmod 600 "$fdir/.credentials.displaced-$ts.json" 2>/dev/null || true
        action="quarantined its (older) displaced credential to $(tilde "$fdir")/.credentials.displaced-$ts.json, $(tilde "$fdir") keeps its newer chain"
        if [[ -z "$(dir_identity "$fdir")" && -n "$foreign_oa" ]]; then
          write_oauth_account "$fdir" "$foreign_oa" || true
        fi
      else
        log "displaced-login: $(tilde "$dcred") changed between read and move, leaving everything in place; retrying next tick"
        rm -rf "$mlock" 2>/dev/null || true
        return 0
      fi
    fi
  fi

  # (c) restore the displaced dir's canonical identity, only from a
  # recoverable oauthAccount object, never invented
  local id_note
  if recover_oauth_account "$cdir" "$cemail" && write_oauth_account "$cdir" "$ORIG_OA"; then
    id_note="restored $cemail's identity (from $ORIG_SRC)"
  else
    id_note="could NOT recover $cemail's oauthAccount (claim, backups and ring all lack it), identity left as-is for reconcile to re-map; $cemail needs a browser login into $(tilde "$cdir")"
  fi

  rm -rf "$mlock" 2>/dev/null || true

  # (d) reconcile the map against the repaired dirs, then reload it
  set +e
  bash "$FAILOVER" reconcile --apply >/dev/null 2>&1
  set -e
  load_accounts || true

  # (e) one summary, logged + notified once
  DISPLACED=$((DISPLACED + 1))
  RELOC_STATE="done"
  log "displaced-login FIXED $(basename "$cdir"): a /login had written $femail into $(tilde "$cdir"), $action; $id_note; map reconciled"
  notify_once "$key" "Displaced /login fixed: $femail's login in $(tilde "$cdir"), $action. $id_note."
  log_state_clear "$key"
  return 0
}

detect_displaced_login() {
  local pend="$CFG_DIR/displaced-pending"

  # 0. REPLAY pending records from earlier deferred (pinned/locked) ticks.
  # That first tick's reconcile already rewrote the map to match the displaced
  # dirs, so, exactly like normalize-pending, the record is the surviving
  # evidence of which account each dir was supposed to hold.
  if [[ -f "$pend" ]]; then
    local tmpp="$pend.tmp.$$" pcd pce pfe pfd cur2 held2 k
    : > "$tmpp"
    while IFS='|' read -r pcd pce pfe pfd || [[ -n "${pcd:-}" ]]; do
      [[ -n "$pcd" && -n "$pce" && -n "$pfe" && -n "$pfd" ]] || continue
      cur2="$(dir_identity "$pcd")"
      if [[ "$cur2" != "$pfe" ]]; then
        log "displaced-login: pending record for $(tilde "$pcd") no longer matches (it holds ${cur2:-nothing}, not $pfe), dropping it"
        log_state_clear "displaced-$(basename "$pcd")"
        continue
      fi
      held2=0
      for k in "${!CANON_DIR[@]}"; do
        [[ "${CANON_DIR[$k]}" == "$pcd" ]] && continue
        [[ "$(dir_identity "${CANON_DIR[$k]}")" == "$pce" ]] && { held2=1; break; }
      done
      if (( held2 )); then
        log "displaced-login: pending record for $(tilde "$pcd") superseded ($pce is held elsewhere now), dropping it"
        log_state_clear "displaced-$(basename "$pcd")"
        continue
      fi
      RELOC_STATE=""
      relocate_displaced "$pcd" "$pce" "$pfe" "$pfd" || true
      [[ "$RELOC_STATE" == "done" ]] || printf '%s|%s|%s|%s\n' "$pcd" "$pce" "$pfe" "$pfd" >> "$tmpp"
    done < "$pend"
    if [[ -s "$tmpp" ]]; then mv "$tmpp" "$pend" 2>/dev/null || rm -f "$tmpp"
    else rm -f "$tmpp" "$pend"; fi
  fi

  # 1. FRESH detection against the pre-reconcile map snapshot
  local i j cdir cemail cur held fdir
  for i in "${!CANON_DIR[@]}"; do
    cdir="${CANON_DIR[$i]}"; cemail="${CANON_LBL[$i]}"
    [[ -d "$cdir" ]] || continue
    cur="$(dir_identity "$cdir")"
    if [[ -z "$cur" || "$cur" == "$cemail" ]]; then
      # healthy, but never clear the log-once dedupe while a pending record
      # still names this dir (the rewritten map reads "healthy" every tick a
      # deferred relocation waits, and clearing would re-arm the refusal log)
      if ! grep -q "^$cdir|" "$pend" 2>/dev/null; then
        log_state_clear "displaced-$(basename "$cdir")"
        log_state_clear "displaced-unknown-$(basename "$cdir")"
      fi
      continue
    fi
    # canonical account still held by ANOTHER dir → a swap/copy shape, which
    # is reconcile/normalize territory, not a displacement
    held=0
    for j in "${!CANON_DIR[@]}"; do
      (( j == i )) && continue
      [[ "$(dir_identity "${CANON_DIR[$j]}")" == "$cemail" ]] && { held=1; break; }
    done
    (( held )) && continue
    # resolve the foreign identity's canonical dir: map snapshot, then roster
    fdir=""
    for j in "${!CANON_DIR[@]}"; do
      [[ "${CANON_LBL[$j]}" == "$cur" ]] && { fdir="${CANON_DIR[$j]}"; break; }
    done
    if [[ -z "$fdir" ]]; then
      for j in "${!R_EMAILS[@]}"; do
        [[ "${R_EMAILS[$j]}" == "$cur" ]] && { fdir="${R_DIRS[$j]}"; break; }
      done
    fi
    if [[ -z "$fdir" ]]; then
      # an account in neither the map nor the roster: never invent a dir
      ST_DISPLACED="unknown"
      log_once "displaced-unknown-$(basename "$cdir")" "$cur" \
        "displaced-login: $(tilde "$cdir") holds $cur, an account in NEITHER the accounts map nor the roster. Not inventing a dir for an unknown account; $cemail stays displaced until $cur is added to the accounts file or logged into its own dir."
      notify_once "displaced-unknown-$(basename "$cdir")" "A /login wrote unknown account $cur into $(tilde "$cdir"), displacing $cemail. Left untouched, unknown accounts get no invented pool dir."
      continue
    fi
    # a mapping that already names THIS dir for the identity it holds is not a
    # displacement (belt: never move a file onto itself)
    [[ "$fdir" == "$cdir" ]] && continue
    RELOC_STATE=""
    relocate_displaced "$cdir" "$cemail" "$cur" "$fdir" || true
    if [[ "$RELOC_STATE" != "done" ]] && ! grep -qF "$cdir|$cemail|$cur|$fdir" "$pend" 2>/dev/null; then
      # this tick's reconcile already rewrote the map over the evidence, the
      # record is what lets a later (pin-free) tick complete the relocation
      printf '%s|%s|%s|%s\n' "$cdir" "$cemail" "$cur" "$fdir" >> "$pend"
    fi
  done
  return 0
}

# ── macOS Keychain duality: unify every pool dir on the FILE ─────────────────
# Found on the FIRST LIVE TICK (the always-on box, 2026-08-12 08:29): the keeper runs in
# the launchd GUI domain, where the login Keychain is UNLOCKED, so a nudged
# CLI reads and refreshes the PER-DIR Keychain item ("Claude
# Code-credentials-<sha256(dir)[:8]>", hash of the config-dir path) and never
# touches <dir>/.credentials.json. tmux-launched sessions (locked keychain)
# use the FILE. One dir, two copies of one single-use refresh chain: whichever
# refreshes first kills the other, the twin-chain disease inside a single
# dir, and it silently breaks normalize/adopt-shared/switch (they move files
# while the item keeps the old chain invisibly).
#
# The cure runs FIRST in every tick: per pool dir, if an item exists, keep
# whichever copy has the LATER expiresAt (item newer → its blob becomes the
# file, atomically; else the file stands), then DELETE the item either way,
# the dir unifies on the file, the one storage every consumer shares. The
# CLI will recreate the item on its next GUI-domain run; the next tick drains
# it again, always after harvesting a newer chain first, so nothing is lost.
# macOS only (Darwin check); token material is piped, never logged.
KC_UNIFIED=0
dir_keychain_service() {  # the per-config-dir service name the CLI uses
  printf 'Claude Code-credentials-%s' "$(printf '%s' "${1:-}" | shasum -a 256 | cut -c1-8)"
}

keychain_unify_dir() {  # keychain_unify_dir <label> <dir>
  [[ "$(uname -s 2>/dev/null)" == "Darwin" ]] || return 0
  command -v security >/dev/null 2>&1 || return 0
  local label="${1:-}" dir="${2:-}"
  local svc cred blob item_exp file_exp direction tmp drained=0 attempt=0
  svc="$(dir_keychain_service "$dir")"
  security find-generic-password -s "$svc" >/dev/null 2>&1 || return 0
  cred="$dir/.credentials.json"
  # the blob is SECRET: it flows only into jq and (maybe) the credential file
  blob="$(security find-generic-password -s "$svc" -w 2>/dev/null || true)"
  item_exp="$(jq -r '.claudeAiOauth.expiresAt // empty' <<<"$blob" 2>/dev/null || true)"
  file_exp="$(jq -r '.claudeAiOauth.expiresAt // empty' "$cred" 2>/dev/null || true)"
  [[ "$item_exp" =~ ^[0-9]+$ ]] || item_exp=""
  [[ "$file_exp" =~ ^[0-9]+$ ]] || file_exp=""
  direction="kept the FILE (item older/equal/unparseable)"
  if [[ -n "$item_exp" ]] && { [[ -z "$file_exp" ]] || (( item_exp > file_exp )); }; then
    # the Keychain copy is the LIVE chain, it becomes the file, atomically
    tmp="$(mktemp "$cred.unify.XXXXXX" 2>/dev/null || true)"
    if [[ -n "$tmp" ]] && ( umask 077; printf '%s' "$blob" > "$tmp" ) \
       && chmod 600 "$tmp" 2>/dev/null && mv "$tmp" "$cred" 2>/dev/null; then
      direction="imported the KEYCHAIN chain into the file (item expiresAt newer)"
    else
      rm -f "$tmp" 2>/dev/null || true
      direction="FAILED to import the newer keychain chain, file left alone"
    fi
  fi
  # EITHER WAY the item goes: bounded drain, duplicates under one name are real
  while (( attempt < 8 )) && security delete-generic-password -s "$svc" >/dev/null 2>&1; do
    drained=$((drained + 1)); attempt=$((attempt + 1))
  done
  KC_UNIFIED=$((KC_UNIFIED + 1))
  log "keychain-unify ${label:-$(basename "$dir")}: $direction; drained $drained Keychain item(s) for $(tilde "$dir")"
  return 0
}

# ── FIX 4b: complete a fresh machine's migration FROM the keeper ─────────────
# The keeper runs in the GUI launchd domain, the ONE context that can read a
# shared Keychain item; an ssh shell or operator terminal cannot. So during
# bootstrap grace the keeper itself finishes what an operator on a fresh laptop
# would otherwise have to do by hand: harvest the NEWEST shared chain (items vs
# file, expiresAt decides, here the FILE may be the older copy) into the
# shared file, then run adopt-shared, which moves that file into the claim's
# pool dir, writes the dir's .claude.json, and purges the shared items, by
# then the moved file IS the newest chain, so the purge is safe. Rollout on a
# fresh box becomes: pull + install + one keeper tick, zero manual credential
# steps. adopt-shared's own gates stay authoritative (zero live claude
# processes, pool-init'd map); a gated tick defers and retries.
bootstrap_migrate() {
  local shared_dir="$HOME/.claude" shared_cred="$HOME/.claude/.credentials.json"
  local svc blob item_exp file_exp best_blob="" best_exp=""
  # 1. shared newest-wins import (blob is SECRET: flows only into jq/the file)
  for svc in "Claude Code-credentials" "$(dir_keychain_service "$shared_dir")"; do
    security find-generic-password -s "$svc" >/dev/null 2>&1 || continue
    blob="$(security find-generic-password -s "$svc" -w 2>/dev/null || true)"
    item_exp="$(jq -r '.claudeAiOauth.expiresAt // empty' <<<"$blob" 2>/dev/null || true)"
    [[ "$item_exp" =~ ^[0-9]+$ ]] || continue
    if [[ -z "$best_exp" ]] || (( item_exp > best_exp )); then
      best_exp="$item_exp"; best_blob="$blob"
    fi
  done
  file_exp="$(jq -r '.claudeAiOauth.expiresAt // empty' "$shared_cred" 2>/dev/null || true)"
  [[ "$file_exp" =~ ^[0-9]+$ ]] || file_exp=""
  if [[ -n "$best_exp" ]] && { [[ -z "$file_exp" ]] || (( best_exp > file_exp )); }; then
    local tmp
    tmp="$(mktemp "$shared_cred.unify.XXXXXX" 2>/dev/null || true)"
    if [[ -n "$tmp" ]] && ( umask 077; printf '%s' "$best_blob" > "$tmp" ) \
       && chmod 600 "$tmp" 2>/dev/null && mv "$tmp" "$shared_cred" 2>/dev/null; then
      log "bootstrap: imported the newer shared KEYCHAIN chain into $(tilde "$shared_cred") (items left in place, adopt-shared purges them once the move lands)"
    else
      rm -f "$tmp" 2>/dev/null || true
      log "bootstrap: FAILED to import the shared keychain chain, file left alone"
    fi
  fi
  # 4. nothing to migrate at all → say so once, then it is browser logins
  if ! cred_is_complete "$shared_cred"; then
    log_once kc-migrate "none" "bootstrap: no shared login to migrate (no usable shared credential file or Keychain item), each account needs one browser login into its pool dir"
    return 0
  fi
  # 2/3. adopt-shared moves the file into the claim's pool dir. Its own gates
  # decide: exit 3 = live claude session(s) → defer to a process-free tick.
  local ad_out ad_rc=0
  set +e
  ad_out="$(bash "$FAILOVER" adopt-shared 2>&1)"
  ad_rc=$?
  set -e
  if (( ad_rc == 0 )); then
    local mig_email
    mig_email="$(jq -r '.oauthAccount.emailAddress // empty' "$HOME/.claude.json" 2>/dev/null || true)"
    log "bootstrap MIGRATED to the pool layout: $ad_out"
    notify_once "migrated" "Machine migrated to the pool layout, account ${mig_email:-unknown}."
    log_state_clear kc-migrate-defer
    log_state_clear kc-grace
  elif (( ad_rc == 3 )); then
    log_once kc-migrate-defer "live" "bootstrap: live claude session(s) present, deferring adopt-shared to a process-free tick (bootstrap grace continues)"
  elif (( ad_rc == 7 )); then
    log_once kc-migrate-defer "locked" "bootstrap: pool-mutate lock held, deferring adopt-shared to the next tick"
  else
    log_once kc-migrate-fail "rc=$ad_rc" "bootstrap: adopt-shared could not run (rc=$ad_rc): $ad_out"
  fi
  return 0
}

keychain_unify() {
  [[ "$(uname -s 2>/dev/null)" == "Darwin" ]] || return 0
  command -v security >/dev/null 2>&1 || return 0
  local i svc attempt drained
  for i in "${!DIRS[@]}"; do
    keychain_unify_dir "${LABELS[$i]}" "${DIRS[$i]}" || true
  done
  # ── FIX 4: BOOTSTRAP GRACE for the shared items ────────────────────────────
  # On a not-yet-migrated machine (a laptop where the user still runs on the
  # shared ~/.claude login) the LIVE chain most likely sits in the shared Keychain
  # item, deleting it unconditionally would force the CLI back onto a
  # possibly stale-generation file and husk the login. So shared items are
  # drained ONLY once at least one pool dir holds a complete credential;
  # until then they are left entirely alone, and the keeper instead tries to
  # complete the migration itself (bootstrap_migrate, FIX 4b).
  local pool_has_cred=0
  for i in "${!DIRS[@]}"; do
    if cred_is_complete "${DIRS[$i]}/.credentials.json"; then pool_has_cred=1; break; fi
  done
  if (( ! pool_has_cred )); then
    log_once kc-grace "grace" "keychain-unify: bootstrap grace, NO pool dir holds a credential yet; shared Keychain items left in place until a pool login exists"
    bootstrap_migrate
    return 0
  fi
  log_state_clear kc-grace
  # the SHARED dir's items (both service-name shapes): with the pool live, the
  # shared slot is credential-free in v2, so these are stale, plain deletion.
  for svc in "Claude Code-credentials" "$(dir_keychain_service "$HOME/.claude")"; do
    attempt=0; drained=0
    while (( attempt < 8 )) && security delete-generic-password -s "$svc" >/dev/null 2>&1; do
      drained=$((drained + 1)); attempt=$((attempt + 1))
    done
    (( drained > 0 )) && log "keychain-unify shared: drained $drained stale item(s) ($svc)"
  done
  return 0
}

# ── FIX 5: shim-guard, the shim must survive native auto-updates ────────────
# On a NATIVE install the claude self-updater rewrites
# ~/.local/bin/claude to point at ~/.local/share/claude/versions/<new-ver> on
# every upgrade, silently un-installing the shim, after which every launch
# runs unpinned against the shared ~/.claude. Each tick therefore: (a)
# refreshes the stable real-binary symlink ~/.local/libexec/claude-real to the
# newest versions/* entry when that layout exists, and (b) re-links the shim
# whenever ~/.local/bin/claude stops being it (marker check), but ONLY when
# the shim source parses and a real binary stays reachable. Logs on change
# only; the persistent leave-alone states log once.
shim_guard() {
  local shim_src="${CLAUDE_KEEPER_SHIM_SRC:-$ROTA_LIB/rota-shim.sh}"
  local dest="$HOME/.local/bin/claude"
  local versions="$HOME/.local/share/claude/versions"
  local libexec="$HOME/.local/libexec/claude-real"
  [[ -f "$shim_src" ]] || return 0
  if ! bash -n "$shim_src" 2>/dev/null; then
    log_once shim-guard "broken-src" "shim-guard: $shim_src does not parse, leaving $(tilde "$dest") alone"
    return 0
  fi
  # (a) keep the stable real-binary path fresh on the native layout
  local newest=""
  if [[ -d "$versions" ]]; then
    newest="$(ls -t "$versions" 2>/dev/null | head -1)"
    if [[ -n "$newest" && -x "$versions/$newest" ]] \
       && [[ "$(readlink "$libexec" 2>/dev/null || true)" != "$versions/$newest" ]]; then
      mkdir -p "$(dirname "$libexec")" 2>/dev/null || true
      ln -sf "$versions/$newest" "$libexec" \
        && log "shim-guard: refreshed $(tilde "$libexec") -> versions/$newest"
    fi
  fi
  # (b) take the `claude` name back if something (the native updater) took it
  [[ -e "$dest" || -L "$dest" ]] || return 0
  if head -c 4096 "$dest" 2>/dev/null | grep -q 'ROTA_SHIM_MARKER'; then
    log_state_clear shim-guard
    return 0
  fi
  if [[ -x "$libexec" || -x /opt/homebrew/bin/claude || -x /usr/local/bin/claude ]]; then
    local tgt
    tgt="$(readlink "$dest" 2>/dev/null || true)"
    case "$tgt" in
      "$versions"/*)
        # the clobbered link names the freshest real binary, park it first
        mkdir -p "$(dirname "$libexec")" 2>/dev/null || true
        ln -sf "$tgt" "$libexec"
        ;;
    esac
    ln -sf "$shim_src" "$dest"
    log "shim-guard: $(tilde "$dest") was NOT the shim (native auto-update?), re-linked it; the real binary stays reachable at $(tilde "$libexec")"
    log_state_clear shim-guard
  else
    log_once shim-guard "no-real" "shim-guard: $(tilde "$dest") is not the shim and no real binary is reachable, leaving it alone"
  fi
  return 0
}

# ── the nudge (shared by keepalive + warming, same helper, same guards) ─────
# One minimal haiku call, cwd=/ so session-mining tools never count it as
# project work, 60s bound so a wedged CLI cannot wedge the tick.
# Returns 0 = nudged AND VERIFIED (the FILE's expiresAt advanced, possibly
# via a keychain re-unify, see below), 2 = nudged and the file was HUSKED
# (refresh rejected, marked dead + notified), 3 = nudge INEFFECTIVE (CLI ran
# but the file never advanced, no rotation is claimed), 1 = guards refused.
NUDGED=0
nudge_account() {  # nudge_account <label> <dir> <why>
  local label="${1:-}" dir="${2:-}" why="${3:-keepalive}"
  local cred="$dir/.credentials.json" pre_fp pre_exp post_exp tmo=""
  cred_is_complete "$cred" || { log "skip nudge $label: credential incomplete (husk, needs a browser login)"; return 1; }
  refresh_known_dead "$label" "$cred" && { log "skip nudge $label: refresh already rejected for this credential (dead-refresh marker)"; return 1; }
  dir_has_live_process "$dir" && { log "skip nudge $label: a live claude process is pinned to $(tilde "$dir") (it refreshes its own chain)"; return 1; }
  pre_fp="$(cred_fingerprint "$cred" 2>/dev/null || true)"
  pre_exp="$(jq -r '.claudeAiOauth.expiresAt // empty' "$cred" 2>/dev/null || true)"
  [[ "$pre_exp" =~ ^[0-9]+$ ]] || pre_exp=""
  if command -v gtimeout >/dev/null 2>&1; then tmo="gtimeout 60"
  elif command -v timeout >/dev/null 2>&1; then tmo="timeout 60"; fi
  if [[ -z "$tmo" ]]; then
    # stage-2 review: an unbounded nudge can wedge a tick for as long as the
    # CLI hangs, surviveable, but it must at least be VISIBLE, once.
    log "warning: neither gtimeout nor timeout on PATH, the nudge below runs UNBOUNDED (brew install coreutils fixes this)"
    notify_once "no-timeout" "rota keeper: no gtimeout/timeout on this box, keeper nudges run unbounded. brew install coreutils."
  fi
  # shellcheck disable=SC2086  # $tmo is deliberately word-split (cmd + arg)
  (cd / && CLAUDE_CONFIG_DIR="$dir" $tmo claude -p "Reply with exactly: ok" \
    --model claude-haiku-4-5-20251001 >/dev/null 2>&1) || true
  NUDGED=$((NUDGED + 1))
  if ! cred_is_complete "$cred"; then
    # complete going in, husk coming out: the refresh was rejected and the CLI
    # cleared the file. Quarantine (mark dead, touch nothing) + notify once.
    mark_refresh_dead "$label" "$pre_fp"
    log "NUDGE HUSKED $label ($why): refresh rejected, CLI cleared $(tilde "$cred"), marked dead, needs one browser login (CLAUDE_CONFIG_DIR=$(tilde "$dir") claude)"
    notify_once "dead-$label" "$label needs a re-login: its refresh token was rejected. CLAUDE_CONFIG_DIR=$(tilde "$dir") claude"
    return 2
  fi
  # ── HONEST verification (first live tick, 2026-08-12): "persisted" means
  # the FILE's expiresAt ADVANCED. The 08:29 run logged "rotated + persisted"
  # three times while all three files kept their old mtimes and expired
  # tokens, the CLI had refreshed into a just-recreated per-dir Keychain
  # item instead. So: check the file; if it did not advance, unify the
  # keychain item back into it and check AGAIN; only then claim success.
  nudge_file_advanced() {
    post_exp="$(jq -r '.claudeAiOauth.expiresAt // empty' "$cred" 2>/dev/null || true)"
    [[ "$post_exp" =~ ^[0-9]+$ ]] || return 1
    [[ -z "$pre_exp" ]] || (( post_exp > pre_exp ))
  }
  if nudge_file_advanced; then
    log "nudged $label ($why): verified, the FILE's expiresAt advanced"
    return 0
  fi
  keychain_unify_dir "$label" "$dir" || true
  if nudge_file_advanced; then
    log "nudged $label ($why): the CLI refreshed into the per-dir Keychain item, unified back into the file, verified"
    return 0
  fi
  log "NUDGE INEFFECTIVE $label ($why): the CLI ran but the file's expiresAt did not advance (and no newer keychain chain existed), NOT claiming rotation"
  return 3
}

# ── usage fetch (one per account per tick), cache_flush's row shape ──────────
# Per-label results for this tick, consumed by auto-switch + warming.
U_LBL=(); U_WK=(); U_WKR=(); U_SE=(); U_SER=()
FETCHED=0
usage_for() {  # usage_for <label> → index into U_* or empty
  local i
  for i in "${!U_LBL[@]}"; do
    [[ "${U_LBL[$i]}" == "${1:-}" ]] && { printf '%s' "$i"; return 0; }
  done
  return 0
}

fetch_usage() {  # fetch_usage <label> <dir>
  local label="${1:-}" dir="${2:-}" json="" http=""
  local cred="$dir/.credentials.json"
  cred_is_complete "$cred" || return 0
  if [[ -n "${CLAUDE_FAILOVER_USAGE_CMD:-}" ]]; then
    json="$("${CLAUDE_FAILOVER_USAGE_CMD}" "$label" "$dir" 2>/dev/null || true)"
  else
    local token resp
    # the token is read from the FILE *here*, at fetch time, i.e. AFTER the
    # keepalive nudges and the keychain unify have run, never from an
    # earlier in-memory copy. Keep it that way: a token captured before the
    # nudge is exactly the expired one the first live tick 401'd on.
    token="$(jq -r '.claudeAiOauth.accessToken // empty' "$cred" 2>/dev/null || true)"
    [[ -n "$token" ]] || return 0
    resp="$(curl -s --max-time 10 -w $'\n%{http_code}' \
      -H "Authorization: Bearer $token" \
      -H "anthropic-beta: oauth-2025-04-20" \
      -H "User-Agent: $USAGE_UA" \
      "$USAGE_API" 2>/dev/null || true)"
    http="${resp##*$'\n'}"
    if [[ "$http" != "200" ]]; then
      # a persistently failing token (the live 401s) repeats every tick,
      # log ONCE per label+code, re-armed by the next successful fetch
      log_once "usage-${label//[^A-Za-z0-9]/_}" "$http" "usage fetch $label: HTTP ${http:-none}"
      return 0
    fi
    log_state_clear "usage-${label//[^A-Za-z0-9]/_}"
    json="${resp%$'\n'*}"
  fi
  [[ -n "$json" ]] || return 0
  # binding weekly = max(percent) over group=="weekly" in `limits`, falling
  # back to seven_day, the same rule the dashboard's weekly_binding applies.
  local row wk wk_r se se_r
  row="$(printf '%s' "$json" | jq -r '
    ([ (.limits // []) | (if type=="array" then .[] else empty end)
       | select(type=="object" and .group=="weekly" and (.percent|type)=="number") ]
     | sort_by(.percent) | last) as $b
    | [ (if $b == null then ((.seven_day.utilization // "")|tostring) else ($b.percent|tostring) end),
        (if $b == null then (.seven_day.resets_at // "") else ($b.resets_at // "") end),
        ((.five_hour.utilization // "")|tostring),
        (.five_hour.resets_at // "") ]
    | join("\u001f")' 2>/dev/null || true)"
  [[ -n "$row" ]] || return 0
  IFS=$'\x1f' read -r wk wk_r se se_r <<<"$row"
  U_LBL+=("$label"); U_WK+=("$wk"); U_WKR+=("$wk_r"); U_SE+=("$se"); U_SER+=("$se_r")
  FETCHED=$((FETCHED + 1))
  # cache row, cache_flush's exact shape + fetched_at
  local data ts te fa
  ts="$(date '+%b %d %H:%M')"; te="$(date '+%s')"; fa="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  mkdir -p "$CFG_DIR"
  data="$(cat "$USAGE_CACHE" 2>/dev/null || echo '{}')"
  # a corrupt cache (truncated write, disk hiccup) must SELF-HEAL: without
  # this the jq below fails and the junk file lives forever (stage-2 review)
  jq -e . <<<"$data" >/dev/null 2>&1 || data='{}'
  data="$(jq --arg e "$label" --arg wu "$wk" --arg wr "$wk_r" --arg su "$se" \
             --arg sr "$se_r" --arg ts "$ts" --arg te "$te" --arg fa "$fa" \
             '.[$e]={wk_u:$wu,wk_r:$wr,se_u:$su,se_r:$sr,ts:$ts,ts_epoch:$te,fetched_at:$fa}' \
             <<<"$data" 2>/dev/null || printf '%s' "$data")"
  printf '%s' "$data" > "$USAGE_CACHE.tmp.$$" 2>/dev/null \
    && mv "$USAGE_CACHE.tmp.$$" "$USAGE_CACHE" || rm -f "$USAGE_CACHE.tmp.$$"
  return 0
}

pct_int() {  # "91.5" → 91, "" → empty
  local u="${1:-}" i
  [[ -n "$u" ]] || return 0
  i="${u%.*}"; [[ "$i" =~ ^[0-9]+$ ]] || return 0
  printf '%s' "$i"
}

# Is this ISO instant in the past (or absent)? Used by warming: a five-hour
# window is OPEN only when its resets_at is a future instant.
iso_in_past_or_empty() {
  local iso="${1:-}" now
  [[ -n "$iso" ]] || return 0
  now="$(date -u '+%Y-%m-%dT%H:%M:%S')"
  [[ "${iso:0:19}" < "$now" ]]
}

# ── main ─────────────────────────────────────────────────────────────────────
main() {
  command -v jq >/dev/null 2>&1 || { printf 'rota-keeper: jq missing, cannot run\n' >&2; exit 1; }
  mkdir -p "$CFG_DIR"

  if [[ "$KEEPER_DISABLE" == "1" ]]; then
    printf '%s disabled (KEEPER_DISABLE=1)\n' "$(now_local)" > "$STATUS_FILE"
    exit 0
  fi

  # lockfile: mkdir is atomic; a lock older than KEEPER_LOCK_STALE_SECS is a
  # crashed run's, but ONLY when its recorded pid is genuinely gone (stage-2
  # review, finding 7): a live pid with an old mtime is a long-running tick
  # (a wedged unbounded nudge, say), and stealing its lock would put two
  # keepers into the same pool. The re-mkdir after rm is the atomic re-claim:
  # of two would-be takers, exactly one wins it.
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    local lock_age now mt lock_pid
    now="$(date +%s)"
    mt="$(stat -f %m "$LOCK_DIR" 2>/dev/null || stat -c %Y "$LOCK_DIR" 2>/dev/null || echo "$now")"
    lock_age=$(( now - mt ))
    if (( lock_age > KEEPER_LOCK_STALE_SECS )); then
      lock_pid="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
      if [[ "$lock_pid" =~ ^[0-9]+$ ]] && kill -0 "$lock_pid" 2>/dev/null; then
        log "keeper lock is ${lock_age}s old but its pid $lock_pid is STILL LIVE, not taking over (a long tick, not a crash)"
        exit 0
      fi
      log "stale keeper lock (${lock_age}s, pid ${lock_pid:-unknown} gone), taking over"
      rm -rf "$LOCK_DIR" 2>/dev/null || true
      mkdir "$LOCK_DIR" 2>/dev/null || { log "another keeper won the re-claim, exiting"; exit 0; }
    else
      log "another keeper run holds the lock, exiting"
      exit 0
    fi
  fi
  printf '%s\n' "$$" > "$LOCK_DIR/pid" 2>/dev/null || true
  trap 'rm -rf "$LOCK_DIR"' EXIT

  if ! load_accounts; then
    printf '%s no accounts file at %s, nothing to keep\n' \
      "$(now_local)" "$(tilde "$ACCOUNTS_FILE")" > "$STATUS_FILE"
    exit 0
  fi
  [[ -x "$FAILOVER" || -f "$FAILOVER" ]] || { log "engine missing at $FAILOVER"; exit 1; }

  # the accounts map AS IT STOOD at tick start: reconcile (step 1) rewrites
  # the file to match the dirs, which erases the one record of which account
  # each dir was SUPPOSED to hold, the displaced-login detection (step 1b)
  # needs that pre-reconcile snapshot.
  CANON_LBL=("${LABELS[@]}"); CANON_DIR=("${DIRS[@]}")
  # The roster (the accounts file) is read BEFORE reconcile rewrites it, so a
  # displaced login can still be recognised as "in neither map nor roster".
  load_roster

  local st_reconcile="noop" st_switch="none" st_normalize="noop" st_warm="-" st_converge="none"

  # 0. KEYCHAIN UNIFY, FIRST, before anything reads, nudges or moves a
  # credential file: harvest any newer per-dir Keychain chain into its file
  # and drain the items, so every later step (reconcile identity reads, the
  # nudges, normalize's fingerprints, the usage fetch's token) sees ONE
  # storage. macOS only; a no-op elsewhere. See "macOS Keychain duality" above.
  keychain_unify

  # 0b. SHIM-GUARD, re-link the shim if a native auto-update clobbered it and
  # keep ~/.local/libexec/claude-real pointing at the newest native binary.
  shim_guard

  # 1. RECONCILE (mapping only, idempotent; exit 4 = ambiguous, report + go on)
  local rec_out rec_rc=0
  set +e
  rec_out="$(bash "$FAILOVER" reconcile --apply 2>&1)"
  rec_rc=$?
  set -e
  if (( rec_rc == 0 )); then
    if grep -q '^reconciled:' <<<"$rec_out"; then
      st_reconcile="fixed"
      log "reconcile: $(grep '^reconciled:' <<<"$rec_out" | tr '\n' '; ')"
      load_accounts || true   # the mapping just changed under us, reload
    fi
    log_state_clear reconcile-ambiguous
  elif (( rec_rc == 4 )); then
    st_reconcile="ambiguous"
    # persists across ticks until a human re-logins a dir, log ONCE per state
    log_once reconcile-ambiguous "$rec_out" "reconcile: AMBIGUOUS, two dirs hold one identity; not touching the map. $rec_out"
    notify_once "reconcile-ambiguous" "Two pool dirs hold the same account, run rota reconcile and re-login one of them."
  elif (( rec_rc == 7 )); then
    # the pool-mutate lock is held (another mutation mid-flight), a wait,
    # not an error; the next tick retries (stage-2 review, finding 3)
    st_reconcile="locked"
    log "reconcile: pool-mutate lock held, skipping this tick"
  else
    st_reconcile="error"
    log "reconcile failed (rc=$rec_rc): $rec_out"
  fi

  # 1b. DISPLACED-LOGIN RELOCATION, a /login into a pinned pane wrote a
  # foreign account into a pool dir, displacing its canonical account (which
  # no other dir holds, i.e. not a swap). Detected against the pre-reconcile
  # map snapshot + the roster; repaired under the pool-mutate lock,
  # only while no live process is pinned to either dir involved.
  detect_displaced_login

  # 2. KEEPALIVE, nudge chains whose access token is expired/expiring.
  #
  # OFF BY DEFAULT SINCE 2026-08-16. This step was built to PREVENT weekly
  # re-logins; measured over one day on both live boxes it was the thing
  # CAUSING them, and it never once did the job it was built for:
  #
  #   the laptop's keeper.log:        81 NUDGE INEFFECTIVE, 12 NUDGE HUSKED, 0 rotations
  #   the always-on box's keeper.log: 120 NUDGE INEFFECTIVE, 11 NUDGE HUSKED, 0 rotations
  #   → 0 verified rotations in ~201 attempts, 23 husked credential files.
  #
  # By 2026-08-16 09:04 the always-on box's dead-refresh/ held ALL FIVE seats,
  # every marker written that same day (01:00, 02:31, 03:22, 08:12, 09:04).
  # One seat read "✗ cleared, needs login" in `rota accounts` (a 1173-byte husk
  # with an EMPTY refreshToken and expiresAt 0 on the box, and no credential
  # file at all on the laptop), and the seat that 13 live sessions were pinned
  # to was husked at 08:13 in the middle of the working day.
  #
  # WHY IT NEVER ROTATES, read off the laptop's own keeper.log on 2026-08-16.
  # (Reconnaissance only: the follow-up fix is deliberately NOT attempted in
  # the same change that turns the step off.)
  #
  #   (a) NUDGE INEFFECTIVE is STRUCTURAL. The CLI does not refresh an access
  #       token that is still VALID, and KEEPALIVE_MIN=90 fires for the last
  #       90 minutes of an ~8-hour token, so nine nudges in ten cannot rotate
  #       anything even in principle. The log shows one dormant account nudged
  #       at 78, 68, 58, 48, 38, 28, 17 and 7 minutes to expiry with expiresAt
  #       unchanged throughout: the CLI ran eight times and correctly did
  #       nothing each time.
  #   (b) The tenth nudge, the one landing AT/just past expiry, DOES make
  #       the CLI refresh, and the refresh appears to SUCCEED; the keeper just
  #       looks in the wrong place. In the launchd GUI domain the CLI persists
  #       the rotated chain into the PER-DIR KEYCHAIN ITEM and leaves the FILE
  #       husked, and nudge_account's husk branch (`! cred_is_complete` → mark
  #       dead → notify → return 2) fires BEFORE the keychain_unify_dir
  #       re-check that the "did the file advance?" path performs. Evidence:
  #       every one of the laptop's 12 husks is followed at the very NEXT tick by
  #       "keychain-unify …: imported the KEYCHAIN chain into the file (item
  #       expiresAt newer)" for the SAME dir, 12 of 12, +10 min each
  #       (08-12 10:13→10:37, 08-13 02:10→02:20, … 08-16 08:13→08:33). A
  #       newer chain existed minutes after we declared the refresh rejected.
  #
  # So "refresh rejected" is, at best, a misdiagnosis of a rotation the keeper
  # failed to harvest at the moment it mattered, and at worst (the one seat
  # above) a genuine clearing. The step cannot tell the two apart. What it
  # demonstrably ships either way: 23 husked files, 23 dead-refresh markers,
  # 23 false "needs a re-login" notifications, and at least one account that
  # really does need one. Zero measured upside.
  #
  # What still protects the pool without this step: a LIVE session refreshes
  # its own chain (that has always been the normal path, the nudge only ever
  # targeted DORMANT dirs), step 0's keychain-unify keeps whatever the CLI did
  # rotate in the one storage everything reads, and `rota accounts` still shows
  # a husked chain so a re-login is a decision rather than a surprise.
  #
  # KEEPALIVE_ENABLED=1 (keeper.conf or the environment) restores the
  # behaviour above unchanged, knob only, no code removed, so a fix for the
  # ineffective rotation can be validated by flipping it back on. NB step 6
  # (WARMING) shares nudge_account and is deliberately NOT gated by this knob:
  # it fires at most once per account per day against a window we want opened,
  # not every 10 minutes against a token we merely want kept warm.
  local i cred left
  if [[ "$KEEPALIVE_ENABLED" != "1" ]]; then
    log_once keepalive-off "off" "keepalive: DISABLED (KEEPALIVE_ENABLED=0, the 2026-08-16 default), 0 verified rotations in ~201 measured attempts and 23 husked credential files across two machines; live sessions refresh their own chains. Set KEEPALIVE_ENABLED=1 in $(tilde "$CFG_DIR/keeper.conf") to restore it."
  else
    log_state_clear keepalive-off
    for i in "${!DIRS[@]}"; do
      cred="${DIRS[$i]}/.credentials.json"
      cred_is_complete "$cred" || continue
      refresh_known_dead "${LABELS[$i]}" "$cred" && continue
      left="$(token_expiry_in "$cred")"
      [[ -n "$left" ]] || continue
      if (( left < KEEPALIVE_MIN * 60 )); then
        nudge_account "${LABELS[$i]}" "${DIRS[$i]}" "keepalive: token expires in $(( left / 60 ))min" || true
      fi
    done
  fi

  # 3. USAGE, one fetch per account per tick, rows land in usage-cache.json
  for i in "${!DIRS[@]}"; do
    fetch_usage "${LABELS[$i]}" "${DIRS[$i]}" || true
  done

  # 4. AUTO-SWITCH, the claim's binding weekly OR 5h utilization ≥ threshold
  local claim="" ui="" wk="" se=""
  claim="$(jq -r '.oauthAccount.emailAddress // empty' "$HOME/.claude.json" 2>/dev/null || true)"
  if [[ -n "$claim" ]]; then
    ui="$(usage_for "$claim")"
    if [[ -n "$ui" ]]; then
      wk="$(pct_int "${U_WK[$ui]}")"; se="$(pct_int "${U_SE[$ui]}")"
    fi
    if [[ -n "$wk" || -n "$se" ]] && { { [[ -n "$wk" ]] && (( wk >= AUTO_SWITCH_PCT )); } \
                                        || { [[ -n "$se" ]] && (( se >= AUTO_SWITCH_PCT )); }; }; then
      # THE KEEPER'S PICKER. NB a SECOND picker exists: the engine's
      # compute_recommendation (floor/burn-down modes) drives the interactive
      # `rota switch`/`rota usage` surfaces.
      #
      # 2026-08-16, THE OPERATOR DECIDED (asked explicitly). The old rule here was
      # "lowest binding weekly utilization, tie-break soonest weekly reset";
      # his policy is the other way round: "always work on the one that
      # expires next and burn all those tokens before switching to the one
      # right after". So the RANKING is soonest-deadline-first, and the two
      # pickers are INTENTIONALLY ALIGNED on it, that alignment is a decision,
      # not accidental drift, and a future reader should not "fix" it back.
      #
      # ⚠️ AND SINCE 2026-08-28 THAT ALIGNMENT IS ONE FUNCTION, NOT A CONVENTION.
      # Both pickers call rota_seat_deadline + rota_deadline_beats
      # (rota-ranking.sh). The convention was NOT enough: on 2026-08-27 the
      # engine moved to min(weekly reset, SEAT END) and this file did not, so for
      # a cancelled seat whose end date falls before its next weekly reset the two
      # named DIFFERENT seats - live on the pool within days (tartare@ ending
      # 1 Sep, thea.hawk@ ending 6 Sep, both resetting first). Do not re-inline
      # the comparison here, and do NOT "restore" the weekly reset alone: that
      # older rule agrees with this one almost always and is wrong exactly on a
      # cancelled seat's last partial week, which is the one week that cannot be
      # had back.
      #
      # What stays separate is the ELIGIBILITY floors, because they answer WHICH
      # seats may be picked rather than in what ORDER: the leaf runs MIN_WEEKLY
      # (20%-left) + MIN_SESSION (10%-left) for an interactive choice the operator
      # is watching; this one runs AUTO_SWITCH_TARGET_MIN_LEFT_PCT (30%-left) plus
      # the AUTO_SWITCH_TARGET_MAX_PCT ceiling and the bounce hysteresis, because
      # it fires unattended at the 90% wall and must not land the operator on an
      # account that is nearly spent too. Changing either side's floors is
      # still a decision to weigh against the other.
      #
      # Pick: logged in, not dead, not the active, weekly ≤
      # AUTO_SWITCH_TARGET_MAX_PCT (ceiling, default 80) AND at least
      # AUTO_SWITCH_TARGET_MIN_LEFT_PCT weekly left (floor, default 30 → at
      # most 70% used), then the shared ranking. Two refinements it carries that
      # this file used to spell out itself, and which rota_deadline_beats now
      # owns for both callers: an account with NO deadline at all is a fresh
      # window (nothing expiring) and therefore ranks LAST, never first, since an
      # empty string would otherwise sort ahead of every real timestamp; and an
      # exact tie on the deadline keeps the old rule as the tie-break (lowest
      # utilization wins), so the pick stays deterministic where the newer
      # policy is silent.
      local best=-1 best_wk="" best_reset="" best_deadline="" best_kind=""
      local j jwk jreset jends jpair jdeadline jkind
      for j in "${!DIRS[@]}"; do
        [[ "${LABELS[$j]}" == "$claim" ]] && continue
        cred="${DIRS[$j]}/.credentials.json"
        cred_is_complete "$cred" || continue
        refresh_known_dead "${LABELS[$j]}" "$cred" && continue
        ui="$(usage_for "${LABELS[$j]}")"
        [[ -n "$ui" ]] || continue
        jwk="$(pct_int "${U_WK[$ui]}")"
        [[ -n "$jwk" ]] || continue
        (( jwk > AUTO_SWITCH_TARGET_MAX_PCT )) && continue          # ceiling
        (( 100 - jwk < AUTO_SWITCH_TARGET_MIN_LEFT_PCT )) && continue  # headroom floor
        jreset="${U_WKR[$ui]}"
        # The seat's own end date, keyed by the label, which IS the login email
        # and is what billing.json keys its accounts by.
        jends="$(rota_seat_field "$BILLING_JSON" "${LABELS[$j]}" 2)"
        jpair="$(rota_seat_deadline "$jreset" "$jends")"
        jdeadline="${jpair%%$'\t'*}"; jkind="${jpair#*$'\t'}"
        if (( best < 0 )) \
           || rota_deadline_beats "$jdeadline" "$jwk" "$best_deadline" "$best_wk"; then
          best="$j"; best_wk="$jwk"; best_reset="$jreset"
          best_deadline="$jdeadline"; best_kind="$jkind"
        fi
      done
      # hysteresis: don't bounce back to the account we switched OFF within
      # AUTO_SWITCH_BOUNCE_SECS (default 1800)
      if (( best >= 0 )) && [[ -f "$LAST_SWITCH_FILE" ]]; then
        local ls_epoch ls_to ls_from
        # shellcheck disable=SC2034  # ls_to is read positionally to reach ls_from
        read -r ls_epoch ls_to ls_from < "$LAST_SWITCH_FILE" || true
        if [[ "$ls_epoch" =~ ^[0-9]+$ ]] && (( $(date +%s) - ls_epoch < AUTO_SWITCH_BOUNCE_SECS )) \
           && [[ "${LABELS[$best]}" == "${ls_from:-}" ]]; then
          log "auto-switch: holding, ${LABELS[$best]} is the account we left $(( ($(date +%s) - ls_epoch) / 60 ))min ago (bounce hysteresis ${AUTO_SWITCH_BOUNCE_SECS}s)"
          best=-1
        fi
      fi
      if (( best >= 0 )); then
        local sw_args=("switch-all" "${LABELS[$best]}") sw_out sw_rc=0
        [[ "$AUTO_SWITCH_RESTART_IDLE" == "1" ]] && sw_args+=("--restart-idle")
        # ⚠️ THE LOG NAMES THE DATE THAT ACTUALLY BOUND THE PICK. Writing "resets
        # <x>" for a seat chosen because it ENDS first is the right decision under
        # the wrong noun, and this line is the only record of why an unattended
        # switch happened at 03:00. best_kind comes out of the same
        # rota_seat_deadline call that produced the ordering.
        local why_clause="resets ${best_reset:-a fresh window}"
        [[ "$best_kind" == "seat-end" ]] \
          && why_clause="seat ENDS ${best_deadline%%T*}, before its weekly reset (${best_reset:-none}), so this is its LAST window"
        log "auto-switch: $claim at weekly ${wk:-?}% / 5h ${se:-?}% (threshold $AUTO_SWITCH_PCT%) → ${LABELS[$best]} (weekly ${best_wk}%, $why_clause, soonest-deadline pick above the ${AUTO_SWITCH_TARGET_MIN_LEFT_PCT}%-left floor)"
        set +e
        sw_out="$(bash "$FAILOVER" "${sw_args[@]}" 2>&1)"
        sw_rc=$?
        set -e
        if (( sw_rc == 0 )); then
          st_switch="to:${LABELS[$best]}"
          printf '%s %s %s\n' "$(date +%s)" "${LABELS[$best]}" "$claim" > "$LAST_SWITCH_FILE"
          notify_once "auto-switch" "Switched to ${LABELS[$best]}: $claim hit ${wk:-?}% weekly / ${se:-?}% 5h."
          log "auto-switch: done, $sw_out"
          log_state_clear no-target
        else
          st_switch="failed"
          log "auto-switch FAILED (rc=$sw_rc): $sw_out"
        fi
      elif [[ "$st_switch" == "none" ]]; then
        # persists tick after tick while the wall stands, log ONCE per state
        log_once no-target "$claim:$wk:$se" "auto-switch: $claim at weekly ${wk:-?}% / 5h ${se:-?}% ≥ $AUTO_SWITCH_PCT% but no eligible target (all above ${AUTO_SWITCH_TARGET_MAX_PCT}%, under the ${AUTO_SWITCH_TARGET_MIN_LEFT_PCT}%-left floor, dead, or unmeasured)"
        st_switch="no-target"
      fi
    fi
  fi

  # 4b. PANE CONVERGE, the retry loop that makes "every pane ends up on the
  # active account" true for panes that were MID-WORK when the switch happened
  # (the switch's own default restart already covered the idle ones). The leaf
  # verb owns the whole mechanism, tmux resolution, the CLAUDE_CONFIG_DIR pin
  # walk, the mid-work skip, /quit + resume-by-name, so nothing is duplicated
  # here; the keeper contributes the schedule, the log discipline and the
  # status field. PANE_CONVERGE=0 in keeper.conf disables it.
  if [[ "$PANE_CONVERGE" == "1" ]]; then
    local pc_out pc_sum pc_restarted="" pc_busy="" pc_line pc_pane pc_acct
    set +e
    pc_out="$(bash "$FAILOVER" pane-converge 2>&1)"
    set -e
    pc_sum="$(grep '^pane-converge: restarted=' <<<"$pc_out" | tail -1)"
    pc_restarted="$(sed -n 's/.*restarted=\([0-9]*\).*/\1/p' <<<"$pc_sum")"
    pc_busy="$(sed -n 's/.*busy=\([0-9]*\).*/\1/p' <<<"$pc_sum")"
    if [[ -z "$pc_restarted" || -z "$pc_busy" ]]; then
      # no parseable summary, the verb is missing (stale leaf?) or died
      st_converge="error"
      log_once converge-error "$pc_out" "pane-converge: no summary from the leaf, $pc_out"
    else
      log_state_clear converge-error
      # one line per restarted pane, and its busy-key re-armed: if the same
      # pane diverges AGAIN later (another switch), the busy log must repeat
      while IFS= read -r pc_line; do
        [[ -n "$pc_line" ]] || continue
        log "pane-converge: $pc_line"
        pc_pane="${pc_line%% *}"
        log_state_clear "converge-$pc_pane"
      done < <(grep ' restarted onto ' <<<"$pc_out" || true)
      # busy/blocked divergent panes: ONE log line per pane+account, then
      # quiet until that pane's account (or state) changes, the wall can
      # stand for hours and the log must not repeat itself every tick
      while IFS= read -r pc_line; do
        [[ -n "$pc_line" ]] || continue
        pc_pane="${pc_line%% *}"
        pc_acct="$(sed -nE 's/.*(busy on|still on) ([^ ]*).*/\2/p' <<<"$pc_line")"
        log_once "converge-$pc_pane" "$pc_acct:$pc_line" "pane-converge: $pc_line"
      done < <(grep -E ' (busy on|still on) ' <<<"$pc_out" || true)
      if (( pc_restarted > 0 )); then
        st_converge="$pc_restarted"
        (( pc_busy > 0 )) && st_converge="$pc_restarted+busy:$pc_busy"
      elif (( pc_busy > 0 )); then
        st_converge="busy:$pc_busy"
      else
        st_converge="none"
        # fully converged, drop every per-pane busy key so a future
        # divergence of the same pane logs afresh
        find "$CFG_DIR" -maxdepth 1 -name 'keeper-lastlog-converge-*' -delete 2>/dev/null || true
      fi
    fi
  else
    st_converge="off"
  fi

  # 5. NORMALIZE, keyed off the PENDING record reconcile writes (stage-1
  # review, 2026-08-12): once step 1's reconcile has rewritten the map, the
  # labels match the dirs by construction and normalize's own label-mismatch
  # detection can never fire, normalize-pending is the surviving evidence of
  # a crossed pair, so its existence is the trigger. Exit 3 (pinned) is a
  # wait, not an error; the record survives for the next tick.
  if [[ -f "$CFG_DIR/normalize-pending" ]]; then
    local nz_out nz_rc=0
    set +e
    nz_out="$(bash "$FAILOVER" normalize 2>&1)"
    nz_rc=$?
    set -e
    if (( nz_rc == 0 )); then
      if grep -q 'swapping' <<<"$nz_out"; then
        st_normalize="swapped"
        log "normalize: swapped a crossed dir pair back, $nz_out"
      else
        st_normalize="cleared"
        log "normalize: pending record resolved without a swap, $nz_out"
      fi
      log_state_clear normalize
    elif (( nz_rc == 3 )); then
      st_normalize="pinned"
      log_once normalize "pinned" "normalize: pending, live process pinned, will retry next tick"
    elif (( nz_rc == 6 )); then
      # fingerprint mismatch / recovered partial, normalize refused and (for
      # a mismatch) already notified; the pending record survives for a human.
      # Live evidence (2026-08-12): an identical refusal repeated EVERY tick,
      # keyed on the refusal output (which carries the fingerprints), the log
      # gets ONE block per distinct state; keeper-status keeps normalize=manual.
      st_normalize="manual"
      log_once normalize "$nz_rc:$nz_out" "normalize: refused pending replay (manual inspection or next-run completion), $nz_out"
    elif (( nz_rc == 7 )); then
      st_normalize="locked"
      log_once normalize "locked" "normalize: pool-mutate lock held, skipping this tick"
    else
      st_normalize="rc=$nz_rc"
      log_once normalize "$nz_rc:$nz_out" "normalize: rc=$nz_rc, $nz_out"
    fi
  fi

  # 6. SESSION WARMING, once per day at/after WARM_AT, one nudge per cold chain
  local now_hm warm_hm today marker warmed=0
  now_hm="${CLAUDE_KEEPER_NOW_HHMM:-$(date '+%H%M')}"
  warm_hm="${WARM_AT//:/}"
  today="$(date '+%Y-%m-%d')"
  marker="$CFG_DIR/warmed-$today"
  if [[ "$now_hm" =~ ^[0-9]{4}$ && "$warm_hm" =~ ^[0-9]{4}$ ]] \
     && (( 10#$now_hm >= 10#$warm_hm )) && [[ ! -f "$marker" ]]; then
    local warm_undecided=0
    st_warm=0
    for i in "${!DIRS[@]}"; do
      if [[ "$WARM_ACCOUNTS" == "active" ]]; then
        [[ -n "$claim" && "${LABELS[$i]}" == "$claim" ]] || continue
      fi
      cred="${DIRS[$i]}/.credentials.json"
      cred_is_complete "$cred" || continue
      refresh_known_dead "${LABELS[$i]}" "$cred" && continue
      # window OPEN = a five-hour resets_at in the future, or any utilization
      # already spent. Cold = utilization 0 with a null/past resets_at.
      ui="$(usage_for "${LABELS[$i]}")"
      if [[ -z "$ui" ]]; then
        # No usage data AND the stored access token has already expired: the
        # fetch could not have answered and never will until something rotates
        # the token, and with keepalive off this nudge is the only thing that
        # does. So the seat is COLD by construction, not undecided. Before this,
        # four seats on the pool host (2026-08-25 → 08-30) sat in a loop: no data
        # because the token was expired, no nudge because there was no data, 144
        # "retrying next tick" lines a day. Decided either way after the nudge:
        # rotated (measurable next tick), husked (marked dead, skipped from now
        # on) or ineffective (logged by nudge_account, not retried every tick).
        left="$(token_expiry_in "$cred")"
        if [[ -n "$left" ]] && (( left <= 0 )); then
          log "warm ${LABELS[$i]}: no usage data and the stored access token expired $(( -left / 60 ))min ago, cold by construction, nudging once (the nudge is also the only refresh path with keepalive off)"
          if nudge_account "${LABELS[$i]}" "${DIRS[$i]}" "warming: access token expired $(( -left / 60 ))min ago"; then
            warmed=$((warmed + 1))
          fi
          continue
        fi
        # UNDECIDED, not skipped (stage-1 review, 2026-08-12): without usage
        # data we cannot tell open from cold, and stamping the marker anyway
        # would let one transient fetch failure at 03:00 kill warming for the
        # whole day. Leave the marker unwritten so the next tick retries.
        log "warm ${LABELS[$i]}: no usage data this tick (cannot prove the window is closed), not stamping, retrying next tick"
        warm_undecided=1
        continue
      fi
      se="$(pct_int "${U_SE[$ui]}")"
      [[ "$se" == "0" ]] || continue                       # already spending → open
      iso_in_past_or_empty "${U_SER[$ui]}" || continue     # future reset → open
      if nudge_account "${LABELS[$i]}" "${DIRS[$i]}" "warming (WARM_AT=$WARM_AT)"; then
        warmed=$((warmed + 1))
      fi
    done
    st_warm="$warmed"
    if (( warm_undecided )); then
      # at least one eligible account could not be decided, no stamp, retry
      st_warm="retry"
      log "warming: $warmed chain(s) warmed, but an eligible account had no usage data, marker NOT stamped, next tick retries"
    else
      # every eligible account was DECIDED (warmed, or provably open), that
      # includes the "0 qualified" case: the day's warming pass is complete
      printf '%s warmed=%s\n' "$(now_local)" "$warmed" > "$marker"
      # yesterday's markers are litter once the day rolls over
      find "$CFG_DIR" -maxdepth 1 -name 'warmed-*' ! -name "warmed-$today" -delete 2>/dev/null || true
      log "warming: $warmed chain(s) warmed (WARM_AT=$WARM_AT, WARM_ACCOUNTS=$WARM_ACCOUNTS)"
    fi
  fi

  # 7. STATUS, one line, overwritten every tick
  (( DISPLACED > 0 )) && ST_DISPLACED="fixed:$DISPLACED"
  printf '%s reconcile=%s nudged=%s fetched=%s switch=%s converge=%s normalize=%s warmed=%s unify=%s displaced=%s\n' \
    "$(now_local)" "$st_reconcile" "$NUDGED" "$FETCHED" \
    "$st_switch" "$st_converge" "$st_normalize" "$st_warm" "$KC_UNIFIED" "$ST_DISPLACED" > "$STATUS_FILE"
  exit 0
}

main "$@"
