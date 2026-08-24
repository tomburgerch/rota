#!/usr/bin/env bash
# The `[ … ] && ok … || bad …` assertion shape below is deliberate: ok()/bad()
# only printf + bump a counter (always return 0), so the SC2015 "C may run when
# A is true" caveat cannot bite. (Same convention as engine.test.sh.)
# shellcheck disable=SC2015
#
# cred-guard.test.sh: regression suite for lib/rota-cred-guard.sh, the backup
# ring + identity-drift detector under the per-session CLAUDE_CONFIG_DIR
# pinning that lib/rota-shim.sh installs.
#
# HERMETIC. Everything runs against a throwaway $HOME with its own accounts
# file, ~/.claude-pool/* and ~/.claude. Nothing here reads or writes a real
# credential: the developer may have live sessions running on those.
#
# What this guards:
#   - the ring only grows on a real CHANGE (sha256 compare), so a 5-minute
#     launchd cadence does not roll ten identical copies through it
#   - a HUSK is never archived. This is the load-bearing rule: after a 401 the
#     CLI hollows the file out, and archiving ten husks in a row would evict the
#     last ten GOOD copies, the safety net would become the thing that loses
#     the credential
#   - pruning keeps the NEWEST N (which is also a test that the `-NN` sequence
#     in the filename sorts correctly; a bare `-2` suffix would sort BEFORE the
#     unsuffixed name and silently prune the wrong end)
#   - drift is detected and reported with BOTH remedies, and NOTHING on disk
#     moves, every watched file is byte-compared across the run
#   - drift notification is state-CHANGE only, not a 5-minute nudge
#   - restore picks the newest complete backup FOR THAT IDENTITY (not merely the
#     newest), and keeps whatever it replaces
#   - no token, or slice of one, ever reaches stdout/stderr

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
GUARD="$ROOT/lib/rota-cred-guard.sh"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'ok   - %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL - %s\n' "$1"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/rota-cred-guard-test.XXXXXX")"
WORK="$(cd "$WORK" && pwd)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

FAKE_HOME="$WORK/home"
CFG="$FAKE_HOME/.config/claude-failover"
BACKUPS="$CFG/backups"
POOL="$FAKE_HOME/.claude-pool"
SHARED="$FAKE_HOME/.claude"
ACCOUNTS="$CFG/accounts"
mkdir -p "$CFG" "$POOL/work" "$POOL/personal" "$SHARED"

CS_EMAIL="work@example.com"
GM_EMAIL="personal@example.com"
SH_EMAIL="shared@example.com"

FAKE_TOKEN="sk-ant-oat01-FAKETOKENDONOTPRINT-0123456789"

printf '# comment the parser must skip\n\n%s|%s\n%s|%s\n' \
  "$CS_EMAIL" "$POOL/work" "$GM_EMAIL" "$POOL/personal" > "$ACCOUNTS"

# --- fixtures ---------------------------------------------------------------
# A COMPLETE credential. The `nonce` field is how a scenario proves WHICH
# generation ended up somewhere without ever grepping for token bytes.
write_cred() {  # write_cred <dir> <nonce>
  printf '{"nonce":"%s","claudeAiOauth":{"accessToken":"%s-%s","refreshToken":"%s-r%s","expiresAt":1786000000,"scopes":["user:inference"],"subscriptionType":"max"}}\n' \
    "$2" "$FAKE_TOKEN" "$2" "$FAKE_TOKEN" "$2" > "$1/.credentials.json"
}
write_husk() {  # write_husk <dir>, what the CLI leaves after a 401
  printf '{"claudeAiOauth":{"accessToken":"","refreshToken":"","scopes":[]}}\n' > "$1/.credentials.json"
}
write_identity() {  # write_identity <dir> <email>   (~/.claude keeps it one level UP)
  local f="$1/.claude.json"
  [ "$1" = "$SHARED" ] && f="$FAKE_HOME/.claude.json"
  printf '{"numStartups":3,"oauthAccount":{"accountUuid":"u","emailAddress":"%s"}}\n' "$2" > "$f"
}

write_cred "$POOL/work" a
write_cred "$POOL/personal" a
write_cred "$SHARED" a
write_identity "$POOL/work" "$CS_EMAIL"
write_identity "$POOL/personal" "$GM_EMAIL"
write_identity "$SHARED" "$SH_EMAIL"

# --- runner -----------------------------------------------------------------
RC=0; OUT=""; ERR=""
run_guard() {  # run_guard [args…]
  local outf="$WORK/out" errf="$WORK/err"
  RC=0
  env HOME="$FAKE_HOME" \
      CLAUDE_FAILOVER_HOME="$CFG" \
      CLAUDE_POOL_DIR="$POOL" \
      CLAUDE_CRED_GUARD_KEEP="${KEEP_OVERRIDE:-10}" \
      CLAUDE_CRED_GUARD_NO_NOTIFY=1 \
      bash "$GUARD" "$@" >"$outf" 2>"$errf" || RC=$?
  OUT="$(cat "$outf")"; ERR="$(cat "$errf")"
}
ring_count() { ls "$BACKUPS/${1:-}"/*.json 2>/dev/null | wc -l | tr -d ' '; }
newest_meta() {  # newest_meta <key> <field>
  local last=""
  local f
  for f in "$BACKUPS/${1:-}"/*.json; do [ -f "$f" ] && last="$f"; done
  [ -n "$last" ] && sed -n "s/^${2:-}=//p" "$last.meta" | head -1
}
# A checksum of every file the guard is allowed to look at but never modify.
watched_fingerprint() {
  find "$POOL" "$SHARED" "$FAKE_HOME/.claude.json" -type f 2>/dev/null \
    | LC_ALL=C sort | while IFS= read -r f; do shasum -a 256 "$f"; done
}

# ───────────────────────────────────────────────────────────────────────────
# 1. the backup ring
# ───────────────────────────────────────────────────────────────────────────
run_guard
[ "$RC" -eq 0 ] \
  && ok "clean run exits 0" \
  || bad "clean run exited $RC: $OUT$ERR"
[ "$(ring_count work)" = "1" ] && [ "$(ring_count personal)" = "1" ] && [ "$(ring_count shared)" = "1" ] \
  && ok "first run archives every complete credential once (work, personal, and ~/.claude as 'shared')" \
  || bad "first run did not archive one per account: work=$(ring_count work) personal=$(ring_count personal) shared=$(ring_count shared)"

[ "$(newest_meta work identity)" = "$CS_EMAIL" ] \
  && ok "the ring records which IDENTITY each archived credential belonged to" \
  || bad "identity not recorded in the backup meta: got '$(newest_meta work identity)'"
[ -n "$(newest_meta work sha256)" ] \
  && ok "the ring records a sha256 (that is how 'has it changed' is answered, never by comparing token bytes)" \
  || bad "no sha256 recorded in the backup meta"

perms="$(ls -l "$(ls "$BACKUPS"/work/*.json | head -1)" | awk '{print $1}')"
case "$perms" in -rw-------*) ok "archived credentials are mode 0600" ;;
                 *) bad "archived credential is not 0600: $perms" ;; esac

run_guard
[ "$(ring_count work)" = "1" ] \
  && ok "a re-run with unchanged bytes archives NOTHING (a 5-min cadence does not roll the ring)" \
  || bad "unchanged re-run still archived: work=$(ring_count work)"

write_cred "$POOL/work" b
run_guard
[ "$(ring_count work)" = "2" ] && [ "$(ring_count personal)" = "1" ] \
  && ok "a CHANGED credential is archived, and only that account's ring grows" \
  || bad "change was not archived correctly: work=$(ring_count work) personal=$(ring_count personal)"

# ───────────────────────────────────────────────────────────────────────────
# 2. a husk is never archived
# ───────────────────────────────────────────────────────────────────────────
before="$(ring_count work)"
write_husk "$POOL/work"
run_guard
[ "$(ring_count work)" = "$before" ] \
  && ok "an incomplete credential (husk) is NOT archived, the ring keeps its last GOOD copies instead of being flushed by ten husks" \
  || bad "a husk entered the ring: was $before, now $(ring_count work)"
case "$OUT$ERR" in *"husk"*|*"incomplete"*) ok "the husk is REPORTED (it is what 'I have to log in again' looks like on disk)" ;;
                   *) bad "the husk was silently ignored: $OUT$ERR" ;; esac
write_cred "$POOL/work" c
run_guard

# ───────────────────────────────────────────────────────────────────────────
# 3. pruning keeps the NEWEST N
# ───────────────────────────────────────────────────────────────────────────
KEEP_OVERRIDE=3
for n in d e f g h; do
  write_cred "$POOL/personal" "$n"
  run_guard
done
[ "$(ring_count personal)" = "3" ] \
  && ok "the ring prunes to N (3 here), oldest out first" \
  || bad "prune did not hold the ring at 3: $(ring_count personal)"
newest="$(ls "$BACKUPS"/personal/*.json | tail -1)"
grep -q '"nonce":"h"' "$newest" \
  && ok "the kept entries are the NEWEST ones (the -NN filename sequence sorts correctly, so pruning takes the right end)" \
  || bad "pruning kept the wrong end of the ring, newest archived is not the last write"
KEEP_OVERRIDE=10

# The bug the loop above only caught about one run in three, pinned down
# DETERMINISTICALLY: prune deletes from the FRONT, so after a prune an early
# `-NN` slot is free again. A "first free slot" allocator reuses it, writing the
# NEWEST credential under the OLDEST-sorting name, where the same run's prune
# deletes it immediately. Seed exactly that shape: a ring whose only entry for
# the CURRENT second is `-03`, with -00..-02 already pruned away.
mkdir -p "$POOL/seq" "$BACKUPS/seq"
write_cred "$POOL/seq" seeded
# BOTH this second and the next one get a `-03`, so it does not matter which of
# them the guard's own `date` lands in: either way an early slot is free and a
# `-03` is already taken, which is the exact shape that reproduced the bug.
for SEED_TS in "$(date -u +%Y%m%dT%H%M%SZ)" "$(date -u -v+1S +%Y%m%dT%H%M%SZ)"; do
  cp "$POOL/seq/.credentials.json" "$BACKUPS/seq/$SEED_TS-03.json"
  printf 'identity=seed@example.com\nsha256=deadbeef\n' > "$BACKUPS/seq/$SEED_TS-03.json.meta"
done
write_cred "$POOL/seq" afterprune
KEEP_OVERRIDE=2 run_guard
seq_newest="$(ls "$BACKUPS"/seq/*.json | tail -1)"
grep -q '"nonce":"afterprune"' "$seq_newest" \
  && ok "a snapshot taken after a prune freed an early slot still sorts LAST (the sequence is monotonic, not 'first free', reusing -00 would make the newest credential prune itself)" \
  || bad "the post-prune snapshot did not sort last: newest is $(basename "$seq_newest")"
rm -rf "$POOL/seq" "$BACKUPS/seq"

# ───────────────────────────────────────────────────────────────────────────
# 4. identity drift, detected, reported, and NOTHING touched
# ───────────────────────────────────────────────────────────────────────────
write_identity "$POOL/work" "$GM_EMAIL"     # a /login as personal inside the work-pinned pane
write_cred "$POOL/work" drifted
run_guard                                  # snapshot the newcomer first
fingerprint_before="$(watched_fingerprint)"
run_guard
fingerprint_after="$(watched_fingerprint)"

[ "$RC" -eq 2 ] \
  && ok "drift exits 2 (distinguishable from a clean run for anything scripting it)" \
  || bad "drift did not exit 2: RC=$RC"
[ "$fingerprint_before" = "$fingerprint_after" ] \
  && ok "drift changes NOTHING on disk, every pool credential and config is byte-identical after the run" \
  || bad "the guard modified a watched file while reporting drift"

REPORT="$OUT$ERR"
case "$REPORT" in *"$POOL/work"*) ok "the report names the pool DIR that drifted" ;;
                  *) bad "the report does not name the drifted dir: $REPORT" ;; esac
case "$REPORT" in *"expected : $CS_EMAIL"*) ok "the report names which account was EXPECTED there" ;;
                  *) bad "the report does not name the expected account: $REPORT" ;; esac
case "$REPORT" in *"found    : $GM_EMAIL"*) ok "the report names which account ARRIVED" ;;
                  *) bad "the report does not name the arriving account: $REPORT" ;; esac
case "$REPORT" in *"RE-FILE THE NEWCOMER"*) ok "remedy (i) is spelled out: re-file the newcomer into its own pool dir" ;;
                  *) bad "remedy (i) missing from the report: $REPORT" ;; esac
case "$REPORT" in *"RESTORE THE DISPLACED ACCOUNT"*) ok "remedy (ii) is spelled out: restore the displaced account from its newest complete backup" ;;
                  *) bad "remedy (ii) missing from the report: $REPORT" ;; esac
case "$REPORT" in *"rota cred-restore work"*) ok "the report hands over the exact restore command, not a description of one" ;;
                  *) bad "the report does not contain a runnable restore command: $REPORT" ;; esac
case "$REPORT" in *"$POOL/personal/.credentials.json"*) ok "remedy (i) resolves the newcomer's OWN pool dir and gives the cp pair for it" ;;
                  *) bad "remedy (i) does not name the newcomer's own dir: $REPORT" ;; esac
[ -s "$CFG/cred-guard-report.txt" ] \
  && ok "the report is also persisted to a file, so it survives the launchd run that produced it" \
  || bad "no persisted report file at $CFG/cred-guard-report.txt"

state1="$(cat "$CFG/cred-guard-drift" 2>/dev/null || true)"
run_guard
state2="$(cat "$CFG/cred-guard-drift" 2>/dev/null || true)"
[ -n "$state1" ] && [ "$state1" = "$state2" ] \
  && ok "repeat runs of the SAME drift keep the same state key (state-change reporting, not a 5-minute nudge)" \
  || bad "drift state key churned between identical runs: '$state1' vs '$state2'"

# ───────────────────────────────────────────────────────────────────────────
# 5. restore
# ───────────────────────────────────────────────────────────────────────────
run_guard restore work --list
case "$OUT" in *"identity=$CS_EMAIL"*) ok "restore --list shows each backup's recorded identity" ;;
               *) bad "restore --list does not show identities: $OUT" ;; esac
case "$OUT" in *"identity=$GM_EMAIL"*) ok "restore --list also shows the DRIFTED entry, so nothing is hidden" ;;
               *) bad "restore --list hid the drifted entry: $OUT" ;; esac
printf '%s' "$OUT" | grep -qE '^  [0-9]{8}T[0-9]{6}Z-[0-9]{2} ' \
  && ok "restore --list shows an ISO timestamp per backup" \
  || bad "restore --list has no ISO timestamps: $OUT"

# The load-bearing one: the newest entry in work's ring belongs to PERSONAL (it was
# archived out of the work dir during the drift). `restore work` must not hand that
# back as if it were work's.
run_guard restore work
[ "$RC" -eq 0 ] \
  && ok "restore exits 0" \
  || bad "restore failed: RC=$RC $OUT$ERR"
grep -q '"nonce":"c"' "$POOL/work/.credentials.json" \
  && ok "restore picks the newest COMPLETE backup FOR THAT IDENTITY, not merely the newest, which here belongs to the account that drifted in" \
  || bad "restore restored the wrong backup into $POOL/work"
ls "$BACKUPS"/work/replaced/*.json >/dev/null 2>&1 \
  && ok "restore keeps the file it replaced (in a 'replaced' dir the ring never prunes)" \
  || bad "restore did not keep the file it replaced"
case "$OUT" in *"still CLAIMS"*) ok "restore says so when the dir's config JSON still claims the other account" ;;
               *) bad "restore did not flag the config-vs-credential disagreement: $OUT" ;; esac

run_guard restore personal --list
case "$OUT" in *"20"*) ok "restore --list works for a second account" ;;
               *) bad "restore --list failed for personal: $OUT$ERR" ;; esac

run_guard restore not-an-account
[ "$RC" -ne 0 ] && case "$ERR" in *"not a known account"*) true ;; *) false ;; esac \
  && ok "an unknown account name fails cleanly and lists the names that ARE known" \
  || bad "unknown account did not fail cleanly: RC=$RC ERR=$ERR"

mkdir -p "$POOL/empty"
run_guard restore empty
[ "$RC" -ne 0 ] && case "$ERR" in *"no complete backup"*) true ;; *) false ;; esac \
  && ok "restoring an account with no backups fails cleanly (never writes a partial or empty credential)" \
  || bad "empty-ring restore did not fail cleanly: RC=$RC ERR=$ERR"
[ ! -f "$POOL/empty/.credentials.json" ] \
  && ok "…and wrote nothing into that dir" \
  || bad "a failed restore still created a credential file"
rmdir "$POOL/empty"

# ───────────────────────────────────────────────────────────────────────────
# 6. drift clears itself once the dir is back on its own account
# ───────────────────────────────────────────────────────────────────────────
write_identity "$POOL/work" "$CS_EMAIL"
run_guard
[ "$RC" -eq 0 ] \
  && ok "once the dir's identity matches its label again, the run is clean (exit 0)" \
  || bad "drift did not clear: RC=$RC $OUT$ERR"
[ ! -f "$CFG/cred-guard-drift" ] && [ ! -f "$CFG/cred-guard-report.txt" ] \
  && ok "…and the stale drift state + report file are cleared, so the next drift reads as NEW" \
  || bad "drift state/report survived a clean run"

# ───────────────────────────────────────────────────────────────────────────
# 7. degrades, never dies, without an accounts file
# ───────────────────────────────────────────────────────────────────────────
mv "$ACCOUNTS" "$WORK/accounts.away"
write_cred "$POOL/work" nofile
run_guard
[ "$RC" -eq 0 ] \
  && ok "no accounts file: still exits 0 (the ring does not depend on the mapping)" \
  || bad "missing accounts file broke the run: RC=$RC $OUT$ERR"
case "$OUT$ERR" in *"drift check skipped"*) ok "…and says the drift check was skipped rather than reporting a false all-clear" ;;
                   *) bad "missing accounts file did not report the skipped drift check: $OUT$ERR" ;; esac
grep -q '"nonce":"nofile"' "$(ls "$BACKUPS"/work/*.json | tail -1)" \
  && ok "…and the pool dir is STILL backed up, discovered off ~/.claude-pool/* rather than the accounts file" \
  || bad "the ring stopped working without an accounts file"
mv "$WORK/accounts.away" "$ACCOUNTS"

# ───────────────────────────────────────────────────────────────────────────
# 8. never leaks a token
# ───────────────────────────────────────────────────────────────────────────
leaked=0
check_leak() { case "$OUT$ERR" in *"$FAKE_TOKEN"*|*"FAKETOKEN"*) leaked=1 ;; esac; }
run_guard;                       check_leak
run_guard restore work --list;   check_leak
run_guard restore work;          check_leak
write_husk "$POOL/personal"; run_guard; check_leak
write_identity "$POOL/personal" "$CS_EMAIL"; run_guard; check_leak
[ "$leaked" -eq 0 ] \
  && ok "no subcommand, including the drift report and the backup listing, ever prints a token or a slice of one" \
  || bad "a token (or a slice of one) reached the guard's output"

# ───────────────────────────────────────────────────────────────────────────
# 9. shared/pool COLLISION, one account, two credential files
#
# Distinct from drift. Drift asks "is the RIGHT account in this dir?"; this asks
# "is ONE account in TWO dirs?". When the shared ~/.claude holds the same
# identity as a pinned pool dir, two processes hold two SEPARATE credential
# FILES for one OAuth account. The refresh token is single-use, so whichever
# rotates first invalidates the other; the loser 401s and gets husked.
#
# From a real 2026-08-08 incident on the always-on box: ~/.claude and one pool
# dir both held the same seat while an unpinned pane raced a pinned one. It husked three times (Aug 7, twice Aug 8). Every other
# pane stayed healthy because each sat on a DISTINCT account, which is exactly
# why this stays invisible until something names it.
# ───────────────────────────────────────────────────────────────────────────
# Section 8 left personal drifted onto CS_EMAIL; restore a clean baseline first.
write_cred "$POOL/personal" z; write_identity "$POOL/personal" "$GM_EMAIL"
write_identity "$SHARED" "$SH_EMAIL"
run_guard
case "$OUT$ERR" in *"CREDENTIAL COLLISION"*) bad "no collision reported when every dir holds a distinct account" ;;
                   *) ok "no collision reported when every dir holds a distinct account" ;; esac

# Collide: point the shared dir at the SAME account as pool/work.
write_identity "$SHARED" "$CS_EMAIL"
coll_before="$(watched_fingerprint)"
run_guard
case "$OUT$ERR" in *"CREDENTIAL COLLISION"*) ok "collision detected when shared and a pinned dir share an account" ;;
                   *) bad "collision detected when shared and a pinned dir share an account" ;; esac
case "$OUT$ERR" in *"$CS_EMAIL"*) ok "collision report names the doubled account" ;;
                   *) bad "collision report names the doubled account" ;; esac
case "$OUT$ERR" in *".claude-pool/work"*) ok "collision report names the pinned dir involved" ;;
                   *) bad "collision report names the pinned dir involved" ;; esac
case "$OUT$ERR" in *"rota switch"*) ok "collision report offers the no-restart remedy (rota switch)" ;;
                   *) bad "collision report offers the no-restart remedy (rota switch)" ;; esac
case "$OUT$ERR" in *"CLAUDE_CONFIG_DIR"*) ok "collision report offers the pin-the-pane remedy" ;;
                   *) bad "collision report offers the pin-the-pane remedy" ;; esac
[ "$RC" -eq 2 ] \
  && ok "collision exits 2, same contract as drift" \
  || bad "collision exits 2, same contract as drift (got $RC)"
[ "$(watched_fingerprint)" = "$coll_before" ] \
  && ok "collision detection moves/copies/deletes NOTHING" \
  || bad "collision detection modified a watched file"

# The case that broke first while building this: a collision with NO drift.
# The early return assumed a non-empty DRIFTS array, and on macOS bash 3.2
# iterating an EMPTY array under `set -u` is a hard error, not a no-op, so the
# guard died with "unbound variable" instead of reporting the collision.
case "$OUT$ERR" in *"unbound variable"*) bad "no unbound-variable error when DRIFTS is empty (bash 3.2 set -u)" ;;
                   *) ok "no unbound-variable error when DRIFTS is empty (bash 3.2 set -u)" ;; esac

case "$OUT$ERR" in *"$FAKE_TOKEN"*|*"FAKETOKEN"*) bad "collision report never prints a token" ;;
                   *) ok "collision report never prints a token" ;; esac

# Clearing the collision clears the report.
write_identity "$SHARED" "$SH_EMAIL"
run_guard
case "$OUT$ERR" in *"CREDENTIAL COLLISION"*) bad "collision clears once the shared dir moves to another account" ;;
                   *) ok "collision clears once the shared dir moves to another account" ;; esac

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
