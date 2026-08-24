#!/usr/bin/env bash
#
# rota-cred-guard.sh: the safety net under the per-session CLAUDE_CONFIG_DIR
# pinning that lib/rota-shim.sh installs. Two jobs, both non-destructive:
#
#   (a) BACKUP RING. Keep the last N (default 10) versions of every
#       ~/.claude-pool/*/.credentials.json plus ~/.claude/.credentials.json under
#       ~/.config/claude-failover/backups/<acct>/<ISO>.json, mode 0600. Only
#       archive when the bytes actually CHANGED (sha256 compare) and only when
#       the credential is COMPLETE, never a husk. That last rule matters: after
#       a 401 the CLI hollows the file out to a ~1296-byte husk (`refreshToken`
#       present but empty, `expiresAt` gone), and archiving ten husks in a row
#       would evict the last ten GOOD copies, turning the safety net into the
#       thing that loses the credential.
#
#   (b) IDENTITY-DRIFT DETECTION, the /login protection. The operator, 2026-08-07:
#       "sometimes I have to do /login and then login to a new account, but we
#       want to make sure that doesn't overwrite the existing credentials." With
#       the shim installed each pane is pinned to one pool dir, so a /login as a
#       DIFFERENT account writes that account into the pinned dir. This detects
#       exactly that, <dir>/.claude.json's .oauthAccount.emailAddress no longer
#       matching the label that dir is mapped to in the accounts file, and then
#       does NOT touch a thing. It snapshots what arrived, then reports which
#       dir, which account was expected, which one arrived, and the exact
#       commands for either remedy. A destructive auto-move is deliberately out
#       of scope; the goal is only that nothing is ever unrecoverable.
#
# Restore is explicit and manual:
#   rota cred-restore <account> --list   list backups (ts, identity, state)
#   rota cred-restore <account>          newest COMPLETE backup for that
#                                                   identity, after backing up what
#                                                   it replaces
#
# <account> is the accounts-file label (the email), the pool dir's basename
# (`work`, `personal`, `team`), or `shared` for ~/.claude.
#
# NOT the same thing as ~/.config/claude-failover/creds/. That directory is a
# legacy login stash: exactly ONE file per email, overwritten by the next login
# for that account, with no completeness check. It is a hand-off, not a history.
# This ring is N-deep, keyed on the config DIR, and refuses to store a husk.
#
# NEVER PRINTS A TOKEN. Completeness is checked with `jq -e` into /dev/null and
# identity/changes are compared by sha256, no token value is ever materialised
# into a shell variable, let alone stdout or a log.
#
# Scheduled every 300s by launchd (com.rota.cred-guard). launchd
# starts jobs with a MINIMAL PATH, which is why this script exports a real one
# below before anything looks for jq, an unresolved jq silently killed an
# overnight job on 2026-08-07.
#
# Env knobs (all also used by the hermetic suite, tests/cred-guard.test.sh):
#   CLAUDE_FAILOVER_BIN         the engine script (default: sibling lib/rota-engine.sh)
#   CLAUDE_FAILOVER_HOME        config dir (default ~/.config/claude-failover)
#   CLAUDE_CRED_GUARD_BACKUPS   backup root (default <cfg>/backups)
#   CLAUDE_CRED_GUARD_KEEP      ring size (default 10)
#   CLAUDE_POOL_DIR             pool root (default ~/.claude-pool)
#   CLAUDE_CRED_GUARD_NO_NOTIFY 1 = never post a macOS notification

set -euo pipefail

# launchd gives a job PATH=/usr/bin:/bin:/usr/sbin:/sbin, no jq, no shim dir.
# Prepend the real ones; anything inherited stays reachable behind them.
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:/usr/bin:/bin${PATH:+:$PATH}"

CFG_DIR="${CLAUDE_FAILOVER_HOME:-$HOME/.config/claude-failover}"
ACCOUNTS_FILE="$CFG_DIR/accounts"
BACKUP_ROOT="${CLAUDE_CRED_GUARD_BACKUPS:-$CFG_DIR/backups}"
POOL_ROOT="${CLAUDE_POOL_DIR:-$HOME/.claude-pool}"
SHARED_DIR="$HOME/.claude"
KEEP="${CLAUDE_CRED_GUARD_KEEP:-10}"
DRIFT_STATE="$CFG_DIR/cred-guard-drift"
REPORT_FILE="$CFG_DIR/cred-guard-report.txt"

SELF_NAME="$(basename "${BASH_SOURCE[0]}")"
ROTA_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"

# The engine, for the pool-v2 escalation: a detected drift is first handed to
# `reconcile --apply` (mapping-only, never a credential byte) and only what
# REMAINS is reported. Resolution order: an explicit override (the hermetic
# suite), then the sibling script in the same lib/ dir. Prints nothing when
# neither exists, and the caller degrades to report-only.
failover_leaf() {
  if [ -n "${CLAUDE_FAILOVER_BIN:-}" ]; then printf '%s' "$CLAUDE_FAILOVER_BIN"; return 0; fi
  if [ -f "$ROTA_LIB/rota-engine.sh" ]; then
    printf '%s' "$ROTA_LIB/rota-engine.sh"; return 0
  fi
  return 0
}

# ~/-abbreviated path, for messages a human reads (same helper as the engine).
tilde() { printf '%s' "${1/#$HOME/~}"; }

die() { printf '%s: %s\n' "$SELF_NAME" "$*" >&2; exit 1; }

usage() {
  cat <<EOF
$SELF_NAME, backup ring + identity-drift detection for the Claude account pool.

  $SELF_NAME [run]                    snapshot changed+complete credentials, prune to
                                      $KEEP, then check every pool dir's identity.
                                      Exit 0 = clean, 2 = drift detected.
  $SELF_NAME restore <account> --list  list that account's backups (newest first)
  $SELF_NAME restore <account>         restore its newest COMPLETE backup, after
                                      backing up whatever it replaces
  $SELF_NAME --help

<account> = the accounts-file label (email), the pool dir basename, or 'shared'.
Backups: $(tilde "$BACKUP_ROOT")/<acct>/<ISO>.json (0600, last $KEEP).
EOF
}

# --- accounts file ---------------------------------------------------------
# Parsed exactly like the engine's load_accounts(): `<label>|<dir>`,
# whitespace stripped, blanks and `#` comments skipped. A MISSING accounts file
# is not fatal here, the backup ring still works off the pool glob; only the
# drift check needs the mapping, and it says so rather than dying.
LABELS=(); DIRS=()
load_accounts() {
  LABELS=(); DIRS=()
  [ -f "$ACCOUNTS_FILE" ] || return 0
  local label dir
  while IFS='|' read -r label dir || [ -n "${label:-}" ]; do
    label="${label//[$' \t\r']/}"
    dir="${dir//[$' \t\r']/}"
    [ -n "$label" ] || continue
    case "$label" in \#*) continue ;; esac
    [ -n "$dir" ] || continue
    # shellcheck disable=SC2088  # matching a LITERAL "~/" written in the accounts
    # file (a data value) and expanding it ourselves, what SC2088 asks for.
    case "$dir" in "~/"*) dir="$HOME/${dir#\~/}" ;; esac
    LABELS+=("$label")
    DIRS+=("$dir")
  done < "$ACCOUNTS_FILE"
}

label_for_dir() {  # accounts-file label mapped to this dir, or empty
  local want="${1:-}" i
  for (( i = 0; i < ${#DIRS[@]}; i++ )); do
    if [ "${DIRS[$i]}" = "$want" ]; then printf '%s' "${LABELS[$i]}"; return 0; fi
    if [ -d "$want" ] && [ -d "${DIRS[$i]}" ] && [ "${DIRS[$i]}" -ef "$want" ]; then
      printf '%s' "${LABELS[$i]}"; return 0
    fi
  done
  return 0
}

dir_for_label() {  # accounts-file label -> dir, or empty
  local want="${1:-}" i
  for (( i = 0; i < ${#LABELS[@]}; i++ )); do
    [ "${LABELS[$i]}" = "$want" ] && { printf '%s' "${DIRS[$i]}"; return 0; }
  done
  return 0
}

# --- credential + identity primitives --------------------------------------
# The default dir keeps its config JSON one level UP as ~/.claude.json; an
# explicit CLAUDE_CONFIG_DIR keeps it inside the dir. Same rule as the engine's
# config_json(), getting this wrong is the nested-config trap.
config_json() {
  local dir="${1:-}"
  if [ "$dir" = "$SHARED_DIR" ] || { [ -d "$dir" ] && [ "$dir" -ef "$SHARED_DIR" ]; }; then
    printf '%s' "$HOME/.claude.json"
  else
    printf '%s' "$dir/.claude.json"
  fi
}

# .oauthAccount.emailAddress out of a dir's config JSON. Empty when unknowable.
identity_of_dir() {
  local f e=""
  f="$(config_json "${1:-}")"
  [ -f "$f" ] || { printf ''; return 0; }
  if command -v jq >/dev/null 2>&1; then
    e="$(jq -r '.oauthAccount.emailAddress // empty' "$f" 2>/dev/null || true)"
  fi
  if [ -z "$e" ]; then
    e="$(grep -o '"emailAddress"[[:space:]]*:[[:space:]]*"[^"]*"' "$f" 2>/dev/null \
           | head -1 | sed 's/.*"emailAddress"[[:space:]]*:[[:space:]]*"//; s/"$//' || true)"
  fi
  printf '%s' "$e"
}

# A COMPLETE credential: parses, non-empty .claudeAiOauth.refreshToken, and an
# expiresAt that is present. `jq -e` answers with its EXIT CODE and its stdout
# goes to /dev/null, so the token is never bound to a variable, the one shape
# of this check that cannot leak.
cred_complete() {
  local f="${1:-}"
  [ -n "$f" ] && [ -f "$f" ] && [ -s "$f" ] || return 1
  if command -v jq >/dev/null 2>&1; then
    jq -e '(.claudeAiOauth.refreshToken // "") != "" and (.claudeAiOauth.expiresAt != null)' \
      "$f" >/dev/null 2>&1
  else
    grep -q '"refreshToken"[[:space:]]*:[[:space:]]*"[^"]' "$f" 2>/dev/null &&
      grep -q '"expiresAt"[[:space:]]*:' "$f" 2>/dev/null
  fi
}

file_sha() {  # sha256 of a file, a hash, never a token slice
  [ -f "${1:-}" ] || return 0
  shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
}

# --- backup ring -----------------------------------------------------------
# The ring is keyed on the config dir's BASENAME (`work`, `personal`, ...), with
# `shared` for ~/.claude, stable, filesystem-safe, and readable in a listing.
acct_key() {
  local dir="${1:-}"
  if [ "$dir" = "$SHARED_DIR" ] || { [ -d "$dir" ] && [ "$dir" -ef "$SHARED_DIR" ]; }; then
    printf 'shared'
  else
    printf '%s' "$(basename "$dir")"
  fi
}

ring_dir()     { printf '%s' "$BACKUP_ROOT/${1:-}"; }
replaced_dir() { printf '%s' "$BACKUP_ROOT/${1:-}/replaced"; }

# Newest ring entry for a key, or empty. Names sort lexically because every one
# of them ends in a fixed-width `-NN` sequence (see next_backup_path).
latest_backup() {
  local d f last=""
  d="$(ring_dir "${1:-}")"
  [ -d "$d" ] || return 0
  for f in "$d"/*.json; do
    [ -f "$f" ] || continue
    last="$f"
  done
  printf '%s' "$last"
}

# The next `<ISO>-NN.json` path, guaranteed to sort AFTER every entry already in
# the ring. macOS `date` has no sub-second format, so a fixed-width two-digit
# sequence is what keeps same-second writes collision-free AND ordered, a bare
# `-2` suffix would sort BEFORE the unsuffixed name ('-' < '.').
#
# The sequence must be MONOTONIC, not merely free. Taking the first unused slot
# is the obvious implementation and it is wrong: prune_ring deletes from the
# FRONT, so after a prune the `-00` name is available again, and reusing it
# writes the NEWEST credential under the OLDEST-sorting name, where the same
# run's prune then deletes it on the spot. That lost one generation roughly one
# run in three (caught by the prune scenario in the test suite, which is why it
# seeds a ring with a freed early slot).
next_backup_path() {
  local key="${1:-}" d ts last base lastts lastn n cand
  d="$(ring_dir "$key")"
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  n=0
  last="$(latest_backup "$key")"
  if [ -n "$last" ]; then
    base="${last##*/}"; base="${base%.json}"      # <ts>-<NN>
    lastn="${base##*-}"; lastts="${base%-*}"
    # Same second (or a clock that went backwards): continue that second's
    # sequence. `10#` so a leading zero is not read as octal.
    if [ ! "$ts" \> "$lastts" ]; then
      ts="$lastts"
      case "$lastn" in
        [0-9][0-9]) n=$(( 10#$lastn + 1 )) ;;
        *)          n=0 ;;
      esac
    fi
  fi
  while :; do
    # 100 archived generations inside ONE second is not reachable (the guard
    # writes at most one per account per run), so the clamp is a safety valve,
    # not a code path: it reuses -99 rather than emitting a name that would
    # break fixed-width ordering.
    [ "$n" -le 99 ] || n=99
    cand="$(printf '%s/%s-%02d.json' "$d" "$ts" "$n")"
    { [ ! -e "$cand" ] || [ "$n" -eq 99 ]; } && { printf '%s' "$cand"; return 0; }
    n=$((n + 1))
  done
}

meta_read() {  # meta_read <backup.json> <field>
  local m="${1:-}.meta" k="${2:-}"
  [ -f "$m" ] || return 0
  sed -n "s/^$k=//p" "$m" 2>/dev/null | head -1
}

# Write bytes into the ring at 0600 without ever letting them exist world-
# readable in between: create under a private umask, then copy in.
write_private() {  # write_private <src> <dst>
  local src="${1:-}" dst="${2:-}"
  mkdir -p "$(dirname "$dst")"
  ( umask 077; cp "$src" "$dst" )
  chmod 600 "$dst"
}

prune_ring() {  # keep the newest $KEEP in <dir>, oldest first out
  local d="${1:-}" keep="${2:-$KEEP}" n f
  [ -d "$d" ] || return 0
  n=0
  for f in "$d"/*.json; do [ -f "$f" ] && n=$((n + 1)); done
  [ "$n" -gt "$keep" ] || return 0
  local drop=$(( n - keep ))
  for f in "$d"/*.json; do
    [ -f "$f" ] || continue
    [ "$drop" -gt 0 ] || break
    rm -f "$f" "$f.meta"
    drop=$((drop - 1))
  done
}

# --- the run ---------------------------------------------------------------
SNAPPED=(); SKIPPED=(); HUSKS=(); DRIFTS=(); COLLISIONS=()

snapshot_dir() {  # snapshot_dir <config-dir>
  local dir="${1:-}" key cred cur_sha last last_sha ident dest
  cred="$dir/.credentials.json"
  key="$(acct_key "$dir")"
  [ -f "$cred" ] || { SKIPPED+=("$key: no credential file yet ($(tilde "$cred"))"); return 0; }

  if ! cred_complete "$cred"; then
    # A husk is a REPORTABLE event (it is what "you have to /login again" looks
    # like on disk) but must never enter the ring.
    HUSKS+=("$key: $(tilde "$cred") is incomplete (husk after a 401?), NOT archived, the ring still holds its last good copy")
    return 0
  fi

  cur_sha="$(file_sha "$cred")"
  last="$(latest_backup "$key")"
  if [ -n "$last" ]; then
    last_sha="$(meta_read "$last" sha256)"
    [ -n "$last_sha" ] || last_sha="$(file_sha "$last")"
    [ "$cur_sha" = "$last_sha" ] && return 0   # unchanged, nothing to archive
  fi

  ident="$(identity_of_dir "$dir")"
  dest="$(next_backup_path "$key")"
  write_private "$cred" "$dest"
  {
    printf 'identity=%s\n' "${ident:-unknown}"
    printf 'sha256=%s\n' "$cur_sha"
    printf 'source=%s\n' "$cred"
    printf 'at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$dest.meta"
  chmod 600 "$dest.meta"
  prune_ring "$(ring_dir "$key")" "$KEEP"
  SNAPPED+=("$key: archived $(basename "$dest") (identity ${ident:-unknown})")
}

# Every config dir worth watching: the accounts file's dirs, every ~/.claude-pool/*
# (so a dir that is not in the accounts file yet is still protected), and ~/.claude.
all_watched_dirs() {
  local i d seen=""
  for (( i = 0; i < ${#DIRS[@]}; i++ )); do
    d="${DIRS[$i]}"
    [ -d "$d" ] || continue
    case "$seen" in *"|$d|"*) continue ;; esac
    seen="$seen|$d|"
    printf '%s\n' "$d"
  done
  if [ -d "$POOL_ROOT" ]; then
    for d in "$POOL_ROOT"/*; do
      [ -d "$d" ] || continue
      case "$seen" in *"|$d|"*) continue ;; esac
      seen="$seen|$d|"
      printf '%s\n' "$d"
    done
  fi
  if [ -d "$SHARED_DIR" ]; then
    case "$seen" in *"|$SHARED_DIR|"*) ;; *) printf '%s\n' "$SHARED_DIR" ;; esac
  fi
}

# The drift report. Precise on purpose: which dir, who was expected, who
# arrived, where the arrival was snapshotted, and BOTH remedies as commands you
# can paste. Nothing here moves, copies over, or deletes anything.
# The collision report. Same contract as drift_report_for(): says exactly what
# is doubled, why that guarantees a lockout rather than merely risking one, and
# both remedies as pasteable commands. Moves nothing.
collision_report_for() {  # collision_report_for <pool-dir> <shared-email>
  local dir="${1:-}" acct="${2:-}" other

  printf 'CREDENTIAL COLLISION, one account, two credential files. This WILL husk one of them.\n'
  printf '\n'
  printf '  account   : %s\n' "$acct"
  printf '  shared    : %s\n' "$(tilde "$SHARED_DIR")"
  printf '  pinned    : %s\n' "$(tilde "$dir")"
  printf '\n'
  printf 'WHY THIS IS NOT MERELY UNTIDY. Both dirs hold their own .credentials.json for the\n'
  printf 'SAME OAuth account. The refresh token is single-use: whichever process rotates\n'
  printf 'first invalidates the other copy. The loser then presents a dead token, gets a\n'
  printf '401, and the CLI hollows its file into a husk, that session is locked out until\n'
  printf 'someone restores it. Unpinned panes (started without CLAUDE_CONFIG_DIR) use the\n'
  printf 'shared dir, which is how a pane ends up racing a pinned one.\n'
  printf '\n'
  printf 'THE EXACT COMMAND (pool v2, the shared slot must hold NO credential; a pointer\n'
  printf 'switch deletes the shared copy and moves only the claim, so this ENDS the race):\n'
  printf '    rota switch %s\n' "$(basename "$dir")"
  printf '\n'
  printf 'Older remedies, if you want to reason about it instead:\n'
  printf '\n'
  printf '  (i) POINT THE SHARED DIR AT A DIFFERENT ACCOUNT, no session restarts.\n'
  printf '      Choose one with no pinned pane of its own, then:\n'
  printf '        rota switch <other-account>\n'
  printf '      Check headroom first, an exhausted account is a poor landing spot:\n'
  printf '        rota usage\n'
  printf '\n'
  printf '  (ii) PIN THE UNPINNED PANE so nothing uses the shared dir for this account.\n'
  printf '      Find it (a claude with no CLAUDE_CONFIG_DIR in its environment):\n'
  printf '        for p in $(pgrep -f "bin/claude"); do ps eww -p $p | tr " " "\\n" \\\n'
  printf '          | grep -q CLAUDE_CONFIG_DIR || echo "unpinned: $p"; done\n'
  printf '      Then restart that pane through the shim. Note it costs in-flight work,\n'
  printf '      which is why (i) is usually the gentler fix.\n'
  printf '\n'
  printf 'NOTHING WAS MOVED, COPIED OVER OR DELETED. Both credentials are in the ring.\n'
}

drift_report_for() {  # drift_report_for <dir> <expected-label> <found-email>
  local dir="${1:-}" expect="${2:-}" found="${3:-}" key snap home_dir
  key="$(acct_key "$dir")"
  snap="$(latest_backup "$key")"
  home_dir="$(dir_for_label "$found")"

  printf 'CREDENTIAL IDENTITY DRIFT, a /login inside a pinned pane put a different account into a pool dir.\n'
  printf '\n'
  printf '  pool dir : %s\n' "$(tilde "$dir")"
  printf '  expected : %s   (per %s)\n' "$expect" "$(tilde "$ACCOUNTS_FILE")"
  printf '  found    : %s\n' "$found"
  printf '\n'
  printf 'NOTHING WAS MOVED, COPIED OVER OR DELETED. What is in that dir right now was snapshotted first:\n'
  if [ -n "$snap" ]; then
    printf '  %s\n' "$(tilde "$snap")"
  else
    printf '  (no snapshot, the credential in that dir is incomplete, see the husk lines above)\n'
  fi
  printf '\n'
  printf 'Pick ONE remedy:\n'
  printf '\n'
  printf '  (i) RE-FILE THE NEWCOMER into its own pool dir.\n'
  if [ -n "$home_dir" ]; then
    printf '      %s belongs in %s. Its current contents are already in the ring\n' "$found" "$(tilde "$home_dir")"
    printf '      (this run archived them), so overwriting is recoverable:\n'
    printf '        cp -p %s %s && cp -p %s %s\n' \
      "$(printf '%q' "$dir/.credentials.json")" "$(printf '%q' "$home_dir/.credentials.json")" \
      "$(printf '%q' "$(config_json "$dir")")" "$(printf '%q' "$(config_json "$home_dir")")"
  else
    printf '      %s is NOT one of the configured pool accounts. Give it its own dir first:\n' "$found"
    printf '        mkdir -p %s\n' "$(printf '%q' "$POOL_ROOT/<new-alias>")"
    printf '        printf %s >> %s\n' "$(printf '%q' "$found|$POOL_ROOT/<new-alias>")" "$(printf '%q' "$ACCOUNTS_FILE")"
    printf '      then move its credential + config across with the cp pair above.\n'
  fi
  printf '\n'
  printf ' (ii) RESTORE THE DISPLACED ACCOUNT (%s) from its newest COMPLETE backup:\n' "$expect"
  printf '        rota cred-restore %s --list     # see what is available\n' "$key"
  printf '        rota cred-restore %s            # restore it (the current file is kept first)\n' "$key"
  printf '\n'
  printf 'A pane already running against %s keeps its in-memory credential until it restarts.\n' "$(tilde "$dir")"
}

# One detection pass over the CURRENT accounts mapping, filling DRIFTS /
# COLLISIONS / DRIFT_KEY. Factored out of cmd_run (pool v2) so the run can
# detect, hand the mapping half to `reconcile --apply`, and detect AGAIN,
# reporting only what an automatic mapping rewrite could not fix.
DRIFT_KEY=""
detect_drift() {
  DRIFTS=(); COLLISIONS=(); DRIFT_KEY=""
  local i label dir found
  if [ "${#DIRS[@]}" -eq 0 ]; then
    SKIPPED+=("drift check skipped, no accounts file at $(tilde "$ACCOUNTS_FILE")")
  else
    for (( i = 0; i < ${#DIRS[@]}; i++ )); do
      label="${LABELS[$i]}"; dir="${DIRS[$i]}"
      [ -d "$dir" ] || continue
      found="$(identity_of_dir "$dir")"
      [ -n "$found" ] || continue          # never logged in there yet, not drift
      [ "$found" = "$label" ] && continue
      DRIFTS+=("$dir|$label|$found")
      DRIFT_KEY="$DRIFT_KEY$dir=$label>$found;"
    done

    # SHARED/POOL COLLISION, a different failure from drift, with the same
    # cause-and-effect shape, so it is detected here and reported the same way.
    #
    # Drift asks "is the RIGHT account in this dir?". This asks "is ONE account
    # sitting in TWO dirs?", specifically, does the shared ~/.claude hold the
    # same identity as one of the pinned pool dirs. When it does, two Claude
    # processes hold two SEPARATE credential FILES for ONE OAuth account. The
    # refresh token is single-use: whichever process rotates first invalidates
    # the other's copy, the loser 401s, and the CLI hollows its file into a
    # husk (see the BACKUP RING note above), locking that session out.
    #
    # Observed on the always-on box 2026-08-08: ~/.claude and one pool dir both
    # held the same seat while an unpinned pane ran off the shared file and a
    # pinned pane ran off the pool one. It husked three times (Aug 7, and
    # twice Aug 8). Every other pane was fine, because each sat on a DISTINCT
    # account, which is exactly why this is invisible without naming it: the
    # box looks healthy, and only the doubled account dies.
    #
    # Like drift, this only DETECTS and REPORTS. Picking which side moves is a
    # judgement about live sessions, so it stays with the human.
    local shared_ident=""
    [ -d "$SHARED_DIR" ] && shared_ident="$(identity_of_dir "$SHARED_DIR")"
    if [ -n "$shared_ident" ]; then
      for (( i = 0; i < ${#DIRS[@]}; i++ )); do
        dir="${DIRS[$i]}"
        [ "$dir" = "$SHARED_DIR" ] && continue
        [ -d "$dir" ] || continue
        [ "$(identity_of_dir "$dir")" = "$shared_ident" ] || continue
        COLLISIONS+=("$dir|$shared_ident")
        DRIFT_KEY="$DRIFT_KEY collide:$shared_ident@$dir;"
      done
    fi
  fi
}

cmd_run() {
  load_accounts

  local d
  while IFS= read -r d; do
    [ -n "$d" ] && snapshot_dir "$d"
  done <<EOF
$(all_watched_dirs)
EOF

  detect_drift

  # ── ESCALATE, don't just report (pool v2, 2026-08-11) ────────────────────
  # A drift's MAPPING half is mechanically fixable: the dirs' own .claude.json
  # files are the identity source and `reconcile --apply` rewrites the
  # accounts file from them, atomic, comment-preserving, and it never moves a
  # credential byte, which is why the guard may run it while still never
  # touching a credential itself. Then detect AGAIN and report only what an
  # automatic mapping rewrite could not fix (collisions, ambiguity, a dir the
  # rewrite could not name). The reports below are the remainder.
  if [ "${#DRIFTS[@]}" -gt 0 ]; then
    local leaf rec_out=""
    leaf="$(failover_leaf)"
    if [ -n "$leaf" ] && [ -f "$leaf" ]; then
      rec_out="$(bash "$leaf" reconcile --apply 2>&1)" || true
      printf 'drift detected, ran `reconcile --apply` first (mapping only, no credential moved):\n%s\n' "$rec_out"
      load_accounts
      detect_drift
      if [ "${#DRIFTS[@]}" -eq 0 ]; then
        printf 'reconcile resolved the drift, nothing left to report on that front.\n'
      fi
    else
      printf 'note: rota-engine.sh not found, cannot auto-reconcile; reporting the drift as-is.\n' >&2
    fi
  fi

  # ── macOS Keychain duality, DETECTED (2026-08-12, report-only) ────────────
  # A per-dir Keychain item ("Claude Code-credentials-<sha256(dir)[:8]>") is a
  # SECOND copy of that dir's refresh chain: GUI-domain launches (launchd,
  # Spotlight) use the item, tmux launches use the file, and single-use
  # refresh tokens mean whichever refreshes first kills the other, the
  # twin-chain disease inside one dir. This guard only NAMES it; the pool
  # keeper's keychain-unify step (first thing every 10-min tick) is the fixer,
  # so a hit here is normally gone within minutes. Nothing here reads an
  # item's VALUE, existence is probed by exit code only.
  if [ "$(uname -s 2>/dev/null)" = "Darwin" ] && command -v security >/dev/null 2>&1; then
    local kc_hash
    for (( i = 0; i < ${#DIRS[@]}; i++ )); do
      [ -d "${DIRS[$i]}" ] || continue
      kc_hash="$(printf '%s' "${DIRS[$i]}" | shasum -a 256 | cut -c1-8)"
      if security find-generic-password -s "Claude Code-credentials-$kc_hash" >/dev/null 2>&1; then
        printf 'NOTE: a per-dir Keychain item exists for %s ("Claude Code-credentials-%s"), a second copy of %s'\''s refresh chain. The keeper drains it on its next tick (or run `rota keeper` now).\n' \
          "$(tilde "${DIRS[$i]}")" "$kc_hash" "${LABELS[$i]}"
      fi
    done
  fi

  local out=""
  if [ "${#SNAPPED[@]}" -gt 0 ]; then
    for i in "${SNAPPED[@]}"; do out="$out$i"$'\n'; done
  fi
  if [ "${#HUSKS[@]}" -gt 0 ]; then
    for i in "${HUSKS[@]}"; do out="$out$i"$'\n'; done
  fi
  if [ "${#SKIPPED[@]}" -gt 0 ]; then
    for i in "${SKIPPED[@]}"; do out="$out$i"$'\n'; done
  fi
  [ -n "$out" ] && printf '%s' "$out"

  if [ "${#DRIFTS[@]}" -eq 0 ] && [ "${#COLLISIONS[@]}" -eq 0 ]; then
    rm -f "$DRIFT_STATE" "$REPORT_FILE" 2>/dev/null || true
    return 0
  fi

  # Each loop is count-guarded because macOS ships bash 3.2, where iterating an
  # EMPTY array under `set -u` is an "unbound variable" error, not a no-op. The
  # original code never met that case: it returned early unless DRIFTS was
  # non-empty. Now that a collision alone can reach here, either array can
  # legitimately be empty while the other has entries.
  local report=""
  if [ "${#DRIFTS[@]}" -gt 0 ]; then
    for i in "${DRIFTS[@]}"; do
      IFS='|' read -r dir label found <<<"$i"
      report="$report$(drift_report_for "$dir" "$label" "$found")"$'\n'
    done
  fi
  if [ "${#COLLISIONS[@]}" -gt 0 ]; then
    for i in "${COLLISIONS[@]}"; do
      IFS='|' read -r dir found <<<"$i"
      report="$report$(collision_report_for "$dir" "$found")"$'\n'
    done
  fi
  mkdir -p "$CFG_DIR"
  printf '%s' "$report" > "$REPORT_FILE"
  printf '%s' "$report" >&2

  # State-CHANGE reporting, not a heartbeat: notify once per distinct drift, not
  # every 5 minutes (a repeating nudge trains the operator to ignore it).
  local prev=""
  [ -f "$DRIFT_STATE" ] && prev="$(cat "$DRIFT_STATE" 2>/dev/null || true)"
  if [ "$prev" != "$DRIFT_KEY" ]; then
    printf '%s' "$DRIFT_KEY" > "$DRIFT_STATE"
    if [ -z "${CLAUDE_CRED_GUARD_NO_NOTIFY:-}" ] && command -v osascript >/dev/null 2>&1; then
      osascript -e 'display notification "Wrong account in a pinned dir, or one account in two dirs. Run: rota cred-guard" with title "Claude credential problem"' \
        >/dev/null 2>&1 || true
    fi
  fi
  return 2
}

# --- restore ---------------------------------------------------------------
RES_DIR=""; RES_KEY=""; RES_LABEL=""
resolve_account() {  # resolve_account <account> -> RES_DIR / RES_KEY / RES_LABEL
  local want="${1:-}" i d
  RES_DIR=""; RES_KEY=""; RES_LABEL=""
  [ -n "$want" ] || return 1

  if [ "$want" = "shared" ]; then
    RES_DIR="$SHARED_DIR"; RES_KEY="shared"; RES_LABEL="$(identity_of_dir "$SHARED_DIR")"
    return 0
  fi
  for (( i = 0; i < ${#LABELS[@]}; i++ )); do
    if [ "${LABELS[$i]}" = "$want" ] || [ "$(basename "${DIRS[$i]}")" = "$want" ]; then
      RES_DIR="${DIRS[$i]}"; RES_KEY="$(acct_key "${DIRS[$i]}")"; RES_LABEL="${LABELS[$i]}"
      return 0
    fi
  done
  if [ -d "$POOL_ROOT/$want" ]; then
    d="$POOL_ROOT/$want"
    RES_DIR="$d"; RES_KEY="$(acct_key "$d")"; RES_LABEL="$(label_for_dir "$d")"
    return 0
  fi
  return 1
}

# Every name `restore` will accept, for the "not a known account" message.
# Index-based, never `"${ARR[@]}"`: bash 3.2 (macOS system bash) treats that as
# an unbound variable when the array is empty and `set -u` is on.
known_accounts() {
  local i out=""
  for (( i = 0; i < ${#LABELS[@]}; i++ )); do
    out="$out${LABELS[$i]} $(basename "${DIRS[$i]}") "
  done
  if [ -d "$POOL_ROOT" ]; then
    local d
    for d in "$POOL_ROOT"/*; do
      [ -d "$d" ] && out="$out$(basename "$d") "
    done
  fi
  printf '%sshared' "$out"
}

cmd_restore() {
  load_accounts
  local want="" list=0 a
  for a in "$@"; do
    case "$a" in
      --list|-l) list=1 ;;
      -*)        die "restore: unknown flag '$a' (usage: $SELF_NAME restore <account> [--list])" ;;
      *)         [ -z "$want" ] && want="$a" || die "restore: one account at a time (got '$want' and '$a')" ;;
    esac
  done
  [ -n "$want" ] || die "restore: which account? (accounts-file label, pool dir basename, or 'shared')"
  resolve_account "$want" || die "restore: '$want' is not a known account, try one of: $(known_accounts)"

  local rd f pick="" pick_id=""
  rd="$(ring_dir "$RES_KEY")"

  if [ "$list" -eq 1 ]; then
    printf 'backups for %s (%s), newest last, ring at %s\n' \
      "$RES_KEY" "${RES_LABEL:-identity unknown}" "$(tilde "$rd")"
    local any=0
    if [ -d "$rd" ]; then
      for f in "$rd"/*.json; do
        [ -f "$f" ] || continue
        any=1
        printf '  %-24s  identity=%-40s  %s  %s\n' \
          "$(basename "$f" .json)" \
          "$(meta_read "$f" identity)" \
          "$(cred_complete "$f" && printf 'complete' || printf 'HUSK    ')" \
          "$(meta_read "$f" at)"
      done
    fi
    [ "$any" -eq 1 ] || printf '  (none yet, the guard archives on the first CHANGE it sees)\n'
    if [ -d "$(replaced_dir "$RES_KEY")" ]; then
      printf 'files this command replaced earlier (kept, never pruned into the ring):\n'
      for f in "$(replaced_dir "$RES_KEY")"/*.json; do
        [ -f "$f" ] && printf '  %s\n' "$(tilde "$f")"
      done
    fi
    return 0
  fi

  # Newest COMPLETE backup, preferring one whose recorded identity is this
  # account's. That preference is what stops a drifted newcomer's credential,
  # archived under this dir's key because it was sitting in this dir, from
  # being restored as if it belonged to this account.
  if [ -d "$rd" ]; then
    for f in "$rd"/*.json; do
      [ -f "$f" ] || continue
      cred_complete "$f" || continue
      if [ -n "$RES_LABEL" ] && [ "$(meta_read "$f" identity)" = "$RES_LABEL" ]; then
        pick="$f"; pick_id="$RES_LABEL"
      fi
    done
    if [ -z "$pick" ]; then
      for f in "$rd"/*.json; do
        [ -f "$f" ] || continue
        cred_complete "$f" || continue
        pick="$f"; pick_id="$(meta_read "$f" identity)"
      done
      [ -n "$pick" ] && printf 'warning: no backup recorded as %s, falling back to the newest COMPLETE one (identity %s).\n' \
        "${RES_LABEL:-this account}" "${pick_id:-unknown}" >&2
    fi
  fi
  [ -n "$pick" ] || die "restore: no complete backup for '$want' in $(tilde "$rd"), run \`rota cred-restore $RES_KEY --list\` to see what is there"

  local cred="$RES_DIR/.credentials.json" kept=""
  mkdir -p "$RES_DIR"
  if [ -f "$cred" ]; then
    kept="$(replaced_dir "$RES_KEY")/$(date -u +%Y%m%dT%H%M%SZ)-replaced.json"
    write_private "$cred" "$kept"
  fi
  write_private "$pick" "$cred"

  printf 'restored %s -> %s (identity %s)\n' "$(tilde "$pick")" "$(tilde "$cred")" "${pick_id:-unknown}"
  [ -n "$kept" ] && printf 'the file it replaced was kept at %s\n' "$(tilde "$kept")"

  # The credential is what carries the login; <dir>/.claude.json's oauthAccount is
  # a separate CLAIM the CLI renders. After un-doing a drift the two can disagree,
  # and saying so beats letting the operator read the wrong account name off the UI.
  local claims
  claims="$(identity_of_dir "$RES_DIR")"
  if [ -n "$claims" ] && [ -n "$pick_id" ] && [ "$claims" != "$pick_id" ]; then
    printf 'note: %s still CLAIMS %s, that is the config JSON, not the credential.\n' \
      "$(tilde "$(config_json "$RES_DIR")")" "$claims"
    printf '      It corrects itself on the next launch pinned to that dir; `rota active` shows what actually governs.\n'
  fi
  printf 'a pane already running against %s keeps its in-memory credential until it restarts.\n' "$(tilde "$RES_DIR")"
  return 0
}

# --- main ------------------------------------------------------------------
main() {
  case "${1:-run}" in
    run|"")            shift || true; cmd_run "$@" ;;
    restore)           shift; cmd_restore "$@" ;;
    -h|--help|help)    usage ;;
    *)                 usage >&2; die "unknown subcommand: $1" ;;
  esac
}

main "$@"
