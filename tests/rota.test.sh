#!/usr/bin/env bash
# Hermetic test for bin/rota: every lib script is a stub, `claude` on PATH is a stub.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
check() { if eval "$2"; then ok "$1"; else fail "$1"; fi; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
FAKE="$TMP/rota"; mkdir -p "$FAKE/bin" "$FAKE/lib" "$FAKE/config" "$TMP/pathbin" "$TMP/cfg" "$TMP/home"
cp "$ROOT/bin/rota" "$FAKE/bin/rota"; cp "$ROOT/VERSION" "$FAKE/VERSION"
: > "$FAKE/config/accounts.example"

# Stub every lib sibling: each records its argv and exits 0.
for s in rota-engine.sh rota-keeper.sh rota-cred-guard.sh rota-billing.sh; do
  printf '#!/usr/bin/env bash\necho "%s: $*"\n' "$s" > "$FAKE/lib/$s"; chmod +x "$FAKE/lib/$s"
done
# Stub claude: prints the config dir it was launched with.
printf '#!/usr/bin/env bash\necho "stub-claude CLAUDE_CONFIG_DIR=${CLAUDE_CONFIG_DIR:-unset}"\n' > "$TMP/pathbin/claude"
chmod +x "$TMP/pathbin/claude"

export PATH="$TMP/pathbin:$PATH"
export CLAUDE_FAILOVER_HOME="$TMP/cfg"
export HOME="$TMP/home"
unset ROTA_LIB
R="$FAKE/bin/rota"

echo "rota.test.sh"

# --- help lists every verb ------------------------------------------------------
HELP="$("$R" help)"; RC=$?
check "help: exit 0" '[ "$RC" -eq 0 ]'
for v in usage accounts switch login billing status keeper-status keeper cred-guard cred-restore \
         reconcile normalize pool-init adopt-shared pane-converge repair-nested roster active next failover help version; do
  check "help lists '$v'" 'grep -qE "^  [a-z| -]*\b'"$v"'\b" <<<"$HELP"'
done
check "help: no home paths leak" '! grep -qE "/Users/|/home/" <<<"$HELP"'

# --- version ---------------------------------------------------------------------
check "version prints 0.1.0" '[ "$("$R" version)" = "0.1.0" ]'

# --- symlink resolution ----------------------------------------------------------
ln -s "$FAKE/bin/rota" "$TMP/pathbin/rota"
check "symlinked rota resolves its root (version via symlink)" '[ "$(rota version)" = "0.1.0" ]'
check "symlinked rota reaches lib (roster via symlink)" '[ "$(rota roster)" = "rota-engine.sh: roster" ]'

# --- dispatch ------------------------------------------------------------------
check "failover roster reaches engine"    '[ "$("$R" failover roster)" = "rota-engine.sh: roster" ]'
check "usage reaches engine usage"        '[ "$("$R" usage --json)" = "rota-engine.sh: usage --json" ]'
check "accounts aliases usage"            '[ "$("$R" accounts)" = "rota-engine.sh: usage" ]'
check "switch bare -> switch-auto"        '[ "$("$R" switch)" = "rota-engine.sh: switch-auto" ]'
check "switch seat -> switch-all + flags" '[ "$("$R" switch work --force)" = "rota-engine.sh: switch-all work --force" ]'
check "status reaches engine"             '[ "$("$R" status)" = "rota-engine.sh: status" ]'
check "billing reaches billing"           '[ "$("$R" billing --json)" = "rota-billing.sh: --json" ]'
check "keeper reaches keeper"             '[ "$("$R" keeper)" = "rota-keeper.sh: " ]'
check "cred-guard -> guard run"           '[ "$("$R" cred-guard)" = "rota-cred-guard.sh: run" ]'
check "cred-restore <seat> -> guard restore" '[ "$("$R" cred-restore work)" = "rota-cred-guard.sh: restore work" ]'
check "cred-restore without seat exits 2" '"$R" cred-restore >/dev/null 2>&1; [ $? -eq 2 ]'
for v in reconcile normalize pool-init adopt-shared pane-converge repair-nested active next; do
  check "$v passes through to engine" '[ "$("$R" '"$v"')" = "rota-engine.sh: '"$v"'" ]'
done

# --- unknown verb ------------------------------------------------------------------
"$R" bogus >/dev/null 2>"$TMP/err"; RC=$?
check "unknown verb exits 2"        '[ "$RC" -eq 2 ]'
check "unknown verb names itself"   'grep -q "unknown verb: bogus" "$TMP/err"'

# --- keeper-status -------------------------------------------------------------------
echo "tick 2026-08-24T10:00" > "$TMP/cfg/keeper-status"; seq 1 30 > "$TMP/cfg/keeper.log"
KS="$("$R" keeper-status)"
check "keeper-status prints the status file" 'grep -q "tick 2026-08-24T10:00" <<<"$KS"'
check "keeper-status tails 20 log lines"     '[ "$(grep -cE "^[0-9]+$" <<<"$KS")" -eq 20 ] && grep -q "^11$" <<<"$KS" && ! grep -q "^10$" <<<"$KS"'

# --- login ---------------------------------------------------------------------------
mkdir -p "$TMP/home/.claude-pool/work"
printf '# comment\nwork@example.com|~/.claude-pool/work\n' > "$TMP/cfg/accounts"
OUT="$("$R" login work)"
check "login by alias: banner names the seat"  'grep -q "logging in seat work" <<<"$OUT"'
check "login by alias: execs claude with CLAUDE_CONFIG_DIR=<dir>, ~ expanded" \
  'grep -q "stub-claude CLAUDE_CONFIG_DIR=$TMP/home/.claude-pool/work" <<<"$OUT"'
OUT="$("$R" login work@example.com)"
check "login by label works too" 'grep -q "stub-claude CLAUDE_CONFIG_DIR=$TMP/home/.claude-pool/work" <<<"$OUT"'
check "login banner says to run /login" 'grep -q "/login" <<<"$OUT"'

# seat dir missing -> pool-init is called first; the stub engine does not create it, so exit 2
printf 'personal@example.com|~/.claude-pool/personal\n' >> "$TMP/cfg/accounts"
OUT="$("$R" login personal 2>&1)"; RC=$?
check "login with missing dir runs pool-init first" 'grep -q "rota-engine.sh: pool-init" <<<"$OUT"'
check "login with dir still missing exits 2"        '[ "$RC" -eq 2 ]'

# accounts file missing -> instructions, exit 2, no pool-init
rm "$TMP/cfg/accounts"
OUT="$("$R" login work 2>&1)"; RC=$?
check "login without accounts file exits 2"            '[ "$RC" -eq 2 ]'
check "login without accounts file points at example"  'grep -q "config/accounts.example" <<<"$OUT"'
check "login without seat arg exits 2"                 '"$R" login >/dev/null 2>&1; [ $? -eq 2 ]'

printf 'rota.test.sh: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
