#!/usr/bin/env bash
# Hermetic test for lib/rota-billing.sh: a fake CFG_DIR holding a billing.json and
# a stub engine that prints a fixed `usage --json`. No network, no ssh.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
check() { if eval "$2"; then ok "$1"; else fail "$1"; fi; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
CFG="$TMP/cfg"; LIB="$TMP/lib"; mkdir -p "$CFG" "$LIB"

# The script under test, copied next to a STUB engine so "$ROTA_LIB/rota-engine.sh"
# resolves to the stub and never to a real engine (which may not exist yet).
cp "$ROOT/lib/rota-billing.sh" "$LIB/rota-billing.sh"
cat > "$LIB/rota-engine.sh" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = "usage" ] && [ "${2:-}" = "--json" ] || { echo "stub: unexpected args: $*" >&2; exit 9; }
echo "stub-noise-before-json"
cat <<'J'
{"generated_at":"2026-08-24T10:00:00+02:00","activeEmail":"work@example.com","floors":{"weekly_pct":20},
 "accounts":[
  {"label":"work@example.com","email":"work@example.com","alias":"work","active":true,"data":"live",
   "weekly":{"remaining_pct":55,"resets_at":"2026-08-27T18:00:00+02:00"},"five_hour":{"remaining_pct":80}},
  {"label":"personal@example.com","email":"personal@example.com","alias":"personal","active":false,"data":"live",
   "config_dir":"POOLDIR/personal",
   "weekly":{"remaining_pct":90,"resets_at":"2026-08-25T09:00:00+02:00"},"five_hour":{"remaining_pct":100}},
  {"label":"team@example.com","email":"team@example.com","alias":"team","active":false,"data":"live",
   "weekly":{"remaining_pct":0,"resets_at":"2026-08-29T12:00:00+02:00"},"five_hour":{"remaining_pct":100}},
  {"label":"dup@example.com","email":"work@example.com","alias":"work2","active":false,"data":"dup"}
 ]}
J
STUB
sed -i.bak "s|POOLDIR|$TMP/pool|" "$LIB/rota-engine.sh"
cp "$LIB/rota-engine.sh" "$TMP/engine.good"
chmod +x "$LIB/rota-engine.sh" "$LIB/rota-billing.sh"

cat > "$CFG/billing.json" <<'J'
{"accounts":{
  "work@example.com":{"plan":"Max 20x","renews_day":7,"amount_display":"$200.00","usd_approx":200,"status":"active"},
  "personal@example.com":{"plan":"Max 5x","renews_day":15,"amount_display":"$100.00","usd_approx":100,"status":"active"},
  "team@example.com":{"plan":"Max 20x","renews_day":1,"amount_display":"$200.00","usd_approx":200,"status":"cancelled","ends":"2026-09-01"}
}}
J

export CLAUDE_FAILOVER_HOME="$CFG"
unset ROTA_POOL_HOST CLAUDE_POOL_HOST CLAUDE_BILLING_JSON
export PATH="$TMP/nossh:$PATH"; mkdir -p "$TMP/nossh"
printf '#!/bin/sh\necho "ssh must not be called" >&2; exit 99\n' > "$TMP/nossh/ssh"; chmod +x "$TMP/nossh/ssh"
# Pin the host name so the table never depends on the machine running the test.
printf '#!/bin/sh\necho testbox\n' > "$TMP/nossh/scutil"; chmod +x "$TMP/nossh/scutil"

echo "billing.test.sh"

# --- table output ------------------------------------------------------------
OUT="$("$LIB/rota-billing.sh" 2>"$TMP/err")"; RC=$?
check "table: exit 0"                         '[ "$RC" -eq 0 ]'
check "table: header row present"             'grep -q "SEAT .*WEEKLY LEFT .*GONE IN .*NEXT CHARGE .*NOTES" <<<"$OUT"'
check "table: active seat marked with <"      'grep -q "work@example.com <" <<<"$OUT"'
check "table: personal row shows 90%"         'grep -E "personal@example.com.* 90%" <<<"$OUT" >/dev/null'
check "table: cancelled seat labelled"        'grep -q "CANCELLED, ends 1 Sep" <<<"$OUT"'
check "table: dup row skipped"                '! grep -q "work2" <<<"$OUT"'
check "table: USE NEXT picks soonest reset (personal)" 'grep -A1 "USE NEXT" <<<"$OUT" | grep -q "rota switch personal"'
check "table: spent seat blanks 5h column"    'grep "team@example.com" <<<"$OUT" | grep -qv "100%"'
check "table: no ssh attempted"               '! grep -q "ssh must not be called" "$TMP/err"'
check "table: host name comes from scutil"   'grep -q "Seats on testbox" <<<"$OUT"'
check "table: every address shown is a fixture address" '[ -z "$(grep -oE "[a-z0-9.]+@[a-z0-9.]+" <<<"$OUT" | grep -v "@example\\.com")" ]'
check "table: no home paths leak"             '! grep -qE "/Users/|/home/" <<<"$OUT"'

# --- json output -------------------------------------------------------------
JOUT="$("$LIB/rota-billing.sh" --json 2>/dev/null)"; RC=$?
check "json: exit 0"                          '[ "$RC" -eq 0 ]'
check "json: parses"                          'python3 -c "import json,sys;json.loads(sys.argv[1])" "$JOUT"'
check "json: active is work@example.com"      '[ "$(python3 -c "import json,sys;print(json.loads(sys.argv[1])[\"active\"])" "$JOUT")" = work@example.com ]'
check "json: three accounts (dup dropped)"    '[ "$(python3 -c "import json,sys;print(len(json.loads(sys.argv[1])[\"accounts\"]))" "$JOUT")" = 3 ]'
check "json: monthly total is 300 (cancelled seat ends before its next charge)" \
  '[ "$(python3 -c "import json,sys;print(json.loads(sys.argv[1])[\"monthly_total_usd_approx\"])" "$JOUT")" = "300.0" ]'
check "json: cancelled seat has next_charge null" \
  '[ "$(python3 -c "import json,sys;d=json.loads(sys.argv[1]);print([a[\"next_charge\"] for a in d[\"accounts\"] if a[\"account\"]==\"team@example.com\"][0])" "$JOUT")" = None ]'
check "json: plan carried from billing.json"  'grep -q "\"plan\": \"Max 5x\"" <<<"$JOUT"'

# --- missing billing.json ------------------------------------------------------
ERR="$(CLAUDE_FAILOVER_HOME="$TMP/empty" "$LIB/rota-billing.sh" 2>&1 >/dev/null)"; RC=$?
check "missing billing.json: exit 2"          '[ "$RC" -eq 2 ]'
check "missing billing.json: tells how to create it from the example" 'grep -q "billing.example.json" <<<"$ERR"'

# --- --local with a POOL_HOST set must not ssh --------------------------------
OUT="$(ROTA_POOL_HOST=some-other-box "$LIB/rota-billing.sh" --local 2>"$TMP/err")"; RC=$?
check "--local: exit 0 with POOL_HOST set"    '[ "$RC" -eq 0 ]'
check "--local: no ssh attempted"             '! grep -q "ssh must not be called" "$TMP/err"'

# --- engine returning nothing must fail loudly --------------------------------
printf '#!/bin/sh\nexit 0\n' > "$LIB/rota-engine.sh"
ERR="$("$LIB/rota-billing.sh" 2>&1 >/dev/null)"; RC=$?
check "empty engine output: exit 1"           '[ "$RC" -eq 1 ]'
check "empty engine output: says so"          'grep -q "returned nothing" <<<"$ERR"'

# --- whose seat is it -------------------------------------------------------
# ⚠️ RESTORE THE STUB FIRST. The "engine returning nothing" case above
# deliberately replaces $LIB/rota-engine.sh with `exit 0`, so anything appended
# after it inherits an engine that produces no accounts - every check below then
# fails for a reason that has nothing to do with what it is testing.
cp "$TMP/engine.good" "$LIB/rota-engine.sh"; chmod +x "$LIB/rota-engine.sh"

# The defect this whole column exists for: on 2026-08-25 the table printed
# `USE NEXT rota switch tommy` for a seat handed to a colleague the day before,
# because it ranked on quota alone. `personal` is the fixture's best seat by
# quota AND by soonest reset, so if a reservation cannot displace it here,
# nothing about the exclusion is actually working.

# (a) a RESERVED marker inside the seat's own config dir
mkdir -p "$TMP/pool/personal"
printf 'owner=airmond-runner\nwhy=pushed to the runners\n' > "$TMP/pool/personal/RESERVED"
OUT="$("$LIB/rota-billing.sh" 2>/dev/null)"
check "marker: reserved seat is labelled"        'grep -q "RESERVED" <<<"$OUT"'
check "marker: the owner is named"               'grep -q "airmond-runner" <<<"$OUT"'
check "marker: USE NEXT no longer picks it"      '! grep -A1 "USE NEXT" <<<"$OUT" | grep -q "rota switch personal"'
check "marker: USE NEXT falls to the next seat"  'grep -A1 "USE NEXT" <<<"$OUT" | grep -q "rota switch work"'
check "marker: withheld seat is named out loud"  'grep -A1 "NOT OFFERED" <<<"$OUT" | grep -q "personal"'
# ⚠️ Labels use the ALIAS, never the email local-part. Two seats can share a
# local-part (a personal and a work address for one person), and then the line
# names the wrong seat or the same name twice. Measured on the real pool:
# gmail and cs are both "cedric.waldburger", so NOT OFFERED read
# "cedric.waldburger ... · cedric.waldburger ...".
check "labels: NOT OFFERED uses the alias, not the local-part" \
  'grep -A1 "NOT OFFERED" <<<"$OUT" | grep -q "personal ("'
check "marker: json carries the reservation"     '[ "$("$LIB/rota-billing.sh" --json 2>/dev/null | python3 -c "import json,sys;print([a[\"reserved_owner\"] for a in json.load(sys.stdin)[\"accounts\"] if a[\"alias\"]==\"personal\"][0])")" = airmond-runner ]'

# --include-reserved is the deliberate override, and must actually override
OUT2="$("$LIB/rota-billing.sh" --include-reserved 2>/dev/null)"
check "--include-reserved: picks the reserved seat again" 'grep -A1 "USE NEXT" <<<"$OUT2" | grep -q "rota switch personal"'
check "--include-reserved: drops the NOT OFFERED note"    '! grep -q "NOT OFFERED" <<<"$OUT2"'
rm -rf "$TMP/pool/personal"

# (b) $CFG_DIR/reserved, for a seat with no marker on this box
printf '# alias owner why\nwork corp-runner handed over\n' > "$CFG/reserved"
OUT="$("$LIB/rota-billing.sh" 2>/dev/null)"
check "config: reserved seat is labelled"        'grep -q "corp-runner" <<<"$OUT"'
check "config: comments are ignored"             '! grep -q "^# alias" <<<"$OUT"'
check "config: USE NEXT still picks the free seat" 'grep -A1 "USE NEXT" <<<"$OUT" | grep -q "rota switch personal"'

# (c) THE UNION. A box that grows its first marker must not un-reserve every
# seat named only in the config - the exact quiet downgrade this guards against.
mkdir -p "$TMP/pool/personal"
printf 'owner=airmond-runner\n' > "$TMP/pool/personal/RESERVED"
OUT="$("$LIB/rota-billing.sh" 2>/dev/null)"
check "union: the marker seat is reserved"       'grep -q "airmond-runner" <<<"$OUT"'
check "union: the config seat is STILL reserved" 'grep -q "corp-runner" <<<"$OUT"'
check "union: nothing is recommended now"        'grep -q "NOT OFFERED" <<<"$OUT"'
rm -rf "$TMP/pool/personal" "$CFG/reserved"

# --- readability ------------------------------------------------------------
OUT="$("$LIB/rota-billing.sh" 2>/dev/null)"
check "table: countdown column is rendered"      'grep -qE "[0-9]+d [0-9]{2}h|[0-9]+h [0-9]{2}m|due" <<<"$OUT"'
check "table: weekly bar is drawn"               'grep -q "\u2588" <<<"$OUT" || grep -q "░" <<<"$OUT"'

printf 'billing.test.sh: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
