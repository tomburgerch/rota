#!/usr/bin/env bash
# The `[ … ] && ok … || bad …` assertion shape below is deliberate: ok()/bad()
# only printf + bump a counter (always return 0), so the SC2015 "C may run when
# A is true" caveat cannot bite. (Same convention as engine.test.sh.)
# shellcheck disable=SC2015
#
# shim.test.sh: regression suite for lib/rota-shim.sh, the ~/.local/bin/claude
# wrapper that pins each session to its own account config
# dir before exec'ing the real binary.
#
# HERMETIC. Everything runs against a throwaway $HOME (its own ~/.claude.json,
# ~/.claude-pool/*, accounts file) with a FAKE `claude` and a FAKE engine
# (rota-engine.sh) handed in via CLAUDE_FAILOVER_BIN. Nothing here reads,
# writes or even looks at a real credential, the real pool, or the real
# Keychain: the developer may have live sessions running on those.
#
# What this guards, in order of how expensive the bug would be:
#   - FAIL OPEN, with the 2026-08-16 rescue in front of it. The shim sits in
#     front of every `claude` launch on the box, so the one thing it must never
#     do is stop `claude` from starting. When only the ACTIVE account is broken
#     (husk credential, missing credential, missing dir, unmapped email) the
#     shim now pins to the FIRST account in the accounts file that still holds
#     a complete credential, under pool v2 the shared dir has no credential,
#     so the old "go unpinned" answer was a guaranteed dead session. Truly
#     unresolvable cases (no identity, no accounts file, every account husked,
#     the nested-config trap) still run the real binary, unpinned.
#   - The rescue never trusts the accounts-file LABEL (2026-08-16 review): a
#     typo'd row for the ACTIVE account rescues BY IDENTITY to the account's
#     own dir rather than borrowing a foreign one, and a row whose dir's real
#     identity contradicts its label is skipped, either way the map's lie is
#     flagged for the keeper, never silently billed to the wrong account.
#   - An explicit CLAUDE_CONFIG_DIR is never touched, the runners, the other
#     suites and any deliberately pinned pane all depend on that.
#   - NO RECURSION. ~/.local/bin is first on PATH, so a naive PATH scan would
#     find the shim itself and fork-bomb the box. A symlink to it and a full
#     COPY of it are both planted earlier on PATH; each run is bounded by a
#     10s alarm so a regression FAILS instead of hanging the suite.
#   - Identity resolution: the cheap ~/.claude.json read, the
#     `rota-engine.sh active` fallback, and the recursion guard being
#     armed (CLAUDE_SHIM_RESOLVING) around that fallback.
#   - No token, or any slice of one, ever reaches stdout/stderr.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SHIM="$ROOT/lib/rota-shim.sh"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'ok   - %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL - %s\n' "$1"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/rota-shim-test.XXXXXX")"
WORK="$(cd "$WORK" && pwd)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

FAKE_HOME="$WORK/home"
REALDIR="$WORK/opt"          # where the FAKE "real" claude lives
STUB="$WORK/bin"             # where the FAKE engine (rota-engine.sh) lives
STATE="$WORK/state"
mkdir -p "$FAKE_HOME/.config/claude-failover" "$FAKE_HOME/.claude" \
         "$FAKE_HOME/.claude-pool/work" "$FAKE_HOME/.claude-pool/personal" \
         "$REALDIR" "$STUB" "$STATE"

CS_EMAIL="work@example.com"
GM_EMAIL="personal@example.com"
CS_DIR="$FAKE_HOME/.claude-pool/work"
GM_DIR="$FAKE_HOME/.claude-pool/personal"
ACCOUNTS="$FAKE_HOME/.config/claude-failover/accounts"

# A recognisable fake secret. Nothing in the shim should ever echo it; the
# no-leak scenario greps every byte of stdout+stderr for it.
FAKE_TOKEN="sk-ant-oat01-FAKETOKENDONOTPRINT-0123456789"

# --- fake "real" claude -----------------------------------------------------
# Prints the one thing every scenario asserts on: which CLAUDE_CONFIG_DIR (if
# any) it was handed, plus its argv, plus whatever exit code the scenario asked
# for. `${CLAUDE_CONFIG_DIR-UNSET}` (not `:-`) so "set but empty" is visible as
# empty rather than as UNSET.
cat > "$REALDIR/claude" <<'STUB'
#!/bin/bash
printf 'REAL-CLAUDE\n'
printf 'CONFIGDIR=%s\n' "${CLAUDE_CONFIG_DIR-UNSET}"
printf 'ARGS=%s\n' "$*"
exit "${FAKE_CLAUDE_RC:-0}"
STUB
chmod +x "$REALDIR/claude"

# --- fake engine (rota-engine.sh) -------------------------------------------
# Serves `active` the way the real engine does: the email on stdout, or nothing +
# exit 3 when it cannot be known. It also records that it was called AND whether
# CLAUDE_SHIM_RESOLVING was exported into it, that variable is what makes the
# shim's own fallback structurally unable to recurse.
cat > "$STUB/rota-engine.sh" <<'STUB'
#!/bin/bash
if [ "${1:-}" = "active" ]; then
  printf '%s\n' "${CLAUDE_SHIM_RESOLVING-UNSET}" >> "$FAKE_STATE/active-guard"
  printf 'called\n' >> "$FAKE_STATE/active-calls"
  if [ -n "${FAKE_ACTIVE_EMAIL:-}" ]; then printf '%s\n' "$FAKE_ACTIVE_EMAIL"; exit 0; fi
  exit 3
fi
exit 1
STUB
chmod +x "$STUB/rota-engine.sh"
FAKE_ENGINE="$STUB/rota-engine.sh"

# --- fixture writers --------------------------------------------------------
write_accounts() {   # write_accounts, the normal two-account mapping
  { printf '# a comment line the parser must skip\n'
    printf '\n'
    printf '%s|%s\n' "$CS_EMAIL" "$CS_DIR"
    printf '%s|%s\n' "$GM_EMAIL" "$GM_DIR"
  } > "$ACCOUNTS"
}
write_identity() {   # write_identity <email|""> , the shared ~/.claude.json
  if [ -z "${1:-}" ]; then
    printf '{"numStartups":7}\n' > "$FAKE_HOME/.claude.json"
  else
    printf '{"numStartups":7,"oauthAccount":{"accountUuid":"u","emailAddress":"%s"}}\n' "$1" \
      > "$FAKE_HOME/.claude.json"
  fi
}
write_complete_cred() {  # write_complete_cred <dir>
  printf '{"claudeAiOauth":{"accessToken":"%s","refreshToken":"%s","expiresAt":1786000000,"scopes":["user:inference"]}}\n' \
    "$FAKE_TOKEN" "$FAKE_TOKEN-refresh" > "$1/.credentials.json"
}
write_husk_cred() {      # write_husk_cred <dir>, what a 401 leaves behind
  printf '{"claudeAiOauth":{"accessToken":"","refreshToken":"","scopes":[]}}\n' \
    > "$1/.credentials.json"
}

write_accounts
write_identity "$CS_EMAIL"
write_complete_cred "$CS_DIR"
write_complete_cred "$GM_DIR"
write_complete_cred "$FAKE_HOME/.claude"

# --- runner -----------------------------------------------------------------
# `env -i` so no ambient CLAUDE_* / PATH from the developer's shell can leak in
# and make a scenario pass for the wrong reason.
#
# The base PATH is $STUB : $REALDIR : a HAND-BUILT tool dir, not /usr/bin, for
# two reasons. (a) Any PATH scan can then only ever reach the FAKE claude. (b)
# macOS now ships jq at /usr/bin/jq, so simply "leaving homebrew off PATH" no
# longer hides it, and the shim's no-jq grep fallback would never be exercised.
# The tool dir carries symlinks to exactly the binaries the shim uses, and
# deliberately no jq. $JQ_PATH re-adds the system dirs to exercise the jq read.
NOJQ="$WORK/nojq"; mkdir -p "$NOJQ"
for _t in grep head sed dirname basename readlink mkdir touch; do
  _p="$(command -v "$_t" 2>/dev/null || true)"
  [ -n "$_p" ] && ln -sf "$_p" "$NOJQ/$_t"
done
BASE_PATH="$STUB:$REALDIR:$NOJQ"
JQ_PATH="$STUB:$REALDIR:$NOJQ:/usr/bin:/bin"

RC=0; OUT=""; ERR=""
run_shim() {  # run_shim [VAR=val …] -- [args to claude …]
  local envs=() args=() past=0 a
  for a in "$@"; do
    if [ "$past" -eq 0 ] && [ "$a" = "--" ]; then past=1; continue; fi
    if [ "$past" -eq 1 ]; then args[${#args[@]}]="$a"; else envs[${#envs[@]}]="$a"; fi
  done
  local outf="$WORK/out" errf="$WORK/err"
  RC=0
  # /usr/bin/perl's alarm bounds every run: if the anti-recursion guard ever
  # regresses, the scenario FAILS on a timeout instead of fork-bombing the box.
  /usr/bin/perl -e 'alarm 10; exec @ARGV' -- \
    /usr/bin/env -i \
      HOME="$FAKE_HOME" \
      PATH="${SHIM_TEST_PATH:-$BASE_PATH}" \
      TMPDIR="$WORK" \
      FAKE_STATE="$STATE" \
      CLAUDE_SHIM_DIRS="${SHIM_TEST_DIRS-$REALDIR}" \
      CLAUDE_FAILOVER_BIN="$FAKE_ENGINE" \
      ${envs[@]+"${envs[@]}"} \
      /bin/bash "$SHIM" ${args[@]+"${args[@]}"} \
      >"$outf" 2>"$errf" || RC=$?
  OUT="$(cat "$outf")"; ERR="$(cat "$errf")"
}
configdir_of() { printf '%s' "$OUT" | sed -n 's/^CONFIGDIR=//p'; }
ran_real()     { case "$OUT" in *REAL-CLAUDE*) return 0 ;; *) return 1 ;; esac; }

# ───────────────────────────────────────────────────────────────────────────
# 0. setup sanity, if these fail every later "ok" is meaningless
# ───────────────────────────────────────────────────────────────────────────
if /usr/bin/env -i PATH="$BASE_PATH" /bin/sh -c 'command -v claude' 2>/dev/null | grep -q "^$REALDIR/claude$"; then
  ok "setup: the only \`claude\` reachable on the test PATH is the FAKE one"
else
  bad "setup: the test PATH does not resolve \`claude\` to the fake at $REALDIR, a real binary could be exec'd"
fi
if /usr/bin/env -i PATH="$BASE_PATH" /bin/sh -c 'command -v jq' >/dev/null 2>&1; then
  bad "setup: jq is unexpectedly on the base test PATH, the grep fallback would not be exercised"
else
  ok "setup: no jq on the base test PATH (the grep fallback is what gets exercised)"
fi
if /usr/bin/env -i PATH="$JQ_PATH" /bin/sh -c 'command -v jq' >/dev/null 2>&1; then
  ok "setup: jq IS on \$JQ_PATH (the jq read is what gets exercised there)"
else
  bad "setup: no jq anywhere, the jq-vs-grep agreement scenario would be vacuous"
fi

# ───────────────────────────────────────────────────────────────────────────
# 1. an explicit CLAUDE_CONFIG_DIR is never touched
# ───────────────────────────────────────────────────────────────────────────
run_shim CLAUDE_CONFIG_DIR="$GM_DIR" --
[ "$(configdir_of)" = "$GM_DIR" ] \
  && ok "pre-set CLAUDE_CONFIG_DIR is passed through untouched (not re-pointed at the active account)" \
  || bad "pre-set CLAUDE_CONFIG_DIR was rewritten: got '$(configdir_of)', want '$GM_DIR'"

run_shim CLAUDE_CONFIG_DIR="/nowhere/at/all" --
[ "$(configdir_of)" = "/nowhere/at/all" ] \
  && ok "pre-set CLAUDE_CONFIG_DIR is respected even when the dir does not exist (an explicit pin always wins)" \
  || bad "pre-set non-existent CLAUDE_CONFIG_DIR was rewritten to '$(configdir_of)'"

rm -f "$STATE/active-calls"
run_shim CLAUDE_CONFIG_DIR="$GM_DIR" --
[ ! -f "$STATE/active-calls" ] \
  && ok "pre-set CLAUDE_CONFIG_DIR short-circuits BEFORE any resolution work (no failover subprocess)" \
  || bad "pre-set CLAUDE_CONFIG_DIR still ran the identity resolution"

# ───────────────────────────────────────────────────────────────────────────
# 2. the happy path: email -> pool dir
# ───────────────────────────────────────────────────────────────────────────
write_identity "$CS_EMAIL"
run_shim --
[ "$(configdir_of)" = "$CS_DIR" ] \
  && ok "resolves the active account ($CS_EMAIL) to its pool dir and exports CLAUDE_CONFIG_DIR" \
  || bad "did not pin to $CS_DIR: got '$(configdir_of)'"

write_identity "$GM_EMAIL"
run_shim --
[ "$(configdir_of)" = "$GM_DIR" ] \
  && ok "follows the shared identity when it changes ($GM_EMAIL -> its own dir), so a switch needs no shim change" \
  || bad "did not follow the identity change: got '$(configdir_of)', want '$GM_DIR'"

SHIM_TEST_PATH="$JQ_PATH" run_shim --
[ "$(configdir_of)" = "$GM_DIR" ] \
  && ok "same answer with jq on PATH (the jq read and the grep fallback agree)" \
  || bad "jq path disagreed with the grep fallback: got '$(configdir_of)'"

write_identity "$CS_EMAIL"

# a "~/"-relative dir in the accounts file
{ printf '%s|~/.claude-pool/work\n' "$CS_EMAIL"; } > "$ACCOUNTS"
run_shim --
[ "$(configdir_of)" = "$FAKE_HOME/.claude-pool/work" ] \
  && ok "expands a leading ~/ in the accounts file to \$HOME" \
  || bad "did not expand ~/ in the accounts file: got '$(configdir_of)'"
write_accounts

# ───────────────────────────────────────────────────────────────────────────
# 3. the `rota-engine.sh active` fallback
# ───────────────────────────────────────────────────────────────────────────
write_identity ""            # config exists but carries no oauthAccount
rm -f "$STATE/active-calls" "$STATE/active-guard"
run_shim FAKE_ACTIVE_EMAIL="$GM_EMAIL" --
[ "$(configdir_of)" = "$GM_DIR" ] \
  && ok "falls back to \`rota-engine.sh active\` when ~/.claude.json carries no oauthAccount" \
  || bad "the active fallback did not resolve the account: got '$(configdir_of)'"
[ "$(cat "$STATE/active-guard" 2>/dev/null || true)" = "1" ] \
  && ok "the fallback runs with CLAUDE_SHIM_RESOLVING=1, a nested \`claude\` it spawns cannot re-enter resolution" \
  || bad "CLAUDE_SHIM_RESOLVING was not exported into the failover call (recursion guard unarmed): got '$(cat "$STATE/active-guard" 2>/dev/null || true)'"

run_shim CLAUDE_SHIM_RESOLVING=1 --
[ "$(configdir_of)" = "UNSET" ] \
  && ok "CLAUDE_SHIM_RESOLVING=1 on entry skips resolution entirely (breaks any re-entry loop)" \
  || bad "CLAUDE_SHIM_RESOLVING=1 did not bypass resolution: got '$(configdir_of)'"

# ───────────────────────────────────────────────────────────────────────────
# 4. FAIL OPEN, every way resolution can fail must still launch claude.
#    Since 2026-08-16 a failure that is the ACTIVE account's alone rescues to
#    the first complete account in file order; only unresolvable failures
#    (and a fully dead pool) still go unpinned.
# ───────────────────────────────────────────────────────────────────────────
write_identity ""
run_shim --                                        # active exits 3, no identity
ran_real && [ "$(configdir_of)" = "UNSET" ] \
  && ok "fail open: identity unknowable (\`active\` exits 3) -> real binary runs UNPINNED" \
  || bad "fail open broke when the identity was unknowable: OUT=$OUT ERR=$ERR"

write_identity "$CS_EMAIL"
mv "$ACCOUNTS" "$WORK/accounts.away"
run_shim --
ran_real && [ "$(configdir_of)" = "UNSET" ] \
  && ok "fail open: accounts file missing -> real binary runs UNPINNED" \
  || bad "fail open broke with no accounts file: OUT=$OUT ERR=$ERR"
mv "$WORK/accounts.away" "$ACCOUNTS"

# Pre-2026-08-16 an unmapped active email went UNPINNED, under pool v2 that is
# a dead session while working credentials sit in the pool, so it now rescues.
write_identity "someone-else@example.com"
run_shim --
ran_real && [ "$(configdir_of)" = "$CS_DIR" ] \
  && ok "active email not in the accounts file -> rescues to the FIRST complete account in file order (was: unpinned, pre-2026-08-16)" \
  || bad "unmapped email did not rescue to $CS_DIR: got '$(configdir_of)' ERR=$ERR"

write_identity "$CS_EMAIL"
mv "$CS_DIR" "$WORK/work.away"
run_shim --
ran_real && [ "$(configdir_of)" = "$GM_DIR" ] \
  && ok "mapped pool dir does not exist -> rescues to the next complete account (was: unpinned, pre-2026-08-16)" \
  || bad "missing mapped dir did not rescue to $GM_DIR: got '$(configdir_of)' ERR=$ERR"
mv "$WORK/work.away" "$CS_DIR"

# THE 2026-08-16 INCIDENT, replayed: the active account's credential is the
# 401 husk while another pool account is complete. The old behaviour (fail
# open to the credential-less shared dir) guaranteed "Not logged in · Please
# run /login"; the fix pins to the first working account and says so, once,
# on stderr, never stdout, which may be piped.
write_husk_cred "$CS_DIR"
run_shim --
ran_real && [ "$(configdir_of)" = "$GM_DIR" ] \
  && ok "active credential is a HUSK -> pins to the first COMPLETE account, not the credential-less shared dir (the 2026-08-16 incident)" \
  || bad "husk did not rescue to $GM_DIR: got '$(configdir_of)' OUT=$OUT ERR=$ERR"
case "$ERR" in
  *"active $CS_EMAIL"*"pinning to $GM_EMAIL"*)
    ok "the rescue announces itself on STDERR, naming both the husked and the fallback account" ;;
  *)
    bad "no/wrong stderr diagnostic for the husk rescue: ERR='$ERR'" ;;
esac
[ "$(printf '%s\n' "$ERR" | grep -c '^rota-shim:')" -eq 1 ] \
  && ok "the rescue diagnostic is exactly ONE stderr line" \
  || bad "expected exactly one rota-shim: stderr line, got: '$ERR'"
case "$OUT" in
  *"rota-shim:"*) bad "the rescue diagnostic leaked to STDOUT (would corrupt piped output): OUT=$OUT" ;;
  *)                ok "the rescue diagnostic stays off stdout (stdout may be piped)" ;;
esac
write_complete_cred "$CS_DIR"

rm -f "$CS_DIR/.credentials.json"
run_shim --
ran_real && [ "$(configdir_of)" = "$GM_DIR" ] \
  && ok "pool dir has no credential at all -> rescues to the next complete account (was: unpinned, pre-2026-08-16)" \
  || bad "missing credential did not rescue to $GM_DIR: got '$(configdir_of)' ERR=$ERR"
write_complete_cred "$CS_DIR"

# The final fallback must survive: with EVERY account husked there is nothing
# to rescue to, and the old unpinned exec is all that is left, the shim must
# still never be the reason `claude` does not start.
write_husk_cred "$CS_DIR"
write_husk_cred "$GM_DIR"
run_shim --
ran_real && [ "$(configdir_of)" = "UNSET" ] \
  && ok "EVERY account husked -> real binary runs UNPINNED (the pre-2026-08-16 final fallback survives a fully dead pool)" \
  || bad "fully dead pool did not fall through unpinned: got '$(configdir_of)' RC=$RC ERR=$ERR"
case "$ERR" in
  *"pinning to"*) bad "fully dead pool still claimed a rescue on stderr: '$ERR'" ;;
  *)              ok "no rescue line when there is nothing to rescue to" ;;
esac
write_complete_cred "$CS_DIR"
write_complete_cred "$GM_DIR"

# and a healthy launch is silent, the rescue line only exists when it engages
run_shim --
[ -z "$ERR" ] \
  && ok "a healthy launch stays silent on stderr (no rescue line unless the rescue engages)" \
  || bad "healthy launch produced stderr: '$ERR'"

# the nested-config trap: never pin AT ~/.claude
{ printf '%s|%s\n' "$CS_EMAIL" "$FAKE_HOME/.claude"; } > "$ACCOUNTS"
run_shim --
ran_real && [ "$(configdir_of)" = "UNSET" ] \
  && ok "fail open: refuses to pin at \$HOME/.claude itself (that is the nested-config trap \`rota repair-nested\` fixes)" \
  || bad "the shim pinned CLAUDE_CONFIG_DIR at the shared dir: got '$(configdir_of)'"
write_accounts

# ───────────────────────────────────────────────────────────────────────────
# 4b. the rescue never trusts the accounts-file LABEL (2026-08-16 review),
#     the map is an auto-reconciled cache that can lie, and a lying label on
#     the rescue path re-creates the 2026-08-11 wrong-account billing.
# ───────────────────────────────────────────────────────────────────────────
# The active account's own row is TYPO'D, so dir_for_email finds nothing,
# while the account's own dir sits right there, healthy and identity-matched.
# Pre-fix the shim borrowed the first foreign account in file order (personal
# here, deliberately listed first); now the identity scan finds the account's
# OWN dir and pins that instead.
printf '{"oauthAccount":{"emailAddress":"%s"}}' "$CS_EMAIL" > "$CS_DIR/.claude.json"
printf '{"oauthAccount":{"emailAddress":"%s"}}' "$GM_EMAIL" > "$GM_DIR/.claude.json"
{ printf '%s|%s\n' "$GM_EMAIL" "$GM_DIR"
  printf 'work-typod@example.com|%s\n' "$CS_DIR"
} > "$ACCOUNTS"
rm -f "$FAKE_HOME/.config/claude-failover/needs-reconcile"
run_shim --
ran_real && [ "$(configdir_of)" = "$CS_DIR" ] \
  && ok "mislabeled OWN row -> rescued BY IDENTITY to the active account's own dir, never a foreign one" \
  || bad "mislabeled own row did not rescue to $CS_DIR by identity: got '$(configdir_of)' ERR=$ERR"
case "$ERR" in
  *"$CS_EMAIL"*"found by identity"*)
    ok "the identity rescue announces itself on stderr, naming the active account" ;;
  *)
    bad "no/wrong stderr diagnostic for the identity rescue: ERR='$ERR'" ;;
esac
[ "$(printf '%s\n' "$ERR" | grep -c '^rota-shim:')" -eq 1 ] \
  && ok "the identity-rescue diagnostic is exactly ONE stderr line" \
  || bad "expected exactly one rota-shim: stderr line, got: '$ERR'"
[ -f "$FAKE_HOME/.config/claude-failover/needs-reconcile" ] \
  && ok "the broken row flags needs-reconcile so the keeper repairs the map" \
  || bad "identity rescue did not flag needs-reconcile"

# And the borrow half: a foreign row whose dir holds a DIFFERENT identity
# than its label is never borrowed UNDER that label, first_complete_account
# skips it and takes the next row that proves itself. (An EMPTY identity
# stays borrowable: unknowable is not a lie, and refusing it would turn
# fail-open into fail-closed.)
write_identity "unmapped@example.com"
printf '{"oauthAccount":{"emailAddress":"intruder@example.com"}}' > "$GM_DIR/.claude.json"
{ printf '%s|%s\n' "$GM_EMAIL" "$GM_DIR"    # lying row FIRST, pre-fix this won
  printf '%s|%s\n' "$CS_EMAIL" "$CS_DIR"
} > "$ACCOUNTS"
run_shim --
ran_real && [ "$(configdir_of)" = "$CS_DIR" ] \
  && ok "first_complete_account SKIPS a row whose dir's identity contradicts its label, borrowing the next VERIFIED row" \
  || bad "mislabeled foreign row was not skipped: got '$(configdir_of)' ERR=$ERR"
case "$ERR" in
  *"pinning to $CS_EMAIL"*)
    ok "the borrow diagnostic names the VERIFIED account, not the lying row" ;;
  *)
    bad "borrow diagnostic wrong: ERR='$ERR'" ;;
esac
rm -f "$CS_DIR/.claude.json" "$GM_DIR/.claude.json" \
      "$FAKE_HOME/.config/claude-failover/needs-reconcile"
write_identity "$CS_EMAIL"
write_accounts

# ───────────────────────────────────────────────────────────────────────────
# 5. the disable switch
# ───────────────────────────────────────────────────────────────────────────
rm -f "$STATE/active-calls"
run_shim CLAUDE_SHIM_DISABLE=1 --
ran_real && [ "$(configdir_of)" = "UNSET" ] \
  && ok "CLAUDE_SHIM_DISABLE=1 bypasses the shim entirely (real binary, no pin)" \
  || bad "CLAUDE_SHIM_DISABLE=1 did not bypass: OUT=$OUT ERR=$ERR"
[ ! -f "$STATE/active-calls" ] \
  && ok "CLAUDE_SHIM_DISABLE=1 does no resolution work at all (no failover subprocess)" \
  || bad "CLAUDE_SHIM_DISABLE=1 still ran identity resolution"

# ───────────────────────────────────────────────────────────────────────────
# 6. NO RECURSION, the shim must never exec itself
# ───────────────────────────────────────────────────────────────────────────
# Both realistic shapes are planted EARLIER on PATH than the fake real binary,
# with CLAUDE_SHIM_DIRS pointed at nothing so the PATH scan is the code path
# under test. A regression here fork-bombs, which the 10s alarm turns into a
# clean FAIL.
LINKDIR="$WORK/pathlink"; mkdir -p "$LINKDIR"
ln -sf "$SHIM" "$LINKDIR/claude"
SHIM_TEST_DIRS="$WORK/does-not-exist" SHIM_TEST_PATH="$LINKDIR:$STUB:$REALDIR:/usr/bin:/bin" run_shim --
ran_real && [ "$RC" -ne 142 ] \
  && ok "PATH scan skips a SYMLINK to the shim named \`claude\` and finds the real binary behind it" \
  || bad "the shim did not skip a symlink to itself (RC=$RC, 142 means it looped until the alarm): OUT=$OUT ERR=$ERR"

COPYDIR="$WORK/pathcopy"; mkdir -p "$COPYDIR"
cp "$SHIM" "$COPYDIR/claude"; chmod +x "$COPYDIR/claude"
SHIM_TEST_DIRS="$WORK/does-not-exist" SHIM_TEST_PATH="$COPYDIR:$STUB:$REALDIR:/usr/bin:/bin" run_shim --
ran_real && [ "$RC" -ne 142 ] \
  && ok "PATH scan skips a full COPY of the shim named \`claude\` (marker match, not just inode) and finds the real binary" \
  || bad "the shim did not skip a copy of itself (RC=$RC, 142 means it looped until the alarm): OUT=$OUT ERR=$ERR"

# and the everyday shape: the shim installed as ~/.local/bin/claude, first on PATH
SELFBIN="$FAKE_HOME/.local/bin"; mkdir -p "$SELFBIN"
ln -sf "$SHIM" "$SELFBIN/claude"
SHIM_TEST_DIRS="$WORK/does-not-exist" SHIM_TEST_PATH="$SELFBIN:$STUB:$REALDIR:/usr/bin:/bin" run_shim --
ran_real && [ "$(configdir_of)" = "$CS_DIR" ] && [ "$RC" -ne 142 ] \
  && ok "the real install shape (~/.local/bin/claude first on PATH) resolves past itself AND still pins correctly" \
  || bad "the real install shape recursed or failed to pin (RC=$RC): OUT=$OUT ERR=$ERR"

# ───────────────────────────────────────────────────────────────────────────
# 7. transparency: argv and exit code belong to the real binary
# ───────────────────────────────────────────────────────────────────────────
run_shim -- --resume "a session title" -p
printf '%s' "$OUT" | grep -q '^ARGS=--resume a session title -p$' \
  && ok "argv is forwarded to the real binary verbatim (quoted arguments survive)" \
  || bad "argv was mangled: $(printf '%s' "$OUT" | sed -n 's/^ARGS=//p')"

run_shim FAKE_CLAUDE_RC=17 --
[ "$RC" -eq 17 ] \
  && ok "the real binary's exit code is the shim's exit code (exec, not a wrapper subprocess)" \
  || bad "exit code not preserved: got $RC, want 17"

# ───────────────────────────────────────────────────────────────────────────
# 8. never leaks a token
# ───────────────────────────────────────────────────────────────────────────
leaked=0
for scenario in normal husk unmapped; do
  case "$scenario" in
    normal)   write_identity "$CS_EMAIL"; write_complete_cred "$CS_DIR" ;;
    husk)     write_husk_cred "$CS_DIR" ;;
    unmapped) write_identity "nobody@example.com"; write_complete_cred "$CS_DIR" ;;
  esac
  run_shim --
  case "$OUT$ERR" in *"$FAKE_TOKEN"*) leaked=1 ;; esac
  case "$OUT$ERR" in *"FAKETOKEN"*)   leaked=1 ;; esac
done
[ "$leaked" -eq 0 ] \
  && ok "no scenario prints the credential, or any slice of it, to stdout or stderr" \
  || bad "a token (or a slice of one) reached the shim's output"

# ───────────────────────────────────────────────────────────────────────────
# 9. no real binary at all, the only non-fail-open exit, and it says why
# ───────────────────────────────────────────────────────────────────────────
EMPTYDIR="$WORK/emptypath"; mkdir -p "$EMPTYDIR"
SHIM_TEST_DIRS="$WORK/does-not-exist" SHIM_TEST_PATH="$EMPTYDIR:/usr/bin:/bin" run_shim --
[ "$RC" -eq 127 ] && case "$ERR" in *"no real \`claude\` binary found"*) true ;; *) false ;; esac \
  && ok "with no claude on the box at all: exit 127 and a message naming where it looked (nothing to fail open TO)" \
  || bad "missing-binary case did not exit 127 with an explanation: RC=$RC ERR=$ERR"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
