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
# UNMEASURED IS NOT SPENT. A seat whose only number describes a weekly window
# that has since rolled (or whose usage probe the API keeps refusing, 429) has no
# percentage at all, so it renders `????????? UNMEASURED` rather than a figure,
# its GONE IN counts to the NEXT reset, and a line under the table gives the one
# command that answers it. Nothing guesses a number for it and nothing ranks it.
#
# The quota columns are re-measured every run; any number that is NOT a live
# local measurement says so in NOTES ([cached, 2d old], [via ballito]). Billing
# is only as true as billing.json; config/billing.example.json documents it.
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
    -h|--help) sed -n '2,34p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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
from datetime import datetime, date, timedelta, timezone

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
        # try/except for the same reason as parse_ts and age_short: billing.json is
        # hand-maintained, `ends` is now also accepted from the engine's seat block,
        # and a date this cannot read must cost a charge estimate, never a traceback
        # under a half-drawn table.
        try: end = date.fromisoformat(str(ends))
        except Exception: return nxt
        if nxt >= end: return None       # cancelled before this charge lands
    return nxt

# ── EVERY STAMP THROUGH ONE PARSER ───────────────────────────────────────────
# Three columns and the whole ranking do arithmetic on these stamps, and they
# arrive in two shapes: an offset-carrying instant from the engine
# (2026-08-27T19:00:00+02:00) and a bare date from billing.json (2026-09-01).
# Subtracting a naive datetime from an aware one raises TypeError, so a bare
# `ends` reaching the countdown would put a traceback under a half-drawn table,
# the one failure mode this whole file is written to avoid (see age_short).
# A bare date is read as LOCAL midnight, the conservative end of the seat's last
# day, which is the same choice rota-engine.sh's seat_deadline makes.
def parse_ts(ts):
    """An aware datetime, or None. NEVER raises: a stamp we cannot read is a stamp we do not print."""
    if not ts: return None
    if isinstance(ts, datetime): return ts if ts.tzinfo else ts.astimezone()
    try:
        dt = datetime.fromisoformat(str(ts).replace('Z', '+00:00'))
    except Exception:
        return None
    return dt if dt.tzinfo else dt.astimezone()

def fmt(ts):
    dt = parse_ts(ts)
    return dt.astimezone().strftime('%a %d %b %H:%M') if dt else '-'

def fmt_date(d):
    """'1 Sep'. A '?' rather than a traceback when billing.json says cancelled and names no end date."""
    dt = parse_ts(d)
    return dt.strftime('%-d %b') if dt else '?'

WEEK = timedelta(days=7)
FAR = datetime(9999, 12, 31, tzinfo=timezone.utc)   # "no deadline at all", sorts last

# ── UNKNOWN IS NOT SPENT ─────────────────────────────────────────────────────
# `unmeasured` is the one fact on a row that billing cannot derive for itself:
# it means "the number I hold describes a window that has since rolled, or the
# usage API refused to answer (429)", and only rota-engine.sh sees the second
# half. Cost of not having it, 2026-08-21: two cancelled-but-live seats read as
# finished while each still carried roughly two more full weekly refreshes of
# already-paid-for quota, and every reader believed the row.
#
# ⚠️ THE NUMBER WINS WHENEVER THERE IS ONE. The two halves can only disagree
# after `rota usage --record`, where the recorded figure IS a measurement, so a
# row with a percentage leaves this bucket. Never the other way round: "may be
# full" must never turn into a figure that anything can rank on.
#
# Absent (an older engine publishes no such field) this is False for every row,
# and everything below then renders exactly as it did before this existed.
def is_unmeasured(r):
    return bool(r.get('unmeasured')) and r.get('weekly_left_pct') is None

# ── THE RESET THIS SEAT WILL ACTUALLY SEE NEXT ───────────────────────────────
# An unmeasured row is holding a stamp for a window that has already rolled;
# that is precisely what makes it unmeasured. Printing that stamp is how tartare
# read `GONE IN: due · QUOTA RESETS: Thu 27 Aug 19:00` on the evening of the
# 27th: a deadline two hours in the past, on a seat whose allowance had just
# refilled. The weekly window is seven days (the same length `rota usage
# --record` assumes when it stamps a hand-read number), so roll the stale
# instant forward until it lands in the future.
#
# ⚠️ Multiplication, not a loop: a stamp from a mis-set clock or a long-dead
# cache costs one subtraction, never one iteration per week since.
def next_reset(r):
    dt = parse_ts(r.get('weekly_resets_at'))
    if dt is None or not is_unmeasured(r): return dt
    now = datetime.now().astimezone()
    if dt > now: return dt
    return dt + WEEK * (int((now - dt).total_seconds() // WEEK.total_seconds()) + 1)

def ends_at(r):
    return parse_ts(r['ends']) if r.get('ends') else None

# ⚠️ ONE deadline function, used by the GONE IN column AND by the ranking at the
# bottom of this file. They used to be able to disagree: the column counted down
# to the weekly reset while the ranking sorted on min(reset, seat end), so a
# cancelled seat's row and its position told two different stories about the
# same date. This is billing's half of rota-engine.sh's seat_deadline.
def loses_at(r):
    """When this seat's CURRENT quota window goes away: min(next reset, seat end)."""
    when = [x for x in (next_reset(r), ends_at(r)) if x is not None]
    return min(when) if when else FAR

# The single most decision-relevant fact on a cancelled row, and the one the
# table Cédric actually reads was missing: the seat dies before its quota
# refills, so this window is the last one it will ever have.
def last_window(r):
    if r.get('seat_ended'): return False      # already over; there is no window to be the last of
    e, n = ends_at(r), next_reset(r)
    return bool(e) and (n is None or e <= n)

rows, total = [], 0.0
for a in usage.get('accounts', []):
    email = a.get('email') or a.get('label')
    # A duplicate row (two dirs, one identity) carries no numbers: skip it, the real row is elsewhere.
    if a.get('data') == 'dup':
        continue
    b = bill.get(email, {})
    w = a.get('weekly') or {}
    f = a.get('five_hour') or {}
    # ── THE SEAT'S LIFECYCLE ────────────────────────────────────────────────
    # The engine has published seat.{status,ends,ended} since 2026-08-25 and
    # billing ignored all three. Today they are this very billing.json read back
    # (rota-engine.sh's load_seats parses this file), so they can only agree;
    # taking `ends` from there when billing.json is silent costs one `or` and
    # means an engine that ever learns a seat's end from somewhere else flows
    # straight through. `ended` is the only one that is genuinely computed, and
    # it is the single state that means the account is really finished.
    #
    # ⚠️ `status` is deliberately NOT taken from there. The engine defaults
    # seat.status to "active" for a seat billing.json has never heard of, so
    # falling back to it would silently retire the "billing unknown, add it to
    # billing.json" warning that is the only thing saying the file is incomplete.
    seat = a.get('seat') or {}
    ends = b.get('ends') or seat.get('ends')
    seat_ended = seat.get('ended')
    if seat_ended is None:
        seat_ended = bool(ends) and str(ends) < date.today().isoformat()
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
        'five_hour_resets_at': f.get('resets_at'),
        # ── WHERE DID THIS NUMBER COME FROM, AND WHEN ────────────────────────
        # quota_data is live | cached | peer | none. quota_source names the peer
        # box when the engine had to read the seat's numbers over ssh (this box
        # holds no credential for it, and copying one here is the option that is
        # permanently rejected: an OAuth refresh token is single-use). Passed
        # through under the SAME names the engine publishes, because this JSON is
        # itself what a peer reads: an asymmetric vocabulary would mean the peer
        # parser had to know which of two shapes answered it.
        'quota_data': a.get('data'),
        'quota_source': a.get('quota_source'),
        # 2026-08-27: the table used to render a 2.5-day-old cached number behind
        # a bare `[quota cached]`, which reads exactly like a current one. This is
        # the field that stops that, and it is the MEASUREMENT instant, never the
        # generated_at of the report carrying it.
        'quota_measured_at': a.get('quota_measured_at'),
        # ── QUOTA UNKNOWN vs QUOTA SPENT ─────────────────────────────────────
        # Passed through under the engine's own name, like the provenance fields
        # above, because this JSON is itself what a peer reads. `unmeasured` is
        # the state rota-engine.sh's table calls UNMEASURED; `seat_ended` is the
        # only field that means the account is actually done.
        'unmeasured': bool(a.get('unmeasured')),
        'seat_ended': bool(seat_ended),
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

# The two derived dates, computed ONCE and published, so a script reading
# --json gets the same answer as the table instead of re-deriving the seven-day
# roll-forward (and getting it subtly different). Both are null-safe: a row with
# no reset and no end date carries null and false.
for r in rows:
    _nr = next_reset(r)
    r['next_weekly_reset'] = _nr.isoformat() if _nr else None
    r['last_window'] = last_window(r)

# Soonest real charge first; seats with no upcoming charge sink to the bottom.
rows.sort(key=lambda r: (r['next_charge'] is None, r['next_charge'] or '', r['account']))

if os.environ.get('WANT_JSON') == '1':
    print(json.dumps({'generated_at': usage.get('generated_at'),
                      'active': usage.get('activeEmail'),
                      # null unless a peer actually contributed a row, so a
                      # consumer can tell "no peer configured" from "peer used"
                      # without scanning every account for a quota_source.
                      'peer': usage.get('peer'),
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
    dt = parse_ts(ts)
    if dt is None or dt is FAR: return '-'
    secs = int((dt - datetime.now().astimezone()).total_seconds())
    if secs <= 0: return 'due'
    d, rem = divmod(secs, 86400)
    h, m = divmod(rem // 60, 60)
    return f"{d}d {h:02d}h" if d else f"{h}h {m:02d}m"

# ── HOW OLD IS THIS NUMBER ──────────────────────────────────────────────────
# countdown()'s twin, pointing backwards, and deliberately COARSER: one unit,
# "4m" / "3h" / "2d". It rides inside a NOTES cell next to the number it
# qualifies, where anything longer stops being glanceable.
#
# Measured on the pool 2026-08-27: two seats' access tokens have been dead for
# ~17h and ~59h, and the keeper cannot rotate them because nothing runs a session
# on those seats, so the staleness is STRUCTURAL and will persist. Their rows
# still printed a confident weekly percentage behind a bare `[quota cached]`. A
# 2.5-day-old number shown like a live one is worse than a blank, because a blank
# sends Cédric to look and a confident number does not. Below AGE_VISIBLE_SECS
# the source marker alone is enough: that number is, for every purpose this table
# serves, now.
# ⚠️ rota-engine.sh has the twin of this pair (its own dashboard is bash). If this
# 120 moves, move that one: two surfaces disagreeing about when a number stops
# being current is worse than either threshold on its own.
AGE_VISIBLE_SECS = 120
def age_short(ts):
    if not ts: return ''
    # except Exception, not except ValueError. A stamp that is None-ish, naive, or
    # simply not a string raises TypeError/AttributeError instead, and a traceback
    # under a half-drawn table is the one failure mode this whole file is written
    # to avoid. An age we cannot compute is an age we do not print.
    try:
        secs = int((datetime.now().astimezone()
                    - datetime.fromisoformat(ts.replace('Z', '+00:00'))).total_seconds())
    except Exception:
        return ''
    if secs <= AGE_VISIBLE_SECS: return ''
    if secs >= 86400: return f"{secs // 86400}d"
    if secs >= 3600:  return f"{secs // 3600}h"
    return f"{secs // 60}m"

# A bar makes the column scannable: five seats sorted by charge date are five
# numbers you have to read, but one glance at the bars finds the empty ones.
BAR_W = 9
def bar(pct, width=BAR_W):
    if pct is None: return ' ' * width
    filled = int(round(pct / 100 * width))
    return '\u2588' * filled + '\u2591' * (width - filled)

print(f"\nSeats on {c(host, '1')} \u00b7 {fmt(usage.get('generated_at'))} \u00b7 active: {c(usage.get('activeEmail') or '?', '36')}\n")
# ⚠️ THE WEEKLY CELL IS LEFT-ALIGNED IN ITS 21, and the header right-aligned over
# the first 14 of it. Every measured cell is exactly 14 wide (bar + " nnn%"), so
# under the old right-alignment they all sat flush at the far end and the bars
# lined up by accident. The UNMEASURED cell is 20, which under that rule shoved
# its bar six columns left of every other bar: the one column whose whole job is
# being comparable at a glance, no longer comparable. Left-aligning pins every
# bar to the same offset and spends the column's existing slack on the long cell
# instead. Nothing to the right of it moves; the 36-wide SEAT column above still
# supplies the gutter.
#
# {'':7}, never seven typed spaces: the header and the rows have to add up to the
# same 21 or every column after 5H drifts, and a miscounted run of spaces is
# invisible in the source and obvious in the table.
hdr = (f"  {'SEAT':36} {'WEEKLY LEFT':>14}{'':7}  {'5H':>4}  {'GONE IN':>8}  "
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
    # ⚠️ THIS CELL IS THE WHOLE POINT OF THE UNMEASURED WORK. `0%` (spent) and
    # `-` (unknown) were both visually EMPTY, and on 2026-08-21 that cost two
    # cancelled-but-live seats' worth of already-paid-for quota: the operator
    # read "unknown" as "finished". A bar of question marks cannot be mistaken
    # for an empty one at a glance, and the word is rota-engine.sh's own bucket
    # name, so the two surfaces say the same thing about the same seat.
    # NO NUMBER IS INVENTED HERE: unmeasured is unmeasured.
    if is_unmeasured(r):
        wk_plain, wk_code = f"{'?' * BAR_W} UNMEASURED", '1;33'
    elif wk is None:
        wk_plain, wk_code = f"{bar(None)}    -", '90'
    else:
        wk_plain = f"{bar(wk)} {wk:>3}%"
        if   wk == 0:  wk_code = '31'  # spent
        elif wk < 20:  wk_code = '33'  # under the >=20%-left health floor
        else:          wk_code = '32'
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
        # ⚠️ "(LAST window)" IS THE MOST DECISION-RELEVANT FACT ON THE ROW and it
        # only ever lived in rota-engine.sh's table. The seat dies before its
        # quota refills, so whatever is left in this window is all it will ever
        # have. fmt_date, not fromisoformat: `cancelled` with no `ends` in
        # billing.json used to be a traceback under a half-drawn table.
        tail = ' (LAST window)' if r['last_window'] else ''
        notes.append(c(f"CANCELLED, ends {fmt_date(r['ends'])}{tail}", '31'))
    elif r['status'] == 'unknown':
        notes.append(c('billing unknown, add it to billing.json', '33'))
    # ⚠️ PROVENANCE AND AGE ON EVERY NUMBER THIS BOX DID NOT MEASURE LIVE. The
    # marker answers "whose measurement is this", the age answers "from when",
    # and a row missing either one reads as current when it may be days old.
    # It COMPOSES with RESERVED / CANCELLED above rather than replacing them:
    # whose seat it is and how fresh the number is are different questions.
    if r['quota_data'] not in ('live', None):
        age = age_short(r.get('quota_measured_at'))
        if r['quota_data'] == 'peer':
            # the peer's own name, not "a peer": which box answered is the whole
            # point of the marker, and it is what you would ssh to to check
            where = r.get('quota_source') or 'a peer'
            notes.append(c(f"[via {where}, {age} old]" if age else f"[via {where}]", '33'))
        elif r['quota_data'] == 'cached':
            notes.append(c(f"[cached, {age} old]" if age else "[cached]", '33'))
        else:
            notes.append(c(f"[quota {r['quota_data']}]", '33'))

    nc_plain = datetime.fromisoformat(r['next_charge']).strftime('%-d %b %Y') if r['next_charge'] else 'none'
    nc = pad(nc_plain, 12, None if r['next_charge'] else '90', right=True)
    name = pad(r['account'] + (' <' if r['active_now'] else ''), 36,
               '36' if r['active_now'] else ('90' if r['reserved'] else None))

    # ── GONE IN AND QUOTA RESETS, HONEST ON A ROLLED WINDOW ──────────────────
    # Both used to read straight off the cached `weekly_resets_at`, which on an
    # unmeasured row is a reset that has ALREADY HAPPENED: tartare printed
    # `due` / `Thu 27 Aug 19:00` at 21:00 on the 27th, two hours after that
    # window refilled. GONE IN now counts down loses_at (the same min(next
    # reset, seat end) the ranking sorts on, so column and order cannot tell
    # different stories), and QUOTA RESETS names the next reset the seat will
    # actually see. On a last window the reset is dimmed: the seat will not live
    # to see it, and the column must not contradict the note beside it.
    gone = loses_at(r)
    reset_plain = fmt(next_reset(r))
    print(f"  {name} {pad(wk_plain, 21, wk_code)}  {fh_plain:>4}  "
          f"{countdown(gone):>8}  "
          f"{pad(reset_plain, 17, '90' if r['last_window'] else None)} {nc} "
          f"{r['amount']:>11}  {'  '.join(notes)}")

# ── WHAT TO DO ABOUT AN UNMEASURED ROW ──────────────────────────────────────
# The MARKER belongs in the row (the ????????? cell). The INSTRUCTION does not:
# NOTES is the one column with no width budget left, already carrying RESERVED,
# CANCELLED plus an end date, and the provenance-and-age marker, and a 40-char
# command in there would push all three off the right edge of a terminal on the
# very row that most needs reading. So the row says what is TRUE and this block,
# once, says what to DO, naming each seat and the exact command.
#
# The polarity line is not padding: the table prints what is LEFT and --record
# takes what is USED, and inverting a number you are copying off a screen is how
# a typo becomes a wrong decision (rota-engine.sh's own --record help says the
# same, in the same words).
unmeasured_rows = [r for r in rows if is_unmeasured(r)]
if unmeasured_rows:
    print(f"\n  {c('UNMEASURED', '1;33')}  "
          f"{c('quota UNKNOWN, not spent. Very possibly full; go and look', '2')}")
    for r in unmeasured_rows:
        who = r['alias'] or r['account']
        print(f"     {c(f'rota usage --record {who} <weekly-used-%>', '1')}")
    print(f"     {c('the number is the USED % the vendor usage page prints, not what is left', '2')}")

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
# That key is loses_at(), defined once near the top of this file and shared with
# the GONE IN column, so the order and the countdown cannot drift apart.
floor = (usage.get('floors') or {}).get('weekly_pct', 20)

# ⚠️ A RESERVED SEAT IS NEVER A RECOMMENDATION. Quota is not the only fact that
# decides whether a seat is available, and this ranking used to behave as if it
# were: on 2026-08-25 it printed `rota switch tommy` for a seat handed to a
# colleague the previous day, and `--json` consumers inherited the same mistake.
# --include-reserved exists for the deliberate override, and says so out loud.
#
# ⚠️ AN UNMEASURED SEAT IS NEVER A RECOMMENDATION EITHER, and the `or 0` below
# is not why. "Very possibly full" is a reason to go and LOOK, never a figure to
# rank on, so the exclusion is spelled out rather than left to depend on a None
# happening to fall under the floor: the day something hands these rows a
# placeholder percentage, that accident would start recommending a guess.
usable = [r for r in rows if (r['weekly_left_pct'] or 0) >= floor
          and not is_unmeasured(r)
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
    # last_window(), the same predicate that puts "(LAST window)" in the row's
    # NOTES, so the row and the recommendation cannot say different things about
    # the same seat.
    if p['last_window']:
        why = (f"the seat ends {fmt_date(p['ends'])}, before its next "
               f"reset: this is its LAST window")
    else:
        why = f"its weekly window resets first ({fmt(next_reset(p))}), so this is the quota closest to being lost"
    print(f"\n  {c('USE NEXT', '1;32')}   {c(cmd, '1')}")
    print(f"     {p['account']} · {p['weekly_left_pct']}% weekly left · {why}")
    if p['active_now']:
        print(f"     {c('(you are already on it)', '2')}")
    rest = usable[1:]
    if rest:
        # .astimezone(): the engine's stamps carry their own offset, and a reset
        # printed in someone else's timezone is a wrong weekday on the line whose
        # entire job is naming the weekday.
        def _resets(r):
            d = next_reset(r)
            return d.astimezone().strftime('%a %-d %b') if d else '?'
        tail = '  ·  '.join(
            f"{r['alias'] or r['account']} ({r['weekly_left_pct']}%, resets {_resets(r)})"
            for r in rest)
        print(f"     {c('then', '2')} {c(tail, '2')}")
else:
    # ⚠️ AN UNMEASURED SEAT IS NOT AN "EARLIEST BACK". It may be full RIGHT NOW,
    # and naming its next reset would tell you to wait for quota you might
    # already be holding, which is the same inversion the UNMEASURED bucket
    # exists to undo. The block above the total is its answer instead.
    cands = [r for r in rows if not is_unmeasured(r) and next_reset(r)]
    soonest = min(cands, key=next_reset, default=None)
    msg = f"nothing clears the {floor}%-weekly floor"
    if soonest:
        msg += f"; earliest back is {soonest['alias'] or soonest['account']} at {fmt(next_reset(soonest))}"
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
# The peer clause appears only when a row actually used a peer, so a box with no
# peers configured never sees it. (The LEAD-IN did change unconditionally, see
# below: it used to promise LIVE for the whole table, which is the over-claim the
# per-row markers exist to retire, and that is true peer or no peer.)
peer_hosts = sorted({r.get('quota_source') for r in rows
                     if r.get('quota_data') == 'peer' and r.get('quota_source')})
peer_clause = (f"; rows marked [via {' / '.join(peer_hosts)}] were read over ssh from "
               f"{'that box, which holds' if len(peer_hosts) == 1 else 'those boxes, which hold'} "
               f"the credential this one does not (no credential is ever copied)") if peer_hosts else ''
# "unless a row says otherwise": the lead-in used to promise LIVE for the whole
# table, which was the same over-claim the per-row markers exist to retire.
print(f"\n  {c('quota is measured live unless the row says otherwise; billing comes from billing.json; reservations from each seat'+chr(39)+'s RESERVED marker + $CFG_DIR/reserved'+peer_clause, '2')}\n")
PY
