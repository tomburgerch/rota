#!/usr/bin/env bash
# shellcheck disable=SC2015
#
# chrome-default.test.sh: every seat and ~/.claude.json gets
# claudeInChromeDefaultEnabled=false when the key is absent (t_n8srwe), so a
# resumed session never stops on Claude Code's "Claude in Chrome extension
# detected" screen. HERMETIC: temp HOME, the real engine command, no keeper tick.
set -uo pipefail

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'ok   - %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL - %s\n' "$1"; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
ENGINE="$ROOT/lib/rota-engine.sh"
KEEPER="$ROOT/lib/rota-keeper.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/rota-chrome-default.XXXXXX")"
WORK="$(cd "$WORK" && pwd)"
REAL_HOME="$HOME"
trap 'export HOME="$REAL_HOME"; rm -rf "$WORK"' EXIT
export HOME="$WORK" CLAUDE_FAILOVER_HOME="$WORK/cfg"
unset CLAUDE_POOL_DIR
POOL="$WORK/.claude-pool"
mkdir -p "$POOL/absent" "$POOL/istrue" "$POOL/isfalse" "$POOL/broken" "$POOL/keep" "$POOL/x.lock" "$WORK/cfg"

printf '{"oauthAccount":{"emailAddress":"a@example.com"},"numStartups":7}\n' > "$POOL/absent/.claude.json"
printf '{"claudeInChromeDefaultEnabled":true,"hasCompletedClaudeInChromeOnboarding":true}\n' > "$POOL/istrue/.claude.json"
printf '{"claudeInChromeDefaultEnabled":false}\n' > "$POOL/isfalse/.claude.json"
printf '{"oauthAccount": {"emailAddress":' > "$POOL/broken/.claude.json"
printf '{"projects":{"/x":{"a":1}},"theme":"dark"}\n' > "$POOL/keep/.claude.json"
chmod 640 "$POOL/keep/.claude.json"
printf '{"numStartups":1}\n' > "$POOL/x.lock/.claude.json"
printf '{"numStartups":3}\n' > "$HOME/.claude.json"
BROKEN_BEFORE="$(cksum < "$POOL/broken/.claude.json")"
LOCK_BEFORE="$(cksum < "$POOL/x.lock/.claude.json")"

OUT="$(bash "$ENGINE" chrome-default 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ok "exit 0" || bad "exit (rc=$RC: $OUT)"

jq -e '.claudeInChromeDefaultEnabled == false and .numStartups == 7 and .oauthAccount.emailAddress == "a@example.com"' \
  "$POOL/absent/.claude.json" >/dev/null && ok "absent key gets false, other keys kept" || bad "absent key"
jq -e '.claudeInChromeDefaultEnabled == true and .hasCompletedClaudeInChromeOnboarding == true' \
  "$POOL/istrue/.claude.json" >/dev/null && ok "existing true stays true" || bad "true overwritten"
jq -e '.claudeInChromeDefaultEnabled == false' "$POOL/isfalse/.claude.json" >/dev/null \
  && ok "existing false stays false" || bad "false changed"
[ "$(cksum < "$POOL/broken/.claude.json")" = "$BROKEN_BEFORE" ] && ok "unparseable file untouched" || bad "broken file modified"
grep -q "broken/.claude.json is not valid JSON" <<<"$OUT" && ok "unparseable file logs one line" || bad "no bad-json line ($OUT)"
jq -e '.claudeInChromeDefaultEnabled == false and .theme == "dark" and .projects["/x"].a == 1' \
  "$POOL/keep/.claude.json" >/dev/null && ok "nested keys preserved" || bad "nested keys lost"
MODE="$(stat -f %Lp "$POOL/keep/.claude.json" 2>/dev/null || stat -c %a "$POOL/keep/.claude.json")"
[ "$MODE" = "640" ] && ok "file mode preserved" || bad "mode is $MODE"
[ "$(cksum < "$POOL/x.lock/.claude.json")" = "$LOCK_BEFORE" ] && ok ".lock dir skipped" || bad ".lock dir touched"
jq -e '.claudeInChromeDefaultEnabled == false and .numStartups == 3' "$HOME/.claude.json" >/dev/null \
  && ok "~/.claude.json handled" || bad "~/.claude.json"
[ -z "$(find "$POOL" "$HOME" -maxdepth 2 -name '.claude.json.chrome.*')" ] && ok "no temp files left" || bad "temp file left"
grep -q "chrome-default: set claudeInChromeDefaultEnabled=false in ~/.claude-pool/absent/.claude.json" <<<"$OUT" \
  && ok "one log line per changed file" || bad "log line ($OUT)"
[ "$(grep -c 'chrome-default: set' <<<"$OUT")" -eq 3 ] && ok "exactly the three changed files logged" || bad "count ($OUT)"

OUT2="$(bash "$ENGINE" chrome-default 2>&1)"
grep -q 'chrome-default: set' <<<"$OUT2" && bad "second run changed something" || ok "second run is a no-op"

# the keeper tick calls the step
grep -q 'FAILOVER" chrome-default' "$KEEPER" && ok "keeper tick calls chrome-default" || bad "keeper does not call chrome-default"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
