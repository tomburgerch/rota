#!/usr/bin/env bash
# rota-reserve.sh: mark a pool seat as RESERVED, so nothing opens an
# interactive session on it by accident.
#
#   rota reserve                        list what is reserved
#   rota reserve runner always-on-runner "this credential is pushed to the runners"
#   rota reserve --release runner       drop the reservation
#
# WHY A MARKER FILE IN THE SEAT, and not a list in a script. On 2026-08-21 an
# interactive pane ran under an explicit CLAUDE_CONFIG_DIR pin and spent a
# reserved seat's whole weekly quota. The rule already existed, as prose in one
# script's header and a hardcoded list of aliases in another, and nothing
# enforced it, because a constant in one script is invisible to every other
# launch path. The seat directory itself is the one thing every path touches, so
# the reservation lives there: lib/rota-shim.sh reads it on every `claude`
# launch and refuses an interactive session, and lib/rota-keeper.sh reads it
# each tick and alarms once when the seat drops under its floor.
#
# What a reservation does NOT do: headless `--print`, the `auth`/`mcp`/`config`
# subcommands and the keeper's own health probes all still run. Refusing those
# would break the seat's legitimate users, and a seat whose health cannot be
# probed is a worse outage than the one this prevents.
set -euo pipefail

POOL_ROOT="${CLAUDE_POOL_DIR:-$HOME/.claude-pool}"
MARKER="${CLAUDE_RESERVED_MARKER:-RESERVED}"

die() { printf 'rota-reserve: %s\n' "$*" >&2; exit 1; }

if [ $# -eq 0 ]; then
  found=0
  for d in "$POOL_ROOT"/*/; do
    [ -f "$d$MARKER" ] || continue
    found=1
    printf '%-10s %s\n' "$(basename "$d")" "$(sed -n 's/^owner=//p' "$d$MARKER" | head -1)"
    why="$(sed -n 's/^why=//p' "$d$MARKER" | head -1)"
    [ -n "$why" ] && printf '%-10s   %s\n' "" "$why"
  done
  [ "$found" -eq 1 ] || printf 'no reserved seats under %s\n' "$POOL_ROOT"
  exit 0
fi

if [ "${1:-}" = "--release" ]; then
  seat="${2:?--release needs a seat}"
  [ -d "$POOL_ROOT/$seat" ] || die "no seat at $POOL_ROOT/$seat"
  rm -f "$POOL_ROOT/$seat/$MARKER"
  printf 'released %s\n' "$seat"
  exit 0
fi

seat="$1"; owner="${2:-}"; why="${3:-}"
[ -n "$owner" ] || die "usage: rota reserve <seat> <owner> [why]"
[ -d "$POOL_ROOT/$seat" ] || die "no seat at $POOL_ROOT/$seat, is '$seat' a real alias? (rota usage lists them)"

{
  printf 'owner=%s\n' "$owner"
  [ -n "$why" ] && printf 'why=%s\n' "$why"
  printf 'reserved_at=%s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
} > "$POOL_ROOT/$seat/$MARKER"

printf 'reserved %s for %s\n' "$seat" "$owner"
printf '  an interactive `claude` on this seat now refuses (CLAUDE_SEAT_OVERRIDE=1 to force)\n'
printf '  headless --print, auth/mcp subcommands and the pool keeper probes are unaffected\n'
