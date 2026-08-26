#!/usr/bin/env bash
# rota-billing.sh: ONE table: how much each seat has left, when its quota
# resets, when it next CHARGES, and what it costs.
#
# Why this exists. `rota usage` measures quota live and is the authority on it.
# Nothing measures billing: no API exposes a renewal date, and receipt emails do
# not name the seat in their body (some seats send no receipt to any shared
# mailbox at all). Establishing five renewal dates by hand once cost the better
# part of a morning. So the billing half lives in $CFG_DIR/billing.json (never in
# the repo), and this merges it with the live quota numbers.
#
# Usage:
#   rota billing               the table (routes to the pool host, see below)
#   rota billing --json        machine-readable merge, for scripts
#   rota billing --local       read THIS box's pool, whatever box it is
#   rota billing --no-refresh  pass through to `rota usage` (use cached quota)
#   rota billing --include-reserved  rank reserved seats too (see below)
#
# WHOSE SEAT IS IT. A pool can hold seats that are not yours to spend - one
# pushed to a server that runs against it around the clock, one handed to a
# colleague. Quota cannot tell you that, so those seats are marked RESERVED and
# held out of the ranking. A seat is reserved if it carries a RESERVED file in
# its own config dir (the same file the shim reads when it refuses to open a
# session there) or is named in $CFG_DIR/reserved as `alias [owner] [why...]`.
#
# The quota columns are LIVE and re-measured on every run. The billing columns
# are only as true as billing.json; config/billing.example.json documents the
# schema and how to re-measure each field.
#
# WHY IT ROUTES. If you run more than one machine, the pool that matters usually
# lives on the always-on box; a laptop's ~/.claude-pool is often a near-empty
# stub. Measured once: the laptop held credentials for ONE of five seats, so
# running this there answered "one usable seat", confidently, and wrong. A quota
# table that silently describes the wrong machine is worse than no table, so
# when ROTA_POOL_HOST is set and names another box, this ssh's to it and says
# so. Unset (the default) means: this box IS the pool host, read locally.

set -euo pipefail
ROTA_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG_DIR="${CLAUDE_FAILOVER_HOME:-$HOME/.config/claude-failover}"
BILLING_JSON="${CLAUDE_BILLING_JSON:-$CFG_DIR/billing.json}"
POOL_HOST="${ROTA_POOL_HOST:-${CLAUDE_POOL_HOST:-}}"

WANT_JSON=0
FORCE_LOCAL=0
INCLUDE_RESERVED=0
PASSTHRU=()
for a in "$@"; do
  case "$a" in
    --json)  WANT_JSON=1; PASSTHRU+=("$a") ;;
    --local) FORCE_LOCAL=1 ;;
    --include-reserved) INCLUDE_RESERVED=1 ;;
    -h|--help) sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) PASSTHRU+=("$a") ;;
  esac
done

# ── route to the pool host ───────────────────────────────────────────────────
# The remote copy is invoked with --local, so this can never recurse. An empty
# POOL_HOST means "here", which skips this block entirely.
THIS_HOST="$(scutil --get LocalHostName 2>/dev/null || hostname -s 2>/dev/null || echo unknown)"
if [ "$FORCE_LOCAL" -eq 0 ] && [ -n "$POOL_HOST" ] && [ "$THIS_HOST" != "$POOL_HOST" ]; then
  if ssh -o ConnectTimeout=8 -o BatchMode=yes "$POOL_HOST" 'command -v rota >/dev/null 2>&1 || test -x "$HOME/.local/bin/rota"' 2>/dev/null; then
    # Note goes to stderr so `--json | jq` stays clean.
    [ "$WANT_JSON" -eq 1 ] || printf '\n  \033[2mpool host: %s (read over ssh from %s)\033[0m\n' "$POOL_HOST" "$THIS_HOST" >&2
    # A non-interactive ssh shell rarely has ~/.local/bin on PATH, so put it there ourselves.
    # ⚠️ NOT ${INCLUDE_RESERVED:+...}: the variable holds 0 or 1 and "0" is
    # non-empty, so :+ would forward the flag when it is switched OFF.
    RES_FLAG=""; [ "$INCLUDE_RESERVED" -eq 1 ] && RES_FLAG=" --include-reserved"
    exec ssh -o ConnectTimeout=8 "$POOL_HOST" "PATH=\$HOME/.local/bin:\$PATH rota billing --local$RES_FLAG ${PASSTHRU[*]:-}"
  fi
  # Fall through rather than fail: this box's table is still worth something, but
  # it must never be mistaken for the pool host's.
  printf '\n  \033[33m! %s unreachable (or has no rota on PATH): showing %s'"'"'s OWN pool, which is probably incomplete.\033[0m\n' \
    "$POOL_HOST" "$THIS_HOST" >&2
fi

if [ ! -f "$BILLING_JSON" ]; then
  cat >&2 <<MSG
rota billing: no billing file at $BILLING_JSON

  Create it from the example and fill in your own seats:
    mkdir -p "$(dirname "$BILLING_JSON")"
    cp "$(cd "$ROTA_LIB/.." && pwd)/config/billing.example.json" "$BILLING_JSON"
    \$EDITOR "$BILLING_JSON"
MSG
  exit 2
fi

# rota-engine.sh is the one thing that measures quota. Never re-implement it.
USAGE_RAW="$("$ROTA_LIB/rota-engine.sh" usage --json ${PASSTHRU+"${PASSTHRU[@]}"} 2>/dev/null || true)"
[ -n "$USAGE_RAW" ] || { echo "rota billing: 'rota-engine.sh usage --json' returned nothing" >&2; exit 1; }

BILLING_JSON="$BILLING_JSON" WANT_JSON="$WANT_JSON" THIS_HOST="$THIS_HOST" \
CFG_DIR="$CFG_DIR" INCLUDE_RESERVED="$INCLUDE_RESERVED" python3 - "$USAGE_RAW" <<'PY'
import json, os, sys
from datetime import datetime, date

raw = sys.argv[1]
usage = json.loads(raw[raw.index('{'):])
billing = json.load(open(os.environ['BILLING_JSON']))
bill = billing.get('accounts', {})

# ── WHOSE SEAT IS IT ────────────────────────────────────────────────────────
# A pool can hold seats that are NOT yours to spend: one pushed to a server that
# runs against it around the clock, one handed to a colleague. Quota alone
# cannot tell you that, so a table that ranks purely on quota will confidently
# send you to somebody else's seat. It did: on 2026-08-25 this printed
# `USE NEXT rota switch tommy` for a seat handed over the day before.
#
# Two sources, UNIONED - never "markers else config":
#   1. a RESERVED file inside the seat's own config dir, which is also what the
#      shim reads when it refuses to open a session there, so the table and the
#      thing that actually refuses cannot drift apart
#   2. $CFG_DIR/reserved, one `alias [owner] [why...]` per line
# The union matters: the first box to grow a marker file would otherwise
# silently un-reserve every seat named only in the config.
def read_reservations(cfg_dir):
    out = {}
    path = os.path.join(cfg_dir, 'reserved')
    try:
        with open(path) as fh:
            for line in fh:
                line = line.split('#', 1)[0].strip()
                if not line: continue
                parts = line.split(None, 2)
                out[parts[0]] = {'owner': parts[1] if len(parts) > 1 else '',
                                 'why':   parts[2] if len(parts) > 2 else ''}
    except OSError:
        pass
    return out

def read_marker(config_dir):
    if not config_dir: return None
    try:
        with open(os.path.join(os.path.expanduser(config_dir), 'RESERVED')) as fh:
            kv = {}
            for line in fh:
                if '=' in line:
                    k, v = line.split('=', 1)
                    kv[k.strip()] = v.strip()
            return {'owner': kv.get('owner', ''), 'why': kv.get('why', '')}
    except OSError:
        return None

RESERVED_CFG = read_reservations(os.environ.get('CFG_DIR', ''))
INCLUDE_RESERVED = os.environ.get('INCLUDE_RESERVED') == '1'

def next_charge(day, ends):
    """Renewal is a day-of-month. Next charge is that day, in the next month it still bills."""
    today = date.today()
    y, m = today.year, today.month
    if today.day >= day:
        m += 1
        if m > 12: m, y = 1, y + 1
    try: nxt = date(y, m, day)
    except ValueError: return None
    if ends:
        end = date.fromisoformat(ends)
        if nxt >= end: return None       # cancelled before this charge lands
    return nxt

def fmt(ts):
    if not ts: return '-'
    return datetime.fromisoformat(ts.replace('Z', '+00:00')).astimezone().strftime('%a %d %b %H:%M')

rows, total = [], 0.0
for a in usage.get('accounts', []):
    email = a.get('email') or a.get('label')
    # A duplicate row (two dirs, one identity) carries no numbers: skip it, the real row is elsewhere.
    if a.get('data') == 'dup':
        continue
    b = bill.get(email, {})
    w = a.get('weekly') or {}
    f = a.get('five_hour') or {}
    ends = b.get('ends')
    nxt = next_charge(b['renews_day'], ends) if b.get('renews_day') else None
    if nxt: total += float(b.get('usd_approx') or 0)
    status = b.get('status', 'unknown')
    alias = a.get('alias')
    # Marker first so a seat carrying one is reserved even with no config line;
    # the config fills in seats that have no marker on this particular box.
    res = read_marker(a.get('config_dir')) or RESERVED_CFG.get(alias)
    rows.append({
        'reserved': bool(res),
        'reserved_owner': (res or {}).get('owner', ''),
        'reserved_why': (res or {}).get('why', ''),
        'account': email,
        'alias': alias,
        'active_now': bool(a.get('active')),
        'weekly_left_pct': w.get('remaining_pct'),
        'weekly_resets_at': w.get('resets_at'),
        'five_hour_left_pct': f.get('remaining_pct'),
        'quota_data': a.get('data'),
        'plan': b.get('plan', '?'),
        'renews_day': b.get('renews_day'),
        'next_charge': nxt.isoformat() if nxt else None,
        'amount': b.get('amount_display', '?'),
        'status': status,
        'ends': ends,
    })

# An empty result must NEVER render as a tidy table reading $0.00: that is the
# same confidently-wrong failure this script exists to prevent. Seen for real:
# routing to a host whose copy predated --local made it a passthrough flag, the
# usage call returned no accounts, and the table printed clean and empty.
if not rows:
    sys.stderr.write(
        "rota billing: the usage call returned NO accounts, so there is nothing to show.\n"
        "  Most likely the pool host's copy of rota is older than this one\n"
        "  (it would not understand --local). Update rota there, or\n"
        "  re-run with --local to read this box's own pool.\n")
    sys.exit(1)

# Soonest real charge first; seats with no upcoming charge sink to the bottom.
rows.sort(key=lambda r: (r['next_charge'] is None, r['next_charge'] or '', r['account']))

if os.environ.get('WANT_JSON') == '1':
    print(json.dumps({'generated_at': usage.get('generated_at'),
                      'active': usage.get('activeEmail'),
                      'monthly_total_usd_approx': round(total, 2),
                      'accounts': rows}, indent=2))
    sys.exit(0)

C = sys.stdout.isatty()
def c(s, code): return f"\033[{code}m{s}\033[0m" if C else s

# Pad on VISIBLE width. An f-string width counts ANSI escapes as characters, so
# colouring a cell before padding it silently shreds every column to its right.
def pad(plain, width, code=None, right=False):
    cell = c(plain, code) if code else plain
    fill = ' ' * max(0, width - len(plain))
    return (fill + cell) if right else (cell + fill)

host = os.environ.get('THIS_HOST') or '?'

# ── HOW LONG UNTIL THIS QUOTA IS GONE ───────────────────────────────────────
# An absolute reset time makes you do date arithmetic in your head to answer the
# only question that matters ("can I still spend this before I leave?"). The
# countdown answers it directly; the absolute time stays because a countdown
# alone cannot be checked against a calendar.
def countdown(ts):
    if not ts: return '-'
    delta = datetime.fromisoformat(ts.replace('Z', '+00:00')) - datetime.now().astimezone()
    secs = int(delta.total_seconds())
    if secs <= 0: return 'due'
    d, rem = divmod(secs, 86400)
    h, m = divmod(rem // 60, 60)
    return f"{d}d {h:02d}h" if d else f"{h}h {m:02d}m"

# A bar makes the column scannable: five seats sorted by charge date are five
# numbers you have to read, but one glance at the bars finds the empty ones.
def bar(pct, width=9):
    if pct is None: return ' ' * width
    filled = int(round(pct / 100 * width))
    return '\u2588' * filled + '\u2591' * (width - filled)

print(f"\nSeats on {c(host, '1')} \u00b7 {fmt(usage.get('generated_at'))} \u00b7 active: {c(usage.get('activeEmail') or '?', '36')}\n")
hdr = (f"  {'SEAT':36} {'WEEKLY LEFT':>21}  {'5H':>4}  {'GONE IN':>8}  "
       f"{'QUOTA RESETS':17} {'NEXT CHARGE':>12} {'AMOUNT':>11}  NOTES")
print(c(hdr, '2;4'))

# Reserved seats sink to the bottom: they are context, not options. Within each
# group the original soonest-charge-first order is kept.
#
# ⚠️ The original position is captured BEFORE sorting, not looked up with
# rows.index(r) inside the key. index() compares dicts by value and scans a list
# that sort() is actively reordering, so it raises ValueError halfway down a
# table that has already printed its header - a half-rendered table with a
# traceback under it.
for _i, _r in enumerate(rows):
    _r['_ord'] = _i
rows.sort(key=lambda r: (bool(r['reserved']), r['_ord']))

for r in rows:
    wk = r['weekly_left_pct']
    wk_plain = f"{bar(wk)} {wk:>3}%" if wk is not None else f"{bar(None)}    -"
    if   wk is None: wk_code = '90'
    elif wk == 0:    wk_code = '31'    # spent
    elif wk < 20:    wk_code = '33'    # under the >=20%-left health floor
    else:            wk_code = '32'
    # A spent weekly makes the 5h window meaningless: it reads ~100% precisely
    # because nothing can run against it. Printing that invites reading a dead
    # seat as available, so blank it rather than show a number that means nothing.
    fh = r['five_hour_left_pct']
    fh_plain = '' if wk == 0 else (f"{fh}%" if fh is not None else '-')

    notes = []
    # ⚠️ THE RESERVATION LEADS. It is the one fact that changes whether a row is
    # an option at all, so it must not sit behind the billing status where a
    # reader scanning for green numbers will never reach it.
    if r['reserved']:
        who = r['reserved_owner'] or 'someone else'
        notes.append(c(f"RESERVED \u2192 {who}", '1;35'))
    if r['status'] == 'cancelled':
        notes.append(c(f"CANCELLED, ends {datetime.fromisoformat(r['ends']).strftime('%-d %b')}", '31'))
    elif r['status'] == 'unknown':
        notes.append(c('billing unknown, add it to billing.json', '33'))
    if r['quota_data'] not in ('live', None):
        notes.append(c(f"[quota {r['quota_data']}]", '33'))

    nc_plain = datetime.fromisoformat(r['next_charge']).strftime('%-d %b %Y') if r['next_charge'] else 'none'
    nc = pad(nc_plain, 12, None if r['next_charge'] else '90', right=True)
    name = pad(r['account'] + (' <' if r['active_now'] else ''), 36,
               '36' if r['active_now'] else ('90' if r['reserved'] else None))

    print(f"  {name} {pad(wk_plain, 21, wk_code, right=True)}  {fh_plain:>4}  "
          f"{countdown(r['weekly_resets_at']):>8}  "
          f"{fmt(r['weekly_resets_at']):17} {nc} {r['amount']:>11}  {'  '.join(notes)}")

# ── USE NEXT ────────────────────────────────────────────────────────────────
# THE LIMIT IS WEEKLY AND USE-IT-OR-LOSE-IT, so rank by when THIS window is
# lost. Unused quota never rolls over: whatever is left on a seat at its weekly
# reset is gone, so the seat to spend now is the one resetting soonest.
#
# Cancellation is NOT the sort key, and an earlier version of this got it
# wrong. Cancelling a seat does not change how much of it you can use this week
# (that quota dies at the weekly reset either way), so the end date says
# nothing about which seat to pick today. It only says how many FUTURE weeks
# exist. Sorting cancelled-first looks right whenever the two orders happen to
# agree and is silently wrong when they diverge: with seat A resetting Thursday
# and a cancelled seat B resetting Saturday, it would send you to seat B and
# waste seat A's entire week.
#
# The end date matters in exactly one place: a seat's FINAL partial week, where
# the account dies before its next reset. So the key is the effective loss time,
# min(weekly reset, account end), which is the weekly reset almost always.
FAR = '9999-12-31T00:00'
floor = (usage.get('floors') or {}).get('weekly_pct', 20)

def loses_at(r):
    """When this seat's CURRENT quota window goes away."""
    reset = r['weekly_resets_at'] or FAR
    end = (r['ends'] + 'T00:00') if r['ends'] else FAR
    # Compare as UTC-naive ISO; resets carry an offset, ends do not.
    return min(reset[:16], end[:16])

# ⚠️ A RESERVED SEAT IS NEVER A RECOMMENDATION. Quota is not the only fact that
# decides whether a seat is available, and this ranking used to behave as if it
# were: on 2026-08-25 it printed `rota switch tommy` for a seat handed to a
# colleague the previous day, and `--json` consumers inherited the same mistake.
# --include-reserved exists for the deliberate override, and says so out loud.
usable = [r for r in rows if (r['weekly_left_pct'] or 0) >= floor
          and (INCLUDE_RESERVED or not r['reserved'])]
usable.sort(key=lambda r: (loses_at(r), -(r['weekly_left_pct'] or 0)))

# Say what was withheld and why. A seat that silently vanishes from the ranking
# is indistinguishable from one that is simply spent, which is how a reservation
# gets quietly forgotten and then quietly violated.
held = [r for r in rows if r['reserved'] and (r['weekly_left_pct'] or 0) >= floor
        and not INCLUDE_RESERVED]

print(f"\n  {c('monthly total (approx, seats that still charge):', '2')} ${total:,.2f}")

if usable:
    p = usable[0]
    cmd = f"rota switch {p['alias']}" if p.get('alias') else f"# no alias for {p['account']}"
    dies_before_reset = bool(p['ends']) and (p['ends'] + 'T00:00')[:16] <= (p['weekly_resets_at'] or FAR)[:16]
    if dies_before_reset:
        why = (f"the seat ends {datetime.fromisoformat(p['ends']).strftime('%-d %b')}, before its next "
               f"reset: this is its LAST window")
    else:
        why = f"its weekly window resets first ({fmt(p['weekly_resets_at'])}), so this is the quota closest to being lost"
    print(f"\n  {c('USE NEXT', '1;32')}   {c(cmd, '1')}")
    print(f"     {p['account']} · {p['weekly_left_pct']}% weekly left · {why}")
    if p['active_now']:
        print(f"     {c('(you are already on it)', '2')}")
    rest = usable[1:]
    if rest:
        tail = '  ·  '.join(
            f"{r['alias'] or r['account']} ({r['weekly_left_pct']}%, resets "
            f"{datetime.fromisoformat(r['weekly_resets_at']).astimezone().strftime('%a %-d %b') if r['weekly_resets_at'] else '?'})"
            for r in rest)
        print(f"     {c('then', '2')} {c(tail, '2')}")
else:
    soonest = min((r for r in rows if r['weekly_resets_at']), key=lambda r: r['weekly_resets_at'], default=None)
    msg = f"nothing clears the {floor}%-weekly floor"
    if soonest:
        msg += f"; earliest back is {soonest['alias'] or soonest['account']} at {fmt(soonest['weekly_resets_at'])}"
    print(f"\n  {c('USE NEXT', '1;31')}   {c(msg, '33')}")

if held:
    # ⚠️ NOT account.split('@')[0]. Two seats can share a local-part - a personal
    # and a work address for the same person - and then the line names the wrong
    # one, or names one seat twice. The alias is what `rota switch` takes and is
    # unique by construction.
    detail = '  ·  '.join(
        f"{r['alias'] or r['account']} ({r['weekly_left_pct']}% left → {r['reserved_owner'] or 'someone else'})"
        for r in held)
    print(f"\n  {c('NOT OFFERED', '1;35')}   {c(detail, '2')}")
    # ⚠️ Do NOT name a verb here. This renderer is reached as `rota accounts`
    # AND as `rota billing` (and as `cdt accounts`), so any verb spelled out is
    # wrong for most of the ways a reader got here - it would send them to a
    # command they did not type.
    print(f"     {c('reserved seats are excluded from the ranking; pass --include-reserved to rank them too', '2')}")

missing = [r['account'] for r in rows if r['status'] == 'unknown']
if missing:
    print(c(f"  billing unknown for: {', '.join(missing)}; add to {os.environ['BILLING_JSON']}", '33'))
print(f"\n  {c('quota is measured live; billing comes from billing.json; reservations from each seat'+chr(39)+'s RESERVED marker + $CFG_DIR/reserved', '2')}\n")
PY
