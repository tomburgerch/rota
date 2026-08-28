#!/usr/bin/env bash
# shellcheck shell=bash
# rota-ranking.sh: THE one answer to "which seat is next", SOURCED by every
# picker that has to answer it. Never executed; it defines functions and nothing
# else, so sourcing it has no side effects beyond the definitions.
#
# WHY THIS FILE EXISTS. rota grew two pickers, and they were kept in step BY
# CONVENTION - a comment in each file saying "the other one ranks the same way,
# do not 'fix' the difference". Convention held right up until one side learned
# something the other did not:
#
#   rota-engine.sh   compute_recommendation, the interactive surfaces
#                    (`rota usage`, `rota switch`). Ranked on
#                    min(weekly reset, SEAT END) from 2026-08-27.
#   rota-keeper.sh   the unattended auto-switch at the 90% wall. Still ranked
#                    on the weekly reset ALONE.
#
# They diverge for exactly ONE shape, and it was live on the pool within days of
# being written: a CANCELLED seat whose end date falls before its next weekly
# reset (2026-08-27, tartare@ ending 1 Sep with its quota resetting 27 Aug, and
# thea.hawk@ ending 6 Sep resetting 28 Aug). The engine would send you to the
# seat that is about to disappear for good; the keeper would send you somewhere
# else. A picker that disagrees with ITSELF is worse than either rule, because
# neither answer can be trusted without knowing which code path produced it.
#
# So the rule lives HERE, once, and both pickers call it. Adding a third surface
# means calling these functions, never writing the comparison out again.
#
# ⚠️ WHAT IS DELIBERATELY *NOT* HERE: the ELIGIBILITY filters. Which seats may
# be picked at all is a different question from how the eligible ones are
# ordered, and the two callers answer it differently ON PURPOSE - the engine
# runs MIN_WEEKLY (20%-left) + MIN_SESSION (10%-left) for a choice the operator
# is watching, the keeper adds AUTO_SWITCH_TARGET_MAX_PCT (an 80%-used ceiling),
# AUTO_SWITCH_TARGET_MIN_LEFT_PCT (a 30%-left floor) and bounce hysteresis
# because it fires unattended and must not land him on a seat that is nearly
# spent too. Those stay where they are. This file unifies the ORDER, not the
# guest list.

# ── the seat lifecycle, read out of billing.json ─────────────────────────────
#
# rota_seat_field <billing-json> <email> 1  -> active|cancelled
# rota_seat_field <billing-json> <email> 2  -> YYYY-MM-DD end date
#
# Read-only and best-effort: a missing, unreadable or jq-less billing file
# leaves every seat "active with no end date", which is exactly how both callers
# behaved before either of them read the file. billing.json is optional (rota
# works without one), so a quota tool must not start failing because a BILLING
# note is absent.
#
# ⚠️ ONE TSV BLOB, NOT AN ASSOCIATIVE ARRAY. macOS ships bash 3.2, which has no
# `declare -A`, and both callers run under `#!/usr/bin/env bash` on every Mac. A
# hash here fails at PARSE time with "declare: -A: invalid option", so the whole
# tool dies rather than degrading.
ROTA_SEATS_TSV=""
ROTA_SEATS_LOADED=0
rota_load_seats() {  # rota_load_seats <billing-json>
  (( ROTA_SEATS_LOADED )) && return 0
  ROTA_SEATS_LOADED=1
  [[ -r "${1:-}" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  ROTA_SEATS_TSV="$(jq -r '(.accounts // {}) | to_entries[]
                           | [.key, (.value.status // "active"), (.value.ends // "")] | @tsv' \
                      "$1" 2>/dev/null || true)"
  return 0
}

# Empty when the seat is not in the file, which is the same answer as "active,
# no end date" everywhere this is used.
#
# ⚠️ `f+1`, because awk's $1 is the EMAIL the row is keyed by, not the first
# VALUE. Without the offset every caller asking for the status got the email
# back, a non-empty string, so a `== cancelled` test silently answered "no" for
# every cancelled seat and the whole feature was inert while looking like it
# worked.
rota_seat_field() {  # rota_seat_field <billing-json> <email> <1=status|2=ends>
  rota_load_seats "${1:-}"
  [[ -n "${2:-}" ]] || return 0
  printf '%s\n' "$ROTA_SEATS_TSV" | awk -F'\t' -v e="$2" -v f="${3:-2}" '$1==e{print $(f+1); exit}'
}

# ── THE DEADLINE: min(weekly reset, SEAT END) ────────────────────────────────
#
# ⚠️ A CANCELLED SEAT IS THE MOST USE-IT-OR-LOSE-IT QUOTA IN THE POOL, NOT THE
# LEAST. It has a fixed number of weekly windows left, ever: after its end date
# that quota is gone whether it was spent or not. Ranking on the weekly reset
# alone treats it as just another account, and in its FINAL PARTIAL WEEK that is
# simply wrong - the seat dies before the window would have refilled, so the
# quota is lost on the end date, not on the reset.
#
# ⚠️ DO NOT "SIMPLIFY" THIS BACK TO THE WEEKLY RESET ALONE. That is the older
# rule, it looks identical whenever the two dates happen to agree (which is
# almost always), and it is silently wrong exactly when it matters. The engine
# carried a warning to this effect from 2026-08-27; this function is where that
# warning now lives, because this is now the only place the rule is written.
#
# Prints "<deadline-iso>\t<reset|seat-end>", i.e. WHEN the quota goes away and
# WHICH of the two dates decided it, because a surface that names the wrong one
# gives the right answer under the wrong noun. Both fields are empty when the
# seat has neither date.
#
# ⚠️ THE "NO DEADLINE" SENTINEL IS THE EMPTY STRING, AND IT MUST RANK LAST.
# An empty string sorts BEFORE every real ISO timestamp under a string compare,
# so a seat with nothing expiring would otherwise come FIRST - the healthiest
# seat in the pool recommended as the most urgent. rota_deadline_beats() below
# handles it as an explicit branch rather than leaning on the comparison, and
# nothing here ever invents a far-future date to stand in for it: a fake instant
# is something a surface can print, and "resets 9999-12-31" is a lie.
#
# A bare YYYY-MM-DD end date sorts against an ISO instant correctly under a
# plain string compare because both are ISO-8601 and lexicographic order IS
# chronological order. It is read as that day's MIDNIGHT, the conservative end
# of the seat's last day, the same choice rota-billing.sh's parse_ts makes.
rota_seat_deadline() {  # rota_seat_deadline <weekly-reset-iso> <seat-end-date>
  local wkr="${1:-}" ends="${2:-}"
  [[ -n "$ends" ]] && ends="${ends}T00:00:00Z"
  if [[ -z "$wkr" && -z "$ends" ]]; then printf '\t'; return 0; fi
  if [[ -z "$wkr" ]]; then printf '%s\tseat-end' "$ends"; return 0; fi
  if [[ -z "$ends" ]]; then printf '%s\treset' "$wkr"; return 0; fi
  # a tie goes to the RESET: the window refills that instant, so the seat is
  # still alive for it, and calling that "the seat ends" would be the wrong noun.
  if [[ "$ends" < "$wkr" ]]; then printf '%s\tseat-end' "$ends"; else printf '%s\treset' "$wkr"; fi
}

# ── THE ORDER ────────────────────────────────────────────────────────────────
# Does the candidate outrank the incumbent? Exit 0 = yes, replace it.
#
# Three rules, in order, and each of the three has already been the difference
# between a right and a wrong pick somewhere in this repo:
#
#   1. A REAL DEADLINE ALWAYS BEATS NO DEADLINE. A seat with nothing expiring is
#      not urgent, it is the opposite; it takes the pick only when nothing else
#      is on offer. (The empty-string sentinel, see above.)
#   2. SOONEST DEADLINE WINS. The limit is weekly and use-it-or-lose-it: unused
#      quota never rolls over, so the seat to spend now is the one whose window
#      dies first. The operator, 2026-08-16, asked for exactly this: "always
#      work on the one that expires next and burn all those tokens before
#      switching to the one right after".
#   3. AN EXACT TIE GOES TO THE LOWEST UTILIZATION. This is the keeper's older
#      rule kept as the tie-break, so the pick stays deterministic where the
#      newer policy is silent. Without it a tie falls through to whatever order
#      the accounts file happens to list, which is not a rule anyone chose.
#      A missing/unparseable utilization loses the tie-break rather than
#      winning it by accident: it is not a number, so it cannot be the lowest.
rota_deadline_beats() {  # rota_deadline_beats <cand-deadline> <cand-used-pct> <best-deadline> <best-used-pct>
  local c="${1:-}" cu="${2:-}" b="${3:-}" bu="${4:-}"
  # 1. real deadline vs none, in both directions
  if [[ -z "$c" && -n "$b" ]]; then return 1; fi
  if [[ -n "$c" && -z "$b" ]]; then return 0; fi
  # 2. soonest wins (both real, or both the sentinel and therefore equal)
  if [[ "$c" < "$b" ]]; then return 0; fi
  if [[ "$b" < "$c" ]]; then return 1; fi
  # 3. exact tie: lowest utilization
  [[ "$cu" =~ ^[0-9]+$ ]] || return 1
  [[ "$bu" =~ ^[0-9]+$ ]] || return 0
  (( cu < bu ))
}
