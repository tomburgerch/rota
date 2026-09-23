#!/usr/bin/env bash
# shellcheck disable=SC2015
#
# reserved-alarm.test.sh: the pool keeper's RESERVED-seat floor alarm.
#
# HERMETIC. Drives the REAL check_reserved_seats() out of lib/rota-keeper.sh
# with stubbed usage numbers and a sandboxed state dir, so it never notifies
# anyone, never reads a real seat, and never runs a keeper tick.
#
# ── WHAT THIS GUARDS ───────────────────────────────────────────────────────
#
# A reserved seat went to 0% on 2026-08-21 and was found DAYS LATER, by
# accident. The shim now refuses interactive sessions on a reserved seat, but a
# guard only covers the ways it knows about, this alarm is the backstop that
# notices the quota going regardless of how.
#
# AND IT MUST BE QUIET WHEN NOTHING CHANGED. The standing rule is no repeating
# nudges: a seat sitting under its floor for three days must produce ONE
# message, not three days of them. A backstop that cries every tick gets muted,
# and a muted alarm is the same as no alarm, which is the state that lost the
# seat in the first place.
set -uo pipefail

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'ok   - %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL - %s\n' "$1"; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
KEEPER="$ROOT/lib/rota-keeper.sh"
[ -r "$KEEPER" ] || { echo "no keeper at $KEEPER" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/rota-reserved-alarm.XXXXXX")"
WORK="$(cd "$WORK" && pwd)"
trap 'rm -rf "$WORK"' EXIT
POOL="$WORK/pool"
CFG="$WORK/cfg"
mkdir -p "$POOL/runner" "$POOL/spare" "$CFG"
printf 'owner=always-on-runner\nwhy=pushed to the always-on runners\n' > "$POOL/runner/RESERVED"

# ── the function under test, lifted out of the keeper ───────────────────────
# The keeper runs main() at the bottom, so it cannot simply be sourced. Lift
# check_reserved_seats and the REAL helpers it depends on (log_once,
# notify_once, log_state_clear, usage_for, pct_int) and nothing else, so this
# exercises the shipped code rather than a copy of it. log_state_clear is a
# ONE-LINER in the keeper, hence its own single-line extraction: a `/^x()/,/^}/`
# range would run past it and swallow whatever follows.
FNSRC="$(
  sed -n '/^notify_once()/,/^}/p;/^log_once()/,/^}/p;/^usage_for()/,/^}/p;/^pct_int()/,/^}/p;/^check_reserved_seats()/,/^}/p' "$KEEPER"
  sed -n '/^log_state_clear()/p' "$KEEPER"
)"

# PREFLIGHT. If a rename in the keeper makes an extraction come back empty, the
# assertions below would fail in a way that says nothing about the real cause.
missing=""
for fn in notify_once log_once log_state_clear usage_for pct_int check_reserved_seats; do
  printf '%s' "$FNSRC" | grep -q "^$fn()" || missing="$missing $fn"
done
[ -z "$missing" ] \
  && ok "(preflight: every keeper function this drives was found and lifted)" \
  || bad "not lifted from $KEEPER, did they get renamed or reshaped?:$missing"

# alarm <reserved-seat weekly USED pct> <floor>
# `used` is weekly UTILISATION, which is what U_WK holds; the alarm reports the
# LEFT side of it.
alarm() {
  CLAUDE_KEEPER_NO_NOTIFY=1 bash -c '
    set -uo pipefail
    SRC="$1"; POOL="$2"; USED="$3"; FLOOR="$4"; CFG_DIR="$5"
    eval "$SRC"
    mkdir -p "$CFG_DIR"
    RESERVED_FLOOR_PCT="$FLOOR"
    LABELS=("runner@example.com" "spare@example.com")
    DIRS=("$POOL/runner" "$POOL/spare")
    U_LBL=("runner@example.com" "spare@example.com"); U_WK=("$USED" "10")
    log() { printf "LOG %s\n" "$*"; }
    check_reserved_seats
  ' _ "$FNSRC" "$POOL" "$1" "$2" "$CFG" 2>&1
}
fresh_state() { rm -rf "$CFG"; mkdir -p "$CFG"; }
said() { printf '%s' "$1" | grep -q 'RESERVED seat'; }

# ── IT FIRES when the seat is under the floor ──────────────────────────────
# 80% used = 20% left, floor 25 -> under.
fresh_state
OUT="$(alarm 80 25)"
case "$OUT" in *"RESERVED seat runner"*) ok "a reserved seat under the floor is reported" ;;
  *) bad "must report a seat under the floor: $OUT" ;; esac
case "$OUT" in *"20% weekly left"*) ok "…with the actual number, not just an adjective" ;;
  *) bad "must carry the number: $OUT" ;; esac
case "$OUT" in *"always-on-runner"*) ok "…and the owner, so it is actionable" ;;
  *) bad "must name the owner: $OUT" ;; esac

# THE NO-REPEAT RULE. Same state on the next tick must say NOTHING.
OUT2="$(alarm 80 25)"
said "$OUT2" && bad "it repeated itself on an unchanged state: $OUT2" \
  || ok "the same state on the next tick is silent (no repeating nudges)"

# A real WORSENING crosses a band and speaks again.
OUT3="$(alarm 95 25)"
case "$OUT3" in *"5% weekly left"*) ok "a materially worse state speaks again" ;;
  *) bad "crossing a band must re-report: $OUT3" ;; esac

# ── IT STAYS QUIET when the seat is healthy ────────────────────────────────
fresh_state
OUT="$(alarm 10 25)"
said "$OUT" && bad "must be quiet above the floor: $OUT" \
  || ok "a healthy reserved seat says nothing"

# AND RECOVERY RE-ARMS IT. A seat that dipped, recovered, then dips again must
# alarm the second time, otherwise the first alarm silences it forever.
fresh_state
alarm 80 25 >/dev/null      # dip
alarm 10 25 >/dev/null      # recover
OUT="$(alarm 80 25)"        # dip again
case "$OUT" in *"RESERVED seat runner"*) ok "a seat that recovered and dipped again alarms again" ;;
  *) bad "recovery must re-arm the alarm: $OUT" ;; esac

# ── AN UNRESERVED SEAT IS NEVER REPORTED, however spent ────────────────────
fresh_state
OUT="$(alarm 80 25)"
case "$OUT" in *spare*) bad "reported an UNRESERVED seat: $OUT" ;;
  *) ok "an unreserved seat is never reported, whatever its quota" ;; esac

# ── THE MARKER IS WHAT DECIDES ─────────────────────────────────────────────
rm -f "$POOL/runner/RESERVED"; fresh_state
OUT="$(alarm 95 25)"
said "$OUT" && bad "alarmed on an unmarked seat: $OUT" \
  || ok "with no marker there is nothing to alarm about"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
