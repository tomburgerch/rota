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

# --- the pool host can live in a FILE, not only the environment ---------------
# A laptop's pool host is a property of the machine; an env var only reaches the
# shell that exported it, so the same command answered differently in a terminal
# and under launchd. The file sits beside `accounts` and `peers`.
printf '# the always-on box\nballito\n' > "$CFG/pool-host"
# The reachability probe silences its own stderr, so the evidence that routing
# happened is the fall-through warning, which names the host it could not reach.
ERR="$("$LIB/rota-billing.sh" 2>&1 >/dev/null)"; RC=$?
check "pool-host file: routes to the named box" 'grep -q "ballito unreachable" <<<"$ERR"'
OUT="$("$LIB/rota-billing.sh" --local 2>"$TMP/err")"; RC=$?
check "pool-host file: --local still reads this box"  '[ "$RC" -eq 0 ]'
check "pool-host file: --local attempts no ssh"       '! grep -q "ssh must not be called" "$TMP/err"'
ERR="$(ROTA_POOL_HOST=testbox "$LIB/rota-billing.sh" 2>&1 >/dev/null)"; RC=$?
check "pool-host file: the environment wins over it"  '! grep -q "ssh must not be called" <<<"$ERR"'
printf '  ballito  \nextra-host\n' > "$CFG/pool-host"
ERR="$("$LIB/rota-billing.sh" 2>&1 >/dev/null)"
check "pool-host file: first host only, whitespace stripped" 'grep -q "ballito unreachable" <<<"$ERR"'
check "pool-host file: a second line is ignored, never dialled" '! grep -q "extra-host" <<<"$ERR"'
printf '# only a comment\n\n' > "$CFG/pool-host"
OUT="$("$LIB/rota-billing.sh" 2>"$TMP/err")"; RC=$?
check "pool-host file: comments-only reads as unset"  '[ "$RC" -eq 0 ]'
check "pool-host file: comments-only attempts no ssh" '! grep -q "ssh must not be called" "$TMP/err"'
rm -f "$CFG/pool-host"

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

# --- provenance and age in NOTES --------------------------------------------
# ⚠️ THE FAILURE THIS PREVENTS, measured 2026-08-27: a seat whose access token had
# been dead for ~59h (nothing runs a session on it, so the keeper cannot rotate it
# either, and the staleness is structural) rendered a confident `27%` weekly with a
# bare `[quota cached]` behind it. Cédric reads this table to decide where to send
# work; a 2.5-day-old number shown like a live one is worse than a blank, because a
# blank sends him to look and a confident number does not.
#
# So every number that is NOT a live local measurement carries WHOSE it is and,
# past two minutes, HOW OLD. A fresh engine stub is written here rather than
# amending the one above: the cases only make sense against rows that are
# deliberately not live.
cat > "$LIB/rota-engine.sh" <<STUB
#!/usr/bin/env bash
[ "\${1:-}" = "usage" ] && [ "\${2:-}" = "--json" ] || { echo "stub: unexpected args: \$*" >&2; exit 9; }
cat <<J
{"generated_at":"$(date -u '+%Y-%m-%dT%H:%M:%SZ')","activeEmail":"work@example.com",
 "floors":{"weekly_pct":20},
 "peer":{"host":"peerbox","generated_at":"$(date -u '+%Y-%m-%dT%H:%M:%SZ')"},
 "accounts":[
  {"label":"work@example.com","email":"work@example.com","alias":"work","active":true,
   "data":"live","quota_data":"live","quota_source":null,
   "quota_measured_at":"$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
   "weekly":{"remaining_pct":55,"resets_at":"$(date -u -v+3d '+%Y-%m-%dT%H:%M:%S+00:00')"},"five_hour":{"remaining_pct":80}},
  {"label":"personal@example.com","email":"personal@example.com","alias":"personal","active":false,
   "data":"peer","quota_data":"peer","quota_source":"peerbox",
   "quota_measured_at":"$(date -u -v-30S '+%Y-%m-%dT%H:%M:%SZ')",
   "weekly":{"remaining_pct":90,"resets_at":"$(date -u -v+1d '+%Y-%m-%dT%H:%M:%S+00:00')"},"five_hour":{"remaining_pct":100}},
  {"label":"team@example.com","email":"team@example.com","alias":"team","active":false,
   "data":"peer","quota_data":"peer","quota_source":"peerbox",
   "quota_measured_at":"$(date -u -v-2d '+%Y-%m-%dT%H:%M:%SZ')",
   "weekly":{"remaining_pct":40,"resets_at":"$(date -u -v+5d '+%Y-%m-%dT%H:%M:%S+00:00')"},"five_hour":{"remaining_pct":70}}
 ]}
J
STUB
chmod +x "$LIB/rota-engine.sh"

OUT="$("$LIB/rota-billing.sh" 2>/dev/null)"
check "notes: a peer-sourced row says which box measured it" \
  'grep "personal@example.com" <<<"$OUT" | grep -q "\[via peerbox\]"'
check "notes: a peer row measured 30s ago carries no age (below 120s it IS now)" \
  '! grep "personal@example.com" <<<"$OUT" | grep -qE "\[via peerbox, [0-9]+[mhd] old\]"'
check "notes: a two-day-old peer row shows its age, in one coarse unit" \
  'grep "team@example.com" <<<"$OUT" | grep -q "\[via peerbox, 2d old\]"'
check "notes: a live local row carries NO provenance marker (unmarked means measured here, now)" \
  '! grep "work@example.com" <<<"$OUT" | grep -qE "\[(via|cached|quota) "'
check "legend: names the peer, and says no credential is copied" \
  'grep -q "were read over ssh from that box" <<<"$OUT" && grep -q "no credential is ever copied" <<<"$OUT"'
check "notes: CANCELLED still renders alongside the provenance marker" \
  'grep "team@example.com" <<<"$OUT" | grep -q "CANCELLED"'

JOUT="$("$LIB/rota-billing.sh" --json 2>/dev/null)"
check "json: quota_source is passed through per row" \
  '[ "$(python3 -c "import json,sys;d=json.loads(sys.argv[1]);print([a[\"quota_source\"] for a in d[\"accounts\"] if a[\"account\"]==\"team@example.com\"][0])" "$JOUT")" = peerbox ]'
check "json: quota_data reads peer for a borrowed row" \
  '[ "$(python3 -c "import json,sys;d=json.loads(sys.argv[1]);print([a[\"quota_data\"] for a in d[\"accounts\"] if a[\"account\"]==\"team@example.com\"][0])" "$JOUT")" = peer ]'
check "json: quota_measured_at is present, so a machine gets the same honesty" \
  '[ "$(python3 -c "import json,sys;d=json.loads(sys.argv[1]);print(bool([a[\"quota_measured_at\"] for a in d[\"accounts\"] if a[\"account\"]==\"team@example.com\"][0]))" "$JOUT")" = True ]'
check "json: the top-level peer object is carried through" \
  '[ "$(python3 -c "import json,sys;print(json.loads(sys.argv[1])[\"peer\"][\"host\"])" "$JOUT")" = peerbox ]'

# --- a STALE LOCAL cached row, with no peer anywhere in the picture -----------
# The same defect, the half that has nothing to do with ssh: this is the shape
# that actually shipped, and fixing only the peer half would have left the two
# seats most worth distrusting looking the most trustworthy.
cat > "$LIB/rota-engine.sh" <<STUB
#!/usr/bin/env bash
[ "\${1:-}" = "usage" ] && [ "\${2:-}" = "--json" ] || { echo "stub: unexpected args: \$*" >&2; exit 9; }
cat <<J
{"generated_at":"$(date -u '+%Y-%m-%dT%H:%M:%SZ')","activeEmail":"work@example.com",
 "floors":{"weekly_pct":20},"peer":null,
 "accounts":[
  {"label":"work@example.com","email":"work@example.com","alias":"work","active":true,
   "data":"live","quota_data":"live","quota_source":null,
   "quota_measured_at":"$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
   "weekly":{"remaining_pct":55,"resets_at":"$(date -u -v+3d '+%Y-%m-%dT%H:%M:%S+00:00')"},"five_hour":{"remaining_pct":80}},
  {"label":"team@example.com","email":"team@example.com","alias":"team","active":false,
   "data":"cached","quota_data":"cached","quota_source":null,
   "quota_measured_at":"$(date -u -v-2d '+%Y-%m-%dT%H:%M:%SZ')",
   "weekly":{"remaining_pct":27,"resets_at":"$(date -u -v+5d '+%Y-%m-%dT%H:%M:%S+00:00')"},"five_hour":{"remaining_pct":70}}
 ]}
J
STUB
chmod +x "$LIB/rota-engine.sh"
OUT="$("$LIB/rota-billing.sh" 2>/dev/null)"
check "notes: a two-day-old LOCAL cache says [cached, 2d old], not a bare [quota cached]" \
  'grep "team@example.com" <<<"$OUT" | grep -q "\[cached, 2d old\]"'
check "notes: and the old unqualified marker is gone for good" \
  '! grep -q "\[quota cached\]" <<<"$OUT"'
# ⚠️ NOT "the legend is unchanged": the LEAD-IN changed on purpose and in every
# case ("quota is measured live" over-claimed for the whole table, which is the
# same defect the per-row markers retire). What is conditional is the PEER CLAUSE,
# and that is what this pins, on both the new lead-in and the absent clause.
check "legend: the lead-in no longer promises LIVE for the whole table" \
  'grep -q "quota is measured live unless the row says otherwise" <<<"$OUT"'
check "legend: with no peer used, no peer clause is appended" \
  '! grep -q "read over ssh" <<<"$OUT"'

# --- UNMEASURED: quota UNKNOWN is not quota SPENT -----------------------------
# ⚠️ THE FAILURE THIS PREVENTS, measured 2026-08-21 and again 2026-08-27. A seat
# whose cached weekly number describes a window that has SINCE ROLLED has no
# usable number at all, and `cdt accounts` rendered that as a bare `-` in the
# same visually-empty column that a genuinely spent seat fills with `0%`. On the
# 21st two cancelled-but-live seats were written off that way while each still
# carried roughly two more full weekly refreshes of already-paid-for quota. On
# the 27th tartare's row read `- · due · Thu 27 Aug 19:00` two hours AFTER that
# window refilled, on a seat whose usage API answers 429 every time, so nothing
# was ever going to correct it on its own.
#
# Fixtures here are RELATIVE to today (`date -v`) and carry their own
# billing.json via CLAUDE_BILLING_JSON: the dates in the shared fixture at the
# top of this file are absolute, and a seat-end date that quietly slides into
# the past would turn these into passes that stop testing anything.
UN_BILL="$TMP/billing-unmeasured.json"
UN_ENDS="$(date -v+4d '+%Y-%m-%d')"          # after today, BEFORE the rolled-forward reset (+7d)
cat > "$UN_BILL" <<J
{"accounts":{
  "work@example.com":{"plan":"Max 20x","renews_day":7,"amount_display":"\$200.00","usd_approx":200,"status":"active"},
  "spent@example.com":{"plan":"Max 5x","renews_day":15,"amount_display":"\$100.00","usd_approx":100,"status":"active"},
  "team@example.com":{"plan":"Max 20x","renews_day":1,"amount_display":"\$200.00","usd_approx":200,"status":"cancelled","ends":"$UN_ENDS"}
}}
J

# tartare's real shape: a peer-sourced number measured a day ago, for a weekly
# window that rolled two hours ago, on a cancelled seat. Plus the two rows it
# has to stay visually distinct from: a live one and a genuinely SPENT one.
write_unmeasured_stub() {  # write_unmeasured_stub <unmeasured-flag> <weekly-pct-or-null> <floor>
  cat > "$LIB/rota-engine.sh" <<STUB
#!/usr/bin/env bash
[ "\${1:-}" = "usage" ] && [ "\${2:-}" = "--json" ] || { echo "stub: unexpected args: \$*" >&2; exit 9; }
cat <<J
{"generated_at":"$(date -u '+%Y-%m-%dT%H:%M:%SZ')","activeEmail":"work@example.com",
 "floors":{"weekly_pct":$3},
 "peer":{"host":"ballito","generated_at":"$(date -u '+%Y-%m-%dT%H:%M:%SZ')"},
 "accounts":[
  {"label":"work@example.com","email":"work@example.com","alias":"work","active":true,
   "data":"live","quota_data":"live","quota_source":null,
   "quota_measured_at":"$(date -u '+%Y-%m-%dT%H:%M:%SZ')","unmeasured":false,
   "seat":{"status":"active","ends":null,"ended":false},
   "weekly":{"remaining_pct":55,"resets_at":"$(date -u -v+3d '+%Y-%m-%dT%H:%M:%S+00:00')","expired":false},
   "five_hour":{"remaining_pct":80}},
  {"label":"spent@example.com","email":"spent@example.com","alias":"spent","active":false,
   "data":"live","quota_data":"live","quota_source":null,
   "quota_measured_at":"$(date -u '+%Y-%m-%dT%H:%M:%SZ')","unmeasured":false,
   "seat":{"status":"active","ends":null,"ended":false},
   "weekly":{"remaining_pct":0,"resets_at":"$(date -u -v+2d '+%Y-%m-%dT%H:%M:%S+00:00')","expired":false},
   "five_hour":{"remaining_pct":100}},
  {"label":"team@example.com","email":"team@example.com","alias":"team","active":false,
   "config_dir":"$TMP/pool/team",
   "data":"peer","quota_data":"peer","quota_source":"ballito",
   "quota_measured_at":"$(date -u -v-1d '+%Y-%m-%dT%H:%M:%SZ')",$1
   "seat":{"status":"cancelled","ends":"$UN_ENDS","ended":false},
   "weekly":{"remaining_pct":$2,"resets_at":"$(date -u -v-2H '+%Y-%m-%dT%H:%M:%S+00:00')","expired":true},
   "five_hour":{"remaining_pct":100}}
 ]}
J
STUB
  chmod +x "$LIB/rota-engine.sh"
}

# A row's field, straight out of --json, so the machine surface is pinned next to
# the table one instead of being inferred from it.
jrow() { python3 -c 'import json,sys;print([a[sys.argv[3]] for a in json.loads(sys.argv[1])["accounts"] if a["account"]==sys.argv[2]][0])' "$1" "$2" "$3"; }
# Is the reset this row publishes actually in the future? The whole point is that
# the one it USED to publish was not.
reset_is_future() { python3 -c '
import json,sys
from datetime import datetime
r=[a for a in json.loads(sys.argv[1])["accounts"] if a["account"]==sys.argv[2]][0]
n=r["next_weekly_reset"]
print(bool(n) and datetime.fromisoformat(n) > datetime.now().astimezone())' "$1" "$2"; }
# ⚠️ THE WEEKLY CELL ALONE, SLICED OUT BY COLUMN. Grepping the whole row for a
# percentage cannot tell the weekly figure from the 5H one two columns over, so
# "no number is invented here" would pass or fail on a number it is not about.
# The cell is the 21 bytes after "  " + the 36-wide SEAT column + one space.
weekly_cell() { python3 -c '
import sys
row=[l for l in sys.argv[1].splitlines() if l.startswith("  "+sys.argv[2])][0]
print(row[39:60].strip())' "$1" "$2"; }
# ⚠️ ALIGNMENT, PINNED IN BYTES. The table is column-aligned and the UNMEASURED
# cell is six characters wider than every other weekly cell; a cell that quietly
# pushes its row out of line is invisible to every grep for the words on it. So:
# AMOUNT's last byte on the header and the last byte of every seat row's amount
# must all land on the same column.
columns_line_up() { python3 -c '
import sys
L=sys.argv[1].splitlines()
h=[l for l in L if l.strip().startswith("SEAT")][0]
rows=[l for l in L if "@example.com" in l and "$" in l]
ends={h.index("AMOUNT")+len("AMOUNT")} | {l.index("$")+len(l[l.index("$"):].split()[0]) for l in rows}
print(len(rows) >= 2 and len(ends) == 1)' "$1"; }

export CLAUDE_BILLING_JSON="$UN_BILL"
write_unmeasured_stub '"unmeasured":true,' 'null' 20
OUT="$("$LIB/rota-billing.sh" 2>/dev/null)"
JOUT="$("$LIB/rota-billing.sh" --json 2>/dev/null)"

check "unmeasured: the weekly cell IS the marker, whole and nothing else" \
  '[ "$(weekly_cell "$OUT" team@example.com)" = "????????? UNMEASURED" ]'
check "unmeasured: a genuinely SPENT seat fills the same cell with a bar and 0%" \
  '[ "$(weekly_cell "$OUT" spent@example.com)" = "░░░░░░░░░   0%" ]'
check "unmeasured: NO percentage is invented for the unmeasured seat" \
  '! grep -qE "[0-9]" <<<"$(weekly_cell "$OUT" team@example.com)"'
check "unmeasured: GONE IN is no longer 'due' (the reset it named has already happened)" \
  '! grep "team@example.com" <<<"$OUT" | grep -qE " due +[A-Z]"'
check "unmeasured: QUOTA RESETS names a reset in the FUTURE" \
  '[ "$(reset_is_future "$JOUT" team@example.com)" = True ]'
check "unmeasured: the seat's LAST window is called out on the row it is about" \
  'grep "team@example.com" <<<"$OUT" | grep -q "LAST window"'
check "unmeasured: CANCELLED still composes on that same row" \
  'grep "team@example.com" <<<"$OUT" | grep -q "CANCELLED, ends"'
check "unmeasured: the provenance-and-age marker still composes on that same row" \
  'grep "team@example.com" <<<"$OUT" | grep -q "\[via ballito, 1d old\]"'
check "unmeasured: the command that would answer it is named under the table" \
  'grep -q "rota usage --record team <weekly-used-%>" <<<"$OUT"'
check "unmeasured: and the polarity is spelled out, because --record takes USED and the table shows LEFT" \
  'grep -q "USED %" <<<"$OUT"'
check "unmeasured: the hint is NOT stuffed into the row's NOTES column" \
  '! grep "team@example.com" <<<"$OUT" | grep -q "\-\-record"'
check "unmeasured: it is never what USE NEXT recommends" \
  '! grep -A1 "USE NEXT" <<<"$OUT" | grep -q "rota switch team"'
check "unmeasured: the row does not push any column out of line" \
  '[ "$(columns_line_up "$OUT")" = True ]'
check "unmeasured: json says so under the engine's own field name" \
  '[ "$(jrow "$JOUT" team@example.com unmeasured)" = True ]'
check "unmeasured: json still carries NO weekly percentage (unknown stays unknown)" \
  '[ "$(jrow "$JOUT" team@example.com weekly_left_pct)" = None ]'
check "unmeasured: json publishes last_window, so a script gets the same warning the row does" \
  '[ "$(jrow "$JOUT" team@example.com last_window)" = True ]'

# RESERVED has to survive all of it: whose seat it is and whether its quota was
# measured are different questions, and the row has to answer both at once.
mkdir -p "$TMP/pool/team"
printf 'owner=airmond-runner\nwhy=pushed to the runners\n' > "$TMP/pool/team/RESERVED"
OUT="$("$LIB/rota-billing.sh" 2>/dev/null)"
check "unmeasured: RESERVED composes with UNMEASURED on one row" \
  'grep "team@example.com" <<<"$OUT" | grep -q "RESERVED" && grep "team@example.com" <<<"$OUT" | grep -qF "UNMEASURED"'
check "unmeasured: RESERVED, CANCELLED and the provenance marker all still render together" \
  'grep "team@example.com" <<<"$OUT" | grep -q "airmond-runner" && grep "team@example.com" <<<"$OUT" | grep -q "CANCELLED" && grep "team@example.com" <<<"$OUT" | grep -q "\[via ballito"'
check "unmeasured: and none of it pushes the columns apart" \
  '[ "$(columns_line_up "$OUT")" = True ]'
check "unmeasured: a reserved seat with no number is not offered as a withheld option either" \
  '! grep -A1 "NOT OFFERED" <<<"$OUT" | grep -q "team ("'
rm -rf "$TMP/pool/team"

# ⚠️ AN UNMEASURED SEAT IS NOT AN "EARLIEST BACK". With nothing over the floor
# the table used to name the seat whose reset comes soonest, and pointing at an
# unmeasured seat's next reset tells you to wait for quota you may be holding
# right now: the same inversion the whole bucket exists to undo.
write_unmeasured_stub '"unmeasured":true,' 'null' 99
OUT="$("$LIB/rota-billing.sh" 2>/dev/null)"
check "unmeasured: with nothing over the floor, it is not named as 'earliest back'" \
  'grep -A1 "USE NEXT" <<<"$OUT" | grep -q "earliest back" && ! grep -A1 "USE NEXT" <<<"$OUT" | grep -q "earliest back is team"'
check "unmeasured: the block above still says what to do about it" \
  'grep -q "rota usage --record team" <<<"$OUT"'

# --- the recorded number flips the row back to a real figure -------------------
# `rota usage --record <seat> <weekly-used-%>` is the whole point of naming the
# command: once a number exists the engine stops calling the row unmeasured, and
# this table has to follow it back.
write_unmeasured_stub '"unmeasured":false,' '88' 20
OUT="$("$LIB/rota-billing.sh" 2>/dev/null)"
JOUT="$("$LIB/rota-billing.sh" --json 2>/dev/null)"
check "recorded: the row shows the real percentage again" \
  'grep "team@example.com" <<<"$OUT" | grep -q " 88%"'
check "recorded: and the UNMEASURED cell is gone" \
  '! grep "team@example.com" <<<"$OUT" | grep -qF "UNMEASURED"'
check "recorded: the block under the table goes with it" \
  '! grep -q "rota usage --record" <<<"$OUT"'
check "recorded: the seat is rankable again (88% beats the 55% seat, and it dies first)" \
  'grep -A1 "USE NEXT" <<<"$OUT" | grep -q "rota switch team"'
check "recorded: json carries the number, not a null" \
  '[ "$(jrow "$JOUT" team@example.com weekly_left_pct)" = 88 ]'

# ⚠️ THE NUMBER WINS WHENEVER THERE IS ONE. If the two halves ever disagree, a
# real measurement must not be hidden behind "may be full" - that is the only
# direction in which this can be wrong safely.
write_unmeasured_stub '"unmeasured":true,' '88' 20
OUT="$("$LIB/rota-billing.sh" 2>/dev/null)"
check "conflict: a row with a percentage leaves the bucket, whatever the flag says" \
  'grep "team@example.com" <<<"$OUT" | grep -q " 88%" && ! grep "team@example.com" <<<"$OUT" | grep -qF "UNMEASURED"'

# --- an OLDER engine, publishing no `unmeasured` field, must be untouched -------
# Degrade silently: the same stale row from a copy of rota-engine.sh that predates
# the field renders exactly what it rendered before any of this existed - a bare
# dash, `due`, and the stamp of the reset that has already gone by.
write_unmeasured_stub '' 'null' 20
OUT="$("$LIB/rota-billing.sh" 2>/dev/null)"
JOUT="$("$LIB/rota-billing.sh" --json 2>/dev/null)"
STALE_RESET="$(date -v-2H '+%a %d %b %H:')"
check "older engine: the weekly cell is a bare dash again, exactly as before" \
  '[ "$(weekly_cell "$OUT" team@example.com)" = "-" ] && ! grep -qF "UNMEASURED" <<<"$OUT"'
check "older engine: GONE IN is 'due' again for a reset that has passed" \
  'grep "team@example.com" <<<"$OUT" | grep -q " due "'
check "older engine: QUOTA RESETS still shows the stale stamp, unrolled" \
  'grep "team@example.com" <<<"$OUT" | grep -q "$STALE_RESET"'
check "older engine: no block appears under the table" \
  '! grep -q "rota usage --record" <<<"$OUT"'
check "older engine: json reports unmeasured false rather than omitting it" \
  '[ "$(jrow "$JOUT" team@example.com unmeasured)" = False ]'
check "older engine: columns still line up" \
  '[ "$(columns_line_up "$OUT")" = True ]'

# --- cancelled with no end date must not be a traceback ------------------------
# billing.json is hand-maintained; `status: cancelled` with no `ends` is a typo
# away at all times, and it used to reach datetime.fromisoformat(None). An
# operator never sees a stack trace under a half-drawn table.
#
# ⚠️ STRIPPED FROM BOTH SOURCES. billing.json is where the date belongs, but the
# engine republishes that same file as seat.ends and this table now falls back to
# it, so removing it from only one side would quietly exercise the fallback
# instead of the missing-date path. (That the first attempt at this test did
# exactly that is the reason the note is here.)
python3 -c 'import json,sys;p=sys.argv[1];d=json.load(open(p));d["accounts"]["team@example.com"].pop("ends");json.dump(d,open(p,"w"))' "$UN_BILL"
sed -i.bak 's/"ends":"[0-9][0-9-]*"/"ends":null/' "$LIB/rota-engine.sh"
OUT="$("$LIB/rota-billing.sh" 2>"$TMP/err")"; RC=$?
check "cancelled with no end date: exit 0, no traceback" \
  '[ "$RC" -eq 0 ] && ! grep -q "Traceback" "$TMP/err"'
check "cancelled with no end date: the row says so with a '?' instead" \
  'grep "team@example.com" <<<"$OUT" | grep -q "CANCELLED, ends ?"'
unset CLAUDE_BILLING_JSON

# --- A SEAT THAT HAS ALREADY ENDED IS NEVER A RECOMMENDATION -------------------
# ⚠️ THE FAILURE THIS PREVENTS, measured on ballito the evening of 2026-09-07.
# `rota billing` printed `USE NEXT rota switch thea` for a subscription that had
# ended on the 6th, one line under a row reading `CANCELLED, ends 6 Sep`: the
# table and the recommendation contradicting each other about the same seat. A
# session launched onto it does not get 60% of a week, it gets an auth failure.
#
# loses_at() is min(next reset, seat end), so a seat whose end date is in the PAST
# is keyed on a moment that has already gone by, and that sorts it FIRST - the
# most-about-to-be-lost seat in the pool. The key was never wrong; the dead seat
# had no business being in the ranked list.
#
# ⚠️ THE FIXTURE CARRIES A CANCELLED-BUT-LIVE SEAT ON PURPOSE (`soon`, ending
# before its next reset), and it is what USE NEXT must pick. Cancellation is NOT
# the exclusion - a cancelled seat's final window is the most use-it-or-lose-it
# quota there is - and a "fix" that widened this to `status == cancelled` would
# pass every other check below while quietly throwing that away.
ED_BILL="$TMP/billing-ended.json"
ED_PAST="$(date -v-1d '+%Y-%m-%d')"          # yesterday: this seat is over
ED_PAST_H="$(date -v-1d '+%-d %b')"
ED_SOON="$(date -v+2d '+%Y-%m-%d')"          # still alive, and dies before its reset
cat > "$ED_BILL" <<J
{"accounts":{
  "work@example.com":{"plan":"Max 20x","renews_day":12,"amount_display":"\$200.00","usd_approx":200,"status":"active"},
  "dead@example.com":{"plan":"Max 20x","renews_day":6,"amount_display":"\$200.00","usd_approx":200,"status":"cancelled","ends":"$ED_PAST"},
  "soon@example.com":{"plan":"Max 5x","renews_day":9,"amount_display":"\$100.00","usd_approx":100,"status":"cancelled","ends":"$ED_SOON"}
}}
J

write_ended_stub() {  # write_ended_stub <floor>
  cat > "$LIB/rota-engine.sh" <<STUB
#!/usr/bin/env bash
[ "\${1:-}" = "usage" ] && [ "\${2:-}" = "--json" ] || { echo "stub: unexpected args: \$*" >&2; exit 9; }
cat <<J
{"generated_at":"$(date -u '+%Y-%m-%dT%H:%M:%SZ')","activeEmail":"work@example.com",
 "floors":{"weekly_pct":$1},"peer":null,
 "accounts":[
  {"label":"work@example.com","email":"work@example.com","alias":"work","active":true,
   "data":"live","quota_data":"live","quota_source":null,
   "quota_measured_at":"$(date -u '+%Y-%m-%dT%H:%M:%SZ')","unmeasured":false,
   "seat":{"status":"active","ends":null,"ended":false},
   "weekly":{"remaining_pct":43,"resets_at":"$(date -u -v+5d '+%Y-%m-%dT%H:%M:%S+00:00')","expired":false},
   "five_hour":{"remaining_pct":88}},
  {"label":"dead@example.com","email":"dead@example.com","alias":"dead","active":false,
   "config_dir":"$TMP/pool/dead",
   "data":"cached","quota_data":"cached","quota_source":null,
   "quota_measured_at":"$(date -u -v-1d '+%Y-%m-%dT%H:%M:%SZ')","unmeasured":false,
   "seat":{"status":"cancelled","ends":"$ED_PAST","ended":true},
   "weekly":{"remaining_pct":60,"resets_at":"$(date -u -v+4d '+%Y-%m-%dT%H:%M:%S+00:00')","expired":false},
   "five_hour":{"remaining_pct":100}},
  {"label":"soon@example.com","email":"soon@example.com","alias":"soon","active":false,
   "data":"live","quota_data":"live","quota_source":null,
   "quota_measured_at":"$(date -u '+%Y-%m-%dT%H:%M:%SZ')","unmeasured":false,
   "seat":{"status":"cancelled","ends":"$ED_SOON","ended":false},
   "weekly":{"remaining_pct":30,"resets_at":"$(date -u -v+6d '+%Y-%m-%dT%H:%M:%S+00:00')","expired":false},
   "five_hour":{"remaining_pct":90}}
 ]}
J
STUB
  chmod +x "$LIB/rota-engine.sh"
}

export CLAUDE_BILLING_JSON="$ED_BILL"
write_ended_stub 20
OUT="$("$LIB/rota-billing.sh" 2>/dev/null)"
JOUT="$("$LIB/rota-billing.sh" --json 2>/dev/null)"

check "ended: USE NEXT does NOT name the seat that ended yesterday" \
  '! grep -A2 "USE NEXT" <<<"$OUT" | grep -q "rota switch dead"'
check "ended: and it is not smuggled into the 'then' tail either" \
  '! grep -A2 "USE NEXT" <<<"$OUT" | grep -q "dead ("'
check "ended: the cancelled-but-LIVE seat still wins, because its last window dies first" \
  'grep -A1 "USE NEXT" <<<"$OUT" | grep -q "rota switch soon"'
check "ended: and it is still called that seat's LAST window" \
  'grep -A2 "USE NEXT" <<<"$OUT" | grep -q "LAST window"'
check "ended: the withheld dead seat is named out loud, with the date the row shows" \
  "grep -A1 '^  ENDED' <<<\"\$OUT\" | grep -q 'dead (60% left, ended $ED_PAST_H)'"
check "ended: the block says the omission is permanent, not a flag away" \
  'grep -A2 "^  ENDED" <<<"$OUT" | grep -q "no flag that ranks it"'
check "ended: a cancelled seat that is still alive is NOT in that block" \
  '! grep -A1 "^  ENDED" <<<"$OUT" | grep -q "soon"'
check "ended: the row itself is unchanged - the table still shows its 60%" \
  'grep "dead@example.com" <<<"$OUT" | grep -q " 60%"'

# ⚠️ NOT EVEN WITH THE OVERRIDE. --include-reserved buys a reserved seat back
# into the ranking because that seat's quota is real and somebody could decide to
# spend it. A dead seat's is not real, so there is deliberately no twin flag, and
# the one that exists must not resurrect it as a side effect.
OUT2="$("$LIB/rota-billing.sh" --include-reserved 2>/dev/null)"
check "ended: --include-reserved does not bring a dead seat back either" \
  '! grep -A2 "USE NEXT" <<<"$OUT2" | grep -q "rota switch dead"'

# ⚠️ ONE SEAT, ONE REASON, AND THE TERMINAL ONE WINS. A seat that is both
# reserved and ended used to be listed under NOT OFFERED as "60% left → someone",
# which promises its owner quota that no longer exists.
mkdir -p "$TMP/pool/dead"
printf 'owner=airmond-runner\nwhy=pushed to the runners\n' > "$TMP/pool/dead/RESERVED"
OUT3="$("$LIB/rota-billing.sh" 2>/dev/null)"
check "ended: a reserved AND ended seat is reported as ENDED" \
  'grep -A1 "^  ENDED" <<<"$OUT3" | grep -q "dead ("'
check "ended: and not offered to its owner as quota that is still there" \
  '! grep -A1 "NOT OFFERED" <<<"$OUT3" | grep -q "dead ("'
rm -rf "$TMP/pool/dead"

# ⚠️ AN ENDED SEAT IS NOT AN "EARLIEST BACK": it is not coming back. next_reset()
# names a real instant on a real calendar for an account that will not exist to
# see it, and this line would send him to wait for it.
write_ended_stub 99
OUT="$("$LIB/rota-billing.sh" 2>/dev/null)"
check "ended: with nothing over the floor, the dead seat is not the 'earliest back'" \
  'grep -A1 "USE NEXT" <<<"$OUT" | grep -q "earliest back" && ! grep -A1 "USE NEXT" <<<"$OUT" | grep -q "earliest back is dead"'
check "ended: a live seat is named as the earliest back instead" \
  'grep -A1 "USE NEXT" <<<"$OUT" | grep -qE "earliest back is (work|soon)"'

# The machine surface has to carry the fact the ranking used, or a --json consumer
# re-deriving the pick inherits exactly the bug the table just stopped having -
# which is what happened to the RESERVED exclusion on 2026-08-25.
check "ended: json marks the dead seat under the engine's own field name" \
  '[ "$(jrow "$JOUT" dead@example.com seat_ended)" = True ]'
check "ended: json leaves a live seat alone" \
  '[ "$(jrow "$JOUT" soon@example.com seat_ended)" = False ]'
check "ended: json still publishes its weekly number, so nothing is hidden, only unranked" \
  '[ "$(jrow "$JOUT" dead@example.com weekly_left_pct)" = 60 ]'
unset CLAUDE_BILLING_JSON

# --- a SCOPED weekly cap spent is not a spent SEAT (2026-09-26) ---------------
# cedric.waldburger@ showed `WEEKLY LEFT 0%` with an EMPTY 5H column: its Fable cap
# was spent (the binding weekly), but weekly_all sat at 60% used and the seat still
# ran Opus. With a scoped binding and weekly_all known, the cell shows the all-model
# figure, NOTES names the Fable cap, and 5h is not blanked. `nosc` is the control:
# its ALL-MODEL weekly is spent, so 5h must still blank exactly as before. `plain`
# carries no kind and no weekly_all at all (the pre-limits shape).
SW_BILL="$TMP/scoped-billing.json"
cat > "$SW_BILL" <<'J'
{"accounts":{
  "fable@example.com":{"plan":"Max 20x","renews_day":7,"amount_display":"$200.00","usd_approx":200,"status":"active"},
  "nosc@example.com":{"plan":"Max 20x","renews_day":8,"amount_display":"$200.00","usd_approx":200,"status":"active"},
  "plain@example.com":{"plan":"Max 20x","renews_day":9,"amount_display":"$200.00","usd_approx":200,"status":"active"}
}}
J
cat > "$LIB/rota-engine.sh" <<'STUB'
#!/usr/bin/env bash
cat <<'J'
{"generated_at":"2026-09-26T10:00:00+02:00","activeEmail":"plain@example.com","floors":{"weekly_pct":20},
 "accounts":[
  {"label":"fable@example.com","email":"fable@example.com","alias":"fable","active":false,"data":"live",
   "weekly":{"remaining_pct":0,"used_pct":100,"resets_at":"2099-09-28T15:59:00+00:00","kind":"weekly_scoped","scope":"Fable"},
   "weekly_all":{"used_pct":60,"remaining_pct":40,"resets_at":"2099-10-01T09:00:00+00:00"},
   "five_hour":{"remaining_pct":84}},
  {"label":"nosc@example.com","email":"nosc@example.com","alias":"nosc","active":false,"data":"live",
   "weekly":{"remaining_pct":0,"used_pct":100,"resets_at":"2099-09-29T09:00:00+00:00","kind":"weekly_all","scope":null},
   "weekly_all":{"used_pct":100,"remaining_pct":0,"resets_at":"2099-09-29T09:00:00+00:00"},
   "five_hour":{"remaining_pct":97}},
  {"label":"plain@example.com","email":"plain@example.com","alias":"plain","active":true,"data":"live",
   "weekly":{"remaining_pct":70,"resets_at":"2099-09-30T09:00:00+00:00"},
   "five_hour":{"remaining_pct":91}}
 ]}
J
STUB
chmod +x "$LIB/rota-engine.sh"
export CLAUDE_BILLING_JSON="$SW_BILL"
OUT="$("$LIB/rota-billing.sh" 2>/dev/null)"
JOUT="$("$LIB/rota-billing.sh" --json 2>/dev/null)"
check "scoped weekly: the cell shows the ALL-MODEL 40%, not the Fable cap's 0%" \
  'grep "fable@example.com" <<<"$OUT" | grep -qE " 40% " && ! grep "fable@example.com" <<<"$OUT" | grep -qE "   0% "'
check "scoped weekly: the 5h column is NOT blanked by a spent scoped cap" \
  'grep "fable@example.com" <<<"$OUT" | grep -q " 84% "'
check "scoped weekly: NOTES names the spent Fable cap and when it is back" \
  'grep "fable@example.com" <<<"$OUT" | grep -qE "Fable spent · back [A-Z][a-z]{2} [0-9]{2} [A-Z][a-z]{2}"'
check "all-model spent: behaviour unchanged, 0% and 5h still blanked" \
  'grep "nosc@example.com" <<<"$OUT" | grep -q "   0% " && ! grep "nosc@example.com" <<<"$OUT" | grep -q "97%"'
check "all-model spent: no scoped note on an unscoped binding" \
  '! grep "nosc@example.com" <<<"$OUT" | grep -qE "spent · back|% left"'
check "no weekly_all: the row renders exactly as before" \
  'grep "plain@example.com" <<<"$OUT" | grep -q " 70% " && grep "plain@example.com" <<<"$OUT" | grep -q " 91% "'
check "scoped weekly (json): weekly_left_pct stays the BINDING 0 the ranking reads" \
  '[ "$(jrow "$JOUT" fable@example.com weekly_left_pct)" = 0 ]'
check "scoped weekly (json): weekly_kind / weekly_scope are published" \
  '[ "$(jrow "$JOUT" fable@example.com weekly_kind)/$(jrow "$JOUT" fable@example.com weekly_scope)" = weekly_scoped/Fable ]'
check "scoped weekly (json): weekly_all is passed through" \
  '[ "$(python3 -c "import json,sys;print([a[\"weekly_all\"][\"remaining_pct\"] for a in json.loads(sys.argv[1])[\"accounts\"] if a[\"account\"]==\"fable@example.com\"][0])" "$JOUT")" = 40 ]'
check "no weekly_all (json): null, never invented" \
  '[ "$(jrow "$JOUT" plain@example.com weekly_all)" = None ]'
check "scoped weekly: the recommendation still ranks on the binding cap (fable is not USE NEXT)" \
  '! grep -A1 "USE NEXT" <<<"$OUT" | grep -q "rota switch fable"'
unset CLAUDE_BILLING_JSON
cp "$TMP/engine.good" "$LIB/rota-engine.sh"; chmod +x "$LIB/rota-engine.sh"

printf 'billing.test.sh: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
