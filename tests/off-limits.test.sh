#!/usr/bin/env bash
# off-limits.test.sh (t_9pzwxz): a RESERVED seat (Dazzle calls it "off-limits")
# is never chosen automatically, by ANY rota picker. One pin per picker:
#   reserve            accepts a non-ASCII owner ("Ákos"), lists it, releases it
#   seat_is_reserved   both sources: <seat>/RESERVED and $CFG_DIR/reserved
#   billing / accounts USE NEXT + ranking skip it; --json carries reserved and
#                      reserved_owner per row (Dazzle reads both)
#   keeper auto-switch the unattended 98% wall loop steps over it (pinned by
#                      source, the loop lives inline in main())
#   engine switch-auto / next / usage --json: pinned in tests/engine.test.sh
#                      ("off-limits" scenarios), they need that file's fake claude/curl.
# HERMETIC: temp CLAUDE_POOL_DIR and CFG_DIR, never ~/.claude-pool.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
POOL="$TMP/pool"; CFG="$TMP/cfg"; LIB="$TMP/lib"
mkdir -p "$POOL/akos" "$POOL/tommy" "$CFG" "$LIB"
export CLAUDE_POOL_DIR="$POOL" CLAUDE_FAILOVER_HOME="$CFG" HOME="$TMP/home"
mkdir -p "$HOME"

# --- reserve: non-ASCII owner, list, release ---------------------------------
OUT="$("$ROOT/bin/rota" reserve akos "Ákos" "off-limits (set in Dazzle)" 2>&1)"; RC=$?
check "reserve: Ákos is accepted"                  '[ "$RC" -eq 0 ] && grep -q "reserved akos for Ákos" <<<"$OUT"'
check "reserve: marker holds the owner verbatim"   '[ "$(sed -n "s/^owner=//p" "$POOL/akos/RESERVED")" = "Ákos" ]'
LIST="$("$ROOT/bin/rota" reserve 2>&1)"
check "reserve: bare list names the owner"         'grep -q "Ákos" <<<"$LIST"'
check "reserve: tommy is untouched"                '[ ! -e "$POOL/tommy/RESERVED" ]'
HELP="$("$ROOT/bin/rota" help 2>&1)"
check "help: reserve says it is Dazzle off-limits" 'grep -qi "dazzle calls this .off-limits" <<<"$HELP"'

# --- seat_is_reserved: both sources ------------------------------------------
LIBSRC="$ROOT/lib/rota-ranking.sh"
sir() { ( CFG_DIR="$CFG"; . "$LIBSRC" >/dev/null 2>&1; seat_is_reserved "$1" "$2" ); }
check "seat_is_reserved: marker source"            'sir akos@example.com "$POOL/akos"'
check "seat_is_reserved: unreserved seat is free"  '! sir tommy@example.com "$POOL/tommy"'
printf '# alias owner why\ntommy Joe off-limits\n' > "$CFG/reserved"
check "seat_is_reserved: cfg-line source (alias)"  'sir tommy@example.com "$POOL/tommy"'
check "seat_is_reserved: cfg-line source (label)"  '( printf "tommy@example.com Joe\n" > "$CFG/reserved"; sir tommy@example.com "$TMP/elsewhere" )'
rm -f "$CFG/reserved"

# --- billing: ranking, USE NEXT, json fields ----------------------------------
cp "$ROOT/lib/rota-billing.sh" "$LIB/rota-billing.sh"
cat > "$LIB/rota-engine.sh" <<STUB
#!/usr/bin/env bash
[ "\${1:-}" = "usage" ] && [ "\${2:-}" = "--json" ] || exit 9
cat <<'J'
{"generated_at":"2026-11-24T10:00:00+01:00","activeEmail":"tommy@example.com","floors":{"weekly_pct":20},
 "accounts":[
  {"label":"tommy@example.com","email":"tommy@example.com","alias":"tommy","active":true,"data":"live",
   "config_dir":"$POOL/tommy","weekly":{"remaining_pct":55,"resets_at":"2026-11-30T18:00:00+01:00"},"five_hour":{"remaining_pct":80}},
  {"label":"akos@example.com","email":"akos@example.com","alias":"akos","active":false,"data":"live",
   "config_dir":"$POOL/akos","weekly":{"remaining_pct":90,"resets_at":"2026-11-25T09:00:00+01:00"},"five_hour":{"remaining_pct":100}}
 ]}
J
STUB
chmod +x "$LIB/rota-engine.sh" "$LIB/rota-billing.sh"
echo '{"accounts":{}}' > "$CFG/billing.json"
OUT="$("$LIB/rota-billing.sh" 2>/dev/null)"
check "billing: akos has the soonest reset but USE NEXT never names it" '! grep -A1 "USE NEXT" <<<"$OUT" | grep -q "rota switch akos"'
check "billing: USE NEXT falls to the unreserved seat"                 'grep -A1 "USE NEXT" <<<"$OUT" | grep -q "rota switch tommy"'
check "billing: NOT OFFERED names akos and Ákos"                        'grep -A1 "NOT OFFERED" <<<"$OUT" | grep -q "akos (90% left → Ákos)"'
JOUT="$("$LIB/rota-billing.sh" --json 2>/dev/null)"
jf() { python3 -c "import json,sys;d=json.loads(sys.argv[1]);print([a[sys.argv[3]] for a in d['accounts'] if a['alias']==sys.argv[2]][0])" "$JOUT" "$1" "$2"; }
check "billing --json: reserved flag true on akos"   '[ "$(jf akos reserved)" = True ]'
check "billing --json: reserved_owner is Ákos"       '[ "$(jf akos reserved_owner)" = "Ákos" ]'
check "billing --json: unreserved row is false/empty" '[ "$(jf tommy reserved)" = False ] && [ -z "$(jf tommy reserved_owner)" ]'
OUT2="$("$LIB/rota-billing.sh" --include-reserved 2>/dev/null)"
check "billing: --include-reserved is the explicit override" 'grep -A1 "USE NEXT" <<<"$OUT2" | grep -q "rota switch akos"'

# --- keeper auto-switch: the unattended target loop steps over a reserved seat
LOOP="$(sed -n '/local best=-1 best_wk=/,/hysteresis: don/p' "$ROOT/lib/rota-keeper.sh")"
check "keeper: target loop located"                         '[ -n "$LOOP" ]'
check "keeper: target loop skips seat_is_reserved seats"    'grep -q "seat_is_reserved \"\${LABELS\[\$j\]}\" \"\${DIRS\[\$j\]}\" && continue" <<<"$LOOP"'
check "keeper: the skip comes before any quota is read"     '[ "$(grep -n seat_is_reserved <<<"$LOOP" | head -1 | cut -d: -f1)" -lt "$(grep -n "usage_for" <<<"$LOOP" | head -1 | cut -d: -f1)" ]'
check "keeper: sources rota-ranking.sh (seat_is_reserved)"  'grep -q "rota-ranking.sh" "$ROOT/lib/rota-keeper.sh"'

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
