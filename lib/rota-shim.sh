#!/usr/bin/env bash
# ROTA_SHIM_MARKER: this literal string is how the shim recognises a COPY of
# itself sitting on PATH and refuses to exec it. Keep it inside the first 4 KB.
#
# rota-shim.sh, installed by install.sh as ~/.local/bin/claude, ahead of the
# real binary on PATH. All it does is pin each interactive Claude session to ITS
# OWN seat config dir before exec'ing the real binary, then get out of the way.
#
# ── THE PROBLEM IT FIXES ─────────────────────────────────────────────────────
# The complaint that started this, 2026-08-07: "Every week I have to re-login."
# Root cause, established live: OAuth refresh tokens are SINGLE-USE. Today every interactive session runs
# a bare `claude`, which uses the SHARED ~/.claude, while each account's
# credential is kept as a COPY in ~/.claude-pool/<acct>/.credentials.json. The
# moment the live session rotates its token, whatever copy the pool still holds
# is invalidated, so pool copies are structurally guaranteed to rot. Switch back
# to that account and you get a 401, at which point the CLI hollows the file out
# (a ~1296-byte husk: `refreshToken` present but empty, `expiresAt` gone), which
# then reads as "no stored credential" and you are typing /login again.
#
# Headless CI runners never have this problem, and the reason is exactly one
# line of configuration: they set a per-account CLAUDE_CONFIG_DIR and NEVER copy
# a credential anywhere. This shim gives an interactive machine the same property.
#
# ── WHAT IT DOES ─────────────────────────────────────────────────────────────
#   1. CLAUDE_CONFIG_DIR already in the environment  -> change NOTHING, exec.
#      (The runners, the test suites, and any deliberately pinned tmux pane all
#      depend on this. An explicit pin always outranks the shim.)
#   2. Otherwise resolve the ACTIVE account's email and map it to its pool dir
#      via ~/.config/claude-failover/accounts (`<email>|<dir>` per line), then
#      export CLAUDE_CONFIG_DIR=<that dir> and exec.
#   3. If the ACTIVE account cannot host a session, its credential is a husk
#      or missing, or its email has no usable mapping, pin to the FIRST
#      account in the accounts file whose credential IS complete, announcing
#      the swap in exactly one stderr line. See THE 2026-08-16 INCIDENT below
#      for why "just go unpinned" stopped being safe.
#   4. Anything else goes wrong, or NO account anywhere holds a complete
#      credential -> exec the real binary with NO CLAUDE_CONFIG_DIR, i.e.
#      exactly the pre-shim behaviour. That unpinned exec stays the final
#      fallback: with nothing left to pin to, it is also all there is.
#
# ── FAIL OPEN, ALWAYS ────────────────────────────────────────────────────────
# This script sits in front of every `claude` invocation on the box, so its
# single most important property is that it can never be the reason `claude`
# does not start. There is deliberately NO `set -e`: an aborting grep must not
# take the exec with it. Every resolution step answers "no opinion" (empty) on
# failure and the caller falls through to the unpinned exec.
#
# ── WHY THE EMAIL, NOT THE `current` POINTER ─────────────────────────────────
# The engine (rota-engine.sh) keeps an index pointer at ~/.config/claude-failover/
# current, but `switch-all` does NOT update it (verified 2026-08-07): it is the
# LAUNCH slot, not the live one. The account that actually governs is whatever
# credential sits in the shared ~/.claude, which is what ~/.claude.json's
# .oauthAccount.emailAddress reports and what `rota active` prints. We read the file directly (~4 ms) because this runs on every launch,
# and fall back to `active` only when the file cannot answer.
#
# ── FIRST RUN PER ACCOUNT ────────────────────────────────────────────────────
# If an account's pool copy had already rotted before the shim was installed,
# the first pinned session for that account will ask for /login once. That login
# writes a fresh credential into THAT POOL DIR ONLY, it cannot touch any other
# account, which is precisely the guarantee the operator asked for. From then on
# nothing copies that credential, so nothing can invalidate it. One login per
# account, once, and the weekly re-login stops.
#
# ── ENV KNOBS ────────────────────────────────────────────────────────────────
#   CLAUDE_SHIM_DISABLE=1   bypass entirely, resolve nothing, exec the real
#                           binary. The escape hatch if this ever misbehaves.
#   CLAUDE_SHIM_DIRS        colon-list of dirs to look for the real binary in
#                           (default /opt/homebrew/bin:/usr/local/bin). Test hook.
#   CLAUDE_SHIM_RESOLVING   set by the shim around its own call to the engine;
#                           a nested `claude` seeing it
#                           skips resolution, which is what makes recursion
#                           structurally impossible.
#   CLAUDE_FAILOVER_HOME    config dir (default ~/.config/claude-failover),
#                           same variable the engine honours.
#   CLAUDE_FAILOVER_BIN     the engine script (default: the sibling
#                           lib/rota-engine.sh, resolved through the symlink
#                           chain that installed this file as `claude`).
#
# Tests: tests/shim.test.sh (hermetic: fake HOME, stubbed binaries, never
# touches a real credential).

# NO `set -e` on purpose (see FAIL OPEN above). `set -u` is safe: every
# expansion below is defaulted.
set -u

# ~/.local/libexec holds `claude-real` on NATIVE installs (no Homebrew binary;
# the self-installer keeps the real binary at ~/.local/share/claude/versions/
# <ver>, a path that MOVES on every self-update; install.sh and the keeper's
# shim-guard park a stable symlink here instead).
CANDIDATE_DIRS="${CLAUDE_SHIM_DIRS:-/opt/homebrew/bin:/usr/local/bin:$HOME/.local/libexec}"
CFG_DIR="${CLAUDE_FAILOVER_HOME:-$HOME/.config/claude-failover}"
ACCOUNTS_FILE="$CFG_DIR/accounts"

# --- this script's own physical path --------------------------------------
# macOS has no reliable `readlink -f`, so walk the symlink chain by hand. Needed
# so find_real_claude can never pick us, and so the sibling engine script can be
# found next to the REAL file (this one is installed as a symlink).
_self="${BASH_SOURCE[0]}"
while [ -h "$_self" ]; do
  _d="$(cd -P "$(dirname "$_self")" 2>/dev/null && pwd)" || break
  _link="$(readlink "$_self")" || break
  case "$_link" in
    /*) _self="$_link" ;;
    *)  _self="$_d/$_link" ;;
  esac
done
_selfdir="$(cd -P "$(dirname "$_self")" 2>/dev/null && pwd)" || _selfdir=""
[ -n "$_selfdir" ] && _self="$_selfdir/$(basename "$_self")"

# Sibling resolution: every lib script lives in one dir, so the engine is next
# to the resolved physical path of this file. CLAUDE_FAILOVER_BIN overrides it
# (the hermetic suite points it at a stub).
ROTA_LIB="$_selfdir"
ENGINE="${CLAUDE_FAILOVER_BIN:-$ROTA_LIB/rota-engine.sh}"

# A candidate that is a COPY of this script (not a symlink to it, which `-ef`
# already catches) would loop forever. Only consulted on the cold PATH-scan
# path, so the two subprocesses cost nothing on a normal launch.
looks_like_shim() {
  head -c 4096 "${1:-}" 2>/dev/null | grep -q 'ROTA_SHIM_MARKER' 2>/dev/null
}

# The real `claude`, resolved robustly and WITHOUT hardcoding a version path
# (the Homebrew entry is itself a symlink into
# ../lib/node_modules/@anthropic-ai/claude-code/, which moves on every upgrade).
find_real_claude() {
  local d c
  local IFS=:
  for d in $CANDIDATE_DIRS; do
    [ -n "$d" ] || continue
    # `claude-real` is the native-install spelling (see CANDIDATE_DIRS above);
    # the -ef self-check holds for both names.
    for c in "$d/claude" "$d/claude-real"; do
      [ -f "$c" ] && [ -x "$c" ] || continue
      [ "$c" -ef "$_self" ] 2>/dev/null && continue
      printf '%s' "$c"
      return 0
    done
  done
  # Fallback: scan PATH. Skip our own directory outright (that is the realistic
  # self-hit: ~/.local/bin is first on PATH), then -ef, then the marker.
  for d in $PATH; do
    [ -n "$d" ] || continue
    if [ -n "$_selfdir" ] && [ "$d" -ef "$_selfdir" ] 2>/dev/null; then continue; fi
    c="$d/claude"
    [ -f "$c" ] && [ -x "$c" ] || continue
    [ "$c" -ef "$_self" ] 2>/dev/null && continue
    looks_like_shim "$c" && continue
    printf '%s' "$c"
    return 0
  done
  return 1
}

# exec the real binary, never returns. The one exit that is NOT fail-open is
# "there is no claude on this box at all", where there was nothing to run anyway.
exec_real() {
  local real
  real="$(find_real_claude)"
  if [ -z "$real" ]; then
    printf 'rota-shim: no real `claude` binary found (looked in %s, then on PATH).\n' \
      "$CANDIDATE_DIRS" >&2
    printf 'rota-shim: install it (`brew install claude-code` or the native installer) or set CLAUDE_SHIM_DIRS.\n' >&2
    exit 127
  fi
  exec "$real" "$@"
}

# --- account resolution ----------------------------------------------------
# Is this a credential we can safely pin a session to? Complete, not a husk: the
# file parses far enough to show a NON-EMPTY refreshToken and an expiresAt. A
# husk is what the CLI leaves behind after a 401, and pinning to one would put a
# login prompt in front of the operator for no reason, so a husk routes the launch
# to another account's dir instead (see THE 2026-08-16 INCIDENT below).
# Deliberately grep-only (no jq): two greps on a ~1 KB file
# beat a JSON parse on the hot path, and the token value is never materialised.
cred_complete() {
  local f="${1:-}"
  [ -n "$f" ] && [ -f "$f" ] && [ -s "$f" ] || return 1
  grep -q '"refreshToken"[[:space:]]*:[[:space:]]*"[^"]' "$f" 2>/dev/null || return 1
  grep -q '"expiresAt"[[:space:]]*:' "$f" 2>/dev/null || return 1
  return 0
}

# The email the shared ~/.claude is currently logged in as. Cheap read first
# (jq ~4 ms on the real 3 MB config, grep as the no-jq fallback), then
# `rota-engine.sh active`, which is authoritative but costs a bash start-up, so
# it is the fallback rather than the default.
active_email() {
  local f="$HOME/.claude.json" e="" tmo=""
  if [ -f "$f" ]; then
    if command -v jq >/dev/null 2>&1; then
      e="$(jq -r '.oauthAccount.emailAddress // empty' "$f" 2>/dev/null)"
    fi
    if [ -z "$e" ]; then
      e="$(grep -o '"emailAddress"[[:space:]]*:[[:space:]]*"[^"]*"' "$f" 2>/dev/null \
             | head -1 \
             | sed 's/.*"emailAddress"[[:space:]]*:[[:space:]]*"//; s/"$//')"
    fi
  fi
  if [ -z "$e" ] && [ -f "$ENGINE" ]; then
    # Bound it: a wedged engine must not wedge every `claude` launch.
    if command -v gtimeout >/dev/null 2>&1; then tmo="gtimeout 5"
    elif command -v timeout >/dev/null 2>&1; then tmo="timeout 5"; fi
    # CLAUDE_SHIM_RESOLVING makes any nested `claude` this spawns skip straight
    # to exec, the recursion guard.
    # "$BASH", not `bash`: this runs under a possibly minimal PATH (launchd,
    # the hermetic suite) where the interpreter is only known by its own path.
    e="$(CLAUDE_SHIM_RESOLVING=1 $tmo "$BASH" "$ENGINE" active 2>/dev/null | head -1)"
  fi
  e="${e%$'\r'}"
  printf '%s' "$e"
}

# email -> config dir, out of the accounts file. Same parse as the engine's
# load_accounts(): `<label>|<dir>`, whitespace stripped, `#` comments and
# blanks skipped. Prints nothing (not an error) when there is no match.
dir_for_email() {
  local want="${1:-}" label dir
  [ -n "$want" ] || return 0
  [ -f "$ACCOUNTS_FILE" ] || return 0
  while IFS='|' read -r label dir || [ -n "${label:-}" ]; do
    label="${label//[$' \t\r']/}"
    dir="${dir//[$' \t\r']/}"
    [ -n "$label" ] || continue
    case "$label" in \#*) continue ;; esac
    if [ "$label" = "$want" ]; then
      # shellcheck disable=SC2088  # matching a LITERAL "~/" written in the
      # accounts file (a data value, not a path this shell is expanding) and
      # expanding it ourselves, which is exactly what SC2088 asks for.
      case "$dir" in "~/"*) dir="$HOME/${dir#\~/}" ;; esac
      printf '%s' "$dir"
      return 0
    fi
  done < "$ACCOUNTS_FILE"
  return 0
}

# The identity a pool DIR actually holds: .oauthAccount.emailAddress out of
# <dir>/.claude.json. Empty = unknowable (never logged in there, or no jq and
# the grep found nothing). Same cheap-read discipline as active_email, this
# runs on the launch hot path, so it is a file read, never a subprocess tree.
dir_identity() {
  local d="${1:-}" f e=""
  [ -n "$d" ] || return 0
  f="$d/.claude.json"
  [ -f "$f" ] || return 0
  if command -v jq >/dev/null 2>&1; then
    e="$(jq -r '.oauthAccount.emailAddress // empty' "$f" 2>/dev/null)"
  fi
  if [ -z "$e" ]; then
    e="$(grep -o '"emailAddress"[[:space:]]*:[[:space:]]*"[^"]*"' "$f" 2>/dev/null \
           | head -1 \
           | sed 's/.*"emailAddress"[[:space:]]*:[[:space:]]*"//; s/"$//')"
  fi
  printf '%s' "$e"
}

# Flag that the accounts-file mapping no longer matches what the dirs hold, so
# the keeper's next tick (or a manual `rota reconcile`) rewrites the map.
# Best-effort and silent: the flag is a hint, never a reason to break a launch.
flag_needs_reconcile() {
  mkdir -p "$CFG_DIR" 2>/dev/null || return 0
  touch "$CFG_DIR/needs-reconcile" 2>/dev/null || true
}

# Scan every dir in the accounts file for the ONE whose identity is <email>.
# Prints that dir only when the match is unique; empty on zero or ambiguous.
# The scan is one jq read per pool dir (4 dirs ≈ sub-10ms) and only runs on the
# mismatch path, so a healthy launch never pays for it.
dir_by_identity() {
  local want="${1:-}" label dir hit="" n=0
  [ -n "$want" ] || return 0
  [ -f "$ACCOUNTS_FILE" ] || return 0
  while IFS='|' read -r label dir || [ -n "${label:-}" ]; do
    label="${label//[$' \t\r']/}"
    dir="${dir//[$' \t\r']/}"
    [ -n "$label" ] || continue
    case "$label" in \#*) continue ;; esac
    [ -n "$dir" ] || continue
    # shellcheck disable=SC2088  # literal "~/" data value, expanded by hand
    case "$dir" in "~/"*) dir="$HOME/${dir#\~/}" ;; esac
    [ -d "$dir" ] || continue
    if [ "$(dir_identity "$dir")" = "$want" ]; then
      n=$((n + 1))
      hit="$dir"
    fi
  done < "$ACCOUNTS_FILE"
  [ "$n" -eq 1 ] && printf '%s' "$hit"
  return 0
}

# ── THE 2026-08-16 INCIDENT: a husk must not strand the session ─────────────
# Under pool v2 the shared ~/.claude deliberately holds NO credential, every
# working login lives in its own pool dir. That quietly inverted what "fail
# open" meant here: when the ACTIVE account's pool credential was a husk, the
# shim shrugged and fell through to the UNPINNED shared dir… which under v2
# has nothing to log in with. Observed live on 2026-08-16: seat A's pool
# credential was the ~1296-byte 401 husk, so every launch on that account came
# up "Not logged in · Please run /login", a GUARANTEED dead session, while the
# other four seats all sat right there with complete, working credentials. "Fail open to the shared dir" is only open when the shared dir
# can actually host a session; under v2 it never can, so a broken active
# account now borrows the pool instead. Rescue order (identity checks added
# 2026-08-16, the accounts file is an auto-reconciled cache that can lie, and
# a lying label here would re-create the 2026-08-11 wrong-account billing):
# the active account's own mapped dir first (unchanged), then the dir whose
# .claude.json ACTUALLY holds the active identity (a typo'd label must not
# push the launch onto a foreign account while the account's own healthy dir
# sits right there), then the FIRST account in the accounts file whose
# credential passes cred_complete() AND whose dir's identity matches its
# label: file order is the operator's priority order, same as the engine
# reads it. Only when NO account anywhere holds a complete credential
# does the shim fall through to the old unpinned exec, which stays the final
# fallback: with a fully dead pool there is nothing better to offer, and the
# shim must still never be the reason `claude` does not start.

# The companion to dir_for_email: instead of mapping ONE email, walk the file
# IN FILE ORDER and print `<email>|<dir>` for the first entry whose dir holds
# a COMPLETE credential. Same parse as dir_for_email, same fail-open contract
# (empty stdout on any failure, never an error). Skips the shared ~/.claude,
# offering it as a rescue would just be the nested-config trap with extra
# steps. Only ever runs on the already-broken path, so its per-entry
# cred_complete (two greps) costs a healthy launch nothing.
first_complete_account() {
  local label dir ident
  [ -f "$ACCOUNTS_FILE" ] || return 0
  while IFS='|' read -r label dir || [ -n "${label:-}" ]; do
    label="${label//[$' \t\r']/}"
    dir="${dir//[$' \t\r']/}"
    [ -n "$label" ] || continue
    case "$label" in \#*) continue ;; esac
    [ -n "$dir" ] || continue
    # shellcheck disable=SC2088  # literal "~/" data value, expanded by hand
    case "$dir" in "~/"*) dir="$HOME/${dir#\~/}" ;; esac
    [ -d "$dir" ] || continue
    [ "$dir" -ef "$HOME/.claude" ] 2>/dev/null && continue
    cred_complete "$dir/.credentials.json" || continue
    # (2026-08-16) The borrowed row's LABEL is what the diagnostic announces
    # and what the operator will believe the session bills, so a row whose
    # dir ACTUALLY holds a different identity must not be borrowed under that
    # label: that is the 2026-08-11 wrong-account swap all over again, just
    # entered through the rescue door. A KNOWN mismatch skips the row and
    # flags the keeper; an EMPTY identity stays acceptable (unknowable is not
    # a lie, and refusing it would turn fail-open into fail-closed).
    ident="$(dir_identity "$dir")"
    if [ -n "$ident" ] && [ "$ident" != "$label" ]; then
      flag_needs_reconcile
      continue
    fi
    printf '%s|%s' "$label" "$dir"
    return 0
  done < "$ACCOUNTS_FILE"
  return 0
}

# The rescue itself: given the active email, print the fallback dir on stdout
# resolve_pool_dir's answer channel, and exactly ONE line on stderr saying
# what the session is doing about it. Stderr, never stdout: `claude -p … | jq`
# is a real shape, and a stray line on stdout would corrupt the caller's data.
# Empty stdout when no account qualifies, which is precisely what lets the
# caller keep the unpinned exec as the final fallback.
#
# (2026-08-16) Identity before borrowing: the thing that routed the launch
# here may be the accounts FILE, not the account, a typo'd label means
# dir_for_email finds nothing while the active account's own dir sits healthy
# in the pool. Borrowing a foreign account then silently bills the wrong one
# (the 2026-08-11 failure class), so the pool is scanned for the dir whose
# .claude.json actually holds the active identity FIRST, and only when no
# such dir can host a session does the borrow happen.
fallback_pin() {
  local active="${1:-}" own hit fb_email fb_dir
  if [ -n "$active" ]; then
    own="$(dir_by_identity "$active")"
    if [ -n "$own" ] && [ -d "$own" ] \
       && ! [ "$own" -ef "$HOME/.claude" ] 2>/dev/null \
       && cred_complete "$own/.credentials.json"; then
      flag_needs_reconcile
      printf 'rota-shim: accounts-file row for active %s is broken/mislabeled, but its own dir was found by identity, pinning %s\n' \
        "$active" "$own" >&2
      printf '%s' "$own"
      return 0
    fi
  fi
  hit="$(first_complete_account)"
  [ -n "$hit" ] || return 0
  fb_email="${hit%%|*}"
  fb_dir="${hit#*|}"
  [ -n "$fb_dir" ] && [ -d "$fb_dir" ] || return 0
  printf 'rota-shim: active %s cannot host a session (credential husk/missing or unmapped), pinning to %s instead\n' \
    "$active" "$fb_email" >&2
  printf '%s' "$fb_dir"
}

# The whole decision, in one place. Empty stdout = "no opinion", fail open.
resolve_pool_dir() {
  local email dir found
  email="$(active_email)"
  [ -n "$email" ] || return 0
  # Guard against `active` having printed a diagnostic instead of an address.
  case "$email" in *@*) ;; *) return 0 ;; esac

  dir="$(dir_for_email "$email")"
  # No usable mapping for the ACTIVE account, not in the file, or the mapped
  # dir is gone. Same rescue as a husk: any other account's complete credential
  # beats a credential-less shared dir (THE 2026-08-16 INCIDENT above).
  if [ -z "$dir" ] || [ ! -d "$dir" ]; then
    fallback_pin "$email"
    return 0
  fi

  # ── IDENTITY VERIFICATION (pool v2, 2026-08-11) ──────────────────────────
  # The accounts file is positional and can lie: a /login inside a pinned pane
  # once wrote the work account into the `personal` pool dir, and from then on
  # every "personal" launch silently billed the work seat. So the mapped dir's own .claude.json is
  # checked against the email we resolved it FOR. On mismatch, the dir that
  # actually holds the identity wins (when there is exactly one); zero or two+
  # matches fall back to the mapped dir, today's behaviour, and either way
  # the needs-reconcile flag tells the keeper to fix the map.
  found="$(dir_identity "$dir")"
  if [ -n "$found" ] && [ "$found" != "$email" ]; then
    flag_needs_reconcile
    _alt="$(dir_by_identity "$email")"
    if [ -n "$_alt" ] && [ -d "$_alt" ]; then
      dir="$_alt"
    fi
  fi

  # Never pin AT the shared dir: CLAUDE_CONFIG_DIR=$HOME/.claude makes the CLI
  # read the NESTED ~/.claude/.claude.json instead of the ~/.claude.json real
  # sessions use, the nested-config trap `rota repair-nested` exists for.
  [ "$dir" -ef "$HOME/.claude" ] 2>/dev/null && return 0

  # The active account's own credential is a husk (or missing). Pre-2026-08-16
  # this returned empty, "fail open" to the shared dir, which under pool v2
  # guarantees a dead session. Borrow the first working account instead; only
  # a fully dead pool still falls through unpinned.
  if ! cred_complete "$dir/.credentials.json"; then
    fallback_pin "$email"
    return 0
  fi
  printf '%s' "$dir"
}

# --- main ------------------------------------------------------------------
# Escape hatch, then the recursion guard, then "an explicit pin always wins".
# `+set` not `:-`: respecting the variable's PRESENCE (even empty) is the
# literal reading of "already set in the environment -> change nothing".
[ -n "${CLAUDE_SHIM_DISABLE:-}" ]   && exec_real "$@"
[ -n "${CLAUDE_SHIM_RESOLVING:-}" ] && exec_real "$@"
[ -n "${CLAUDE_CONFIG_DIR+set}" ]   && exec_real "$@"

_pool_dir="$(resolve_pool_dir)"
if [ -n "$_pool_dir" ]; then
  export CLAUDE_CONFIG_DIR="$_pool_dir"
fi

exec_real "$@"
