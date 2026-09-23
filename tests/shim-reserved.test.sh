#!/usr/bin/env bash
# The `[ … ] && ok … || bad …` assertion shape below is deliberate: ok()/bad()
# only printf + bump a counter (always return 0), so the SC2015 "C may run
# when A is true" caveat cannot bite. (Same convention as engine.test.sh.)
# shellcheck disable=SC2015
#
# shim-reserved.test.sh: the RESERVED-seat guard in lib/rota-shim.sh.
#
# HERMETIC. Runs the REAL shim against a sandboxed pool and a FAKE `claude`
# handed in via CLAUDE_SHIM_DIRS, so nothing here launches anything, reads a
# real credential, or touches a real seat.
#
# ── WHAT THIS GUARDS ───────────────────────────────────────────────────────
#
# On 2026-08-21 an interactive pane ran under an explicit CLAUDE_CONFIG_DIR pin
# and spent a reserved seat's whole weekly quota. The rule existed in prose and
# as one script's hardcoded list of aliases, and nothing enforced it.
#
# BUT THE DANGEROUS FAILURE OF THIS GUARD IS THE OTHER DIRECTION. Refusing too
# much would break the seat's LEGITIMATE users, the pool keeper's `claude -p`
# probe, the login check and the failover's `claude auth status`, and a seat
# whose health can no longer be probed is a worse outage than the one this
# prevents. So there are more assertions below about what must STILL RUN than
# about what must be refused, and each of them names the caller it protects.
set -uo pipefail

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'ok   - %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL - %s\n' "$1"; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SHIM="$ROOT/lib/rota-shim.sh"
[ -r "$SHIM" ] || { echo "no shim at $SHIM" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/rota-shim-reserved.XXXXXX")"
WORK="$(cd "$WORK" && pwd)"
trap 'rm -rf "$WORK"' EXIT
POOL="$WORK/pool"
mkdir -p "$POOL/runner" "$POOL/spare" "$WORK/bin"

printf 'owner=always-on-runner\nwhy=this credential is pushed to the always-on runners\n' \
  > "$POOL/runner/RESERVED"

# The FAKE real-claude. If this ever prints, the shim let the call through.
cat > "$WORK/bin/claude" <<'STUB'
#!/usr/bin/env bash
echo "RAN"
STUB
chmod +x "$WORK/bin/claude"

# run_tty <seat> [args…], WITH a tty on stdin, which is what an interactive
# pane has. `script -q /dev/null <cmd>` is how you allocate one from a suite
# that has no terminal of its own; its own stdin comes from /dev/null so it
# never blocks waiting for input (BSD script, i.e. macOS, which is what the
# rest of this repo targets).
# CLAUDE_SEAT_OVERRIDE is forwarded explicitly rather than inherited, so the
# override scenario is unambiguous and cannot leak into a later one. Empty is
# the same as unset to the shim, which tests it with `-n`.
run_tty() {
  local seat="$1"; shift
  script -q /dev/null env \
    CLAUDE_SHIM_DIRS="$WORK/bin" CLAUDE_CONFIG_DIR="$POOL/$seat" \
    CLAUDE_SEAT_OVERRIDE="${CLAUDE_SEAT_OVERRIDE:-}" \
    bash "$SHIM" "$@" < /dev/null 2>&1
}
# …and WITHOUT one, which is what a launchd job or a piped probe has.
run_notty() {
  local seat="$1"; shift
  CLAUDE_SHIM_DIRS="$WORK/bin" CLAUDE_CONFIG_DIR="$POOL/$seat" \
    bash "$SHIM" "$@" < /dev/null 2>&1
}
ran()     { printf '%s' "$1" | grep -q 'RAN'; }
refused() { printf '%s' "$1" | grep -q 'REFUSED'; }

# ── PREFLIGHT: the harness really does hand the child a tty ────────────────
# Without one, every "must still run" assertion below would pass VACUOUSLY
# while the refusal assertions failed, which is the confusing way for this
# suite to break. Check it once, out loud.
TTYCHK="$(script -q /dev/null bash -c '[ -t 0 ] && echo HASTTY || echo NOTTY' < /dev/null 2>&1)"
printf '%s' "$TTYCHK" | grep -q 'HASTTY' \
  && ok "(harness preflight: run_tty really gives the child a tty)" \
  || bad "harness cannot allocate a tty, every refusal assertion below is meaningless: $TTYCHK"

# ── IT REFUSES THE THING THAT BURNED THE SEAT ──────────────────────────────
OUT="$(run_tty runner)"
refused "$OUT" && ok "an interactive session on a reserved seat is refused" \
  || bad "must refuse an interactive session on a reserved seat: $OUT"
ran "$OUT" && bad "it refused but ALSO ran claude anyway: $OUT" \
  || ok "…and the real claude never runs"
printf '%s' "$OUT" | grep -q 'always-on-runner' \
  && ok "…and the refusal names the OWNER, so it is actionable" \
  || bad "the refusal must name the owner: $OUT"
printf '%s' "$OUT" | grep -q 'CLAUDE_SEAT_OVERRIDE' \
  && ok "…and names the one way past it" \
  || bad "the refusal must name the override: $OUT"

# THE EXPLICIT PIN IS THE PATH THE BREACH CAME IN THROUGH. The shim's own rule
# is "an explicit CLAUDE_CONFIG_DIR always wins, change nothing", so the guard
# has to sit in FRONT of that, or a hand-typed pin walks straight past.
# (Every case here sets the pin explicitly, which is exactly that path.)
ok "(the cases above all take the explicit-pin path, which is how it happened)"

# ── AND IT MUST NOT BREAK THE SEAT'S REAL USERS ────────────────────────────
OUT="$(run_tty runner -p 'ping')"
ran "$OUT" && ok "headless --print still runs (the pool keeper's health probe)" \
  || bad "MUST NOT break the keeper's \`claude -p\` probe: $OUT"

OUT="$(run_tty runner auth status)"
ran "$OUT" && ok "auth status still runs (the login check, the failover)" \
  || bad "MUST NOT break \`claude auth status\`: $OUT"

OUT="$(run_tty runner mcp list)"
ran "$OUT" && ok "mcp subcommands still run" || bad "must not break mcp: $OUT"

OUT="$(run_tty runner --version)"
ran "$OUT" && ok "--version still runs" || bad "must not break --version: $OUT"

OUT="$(run_notty runner)"
ran "$OUT" && ok "no TTY still runs, nothing is going to sit there spending quota" \
  || bad "must not refuse a non-interactive invocation: $OUT"

OUT="$(CLAUDE_SEAT_OVERRIDE=1 run_tty runner)"
ran "$OUT" && ok "CLAUDE_SEAT_OVERRIDE=1 lets a deliberate session through" \
  || bad "the override must work: $OUT"

# ── AN UNRESERVED SEAT IS UNTOUCHED ────────────────────────────────────────
OUT="$(run_tty spare)"
ran "$OUT" && ok "an unreserved seat is completely unaffected" \
  || bad "must not touch an unreserved seat: $OUT"
refused "$OUT" && bad "refused an unreserved seat: $OUT" || ok "…and is never refused"

# AN UNRECOGNISED FIRST ARG MUST COUNT AS A SESSION. If a new interactive mode
# ships, the guard should cover it by default rather than exempt it silently,
# the failure mode of this whole task was a rule that existed and did not apply.
OUT="$(run_tty runner --some-future-interactive-flag)"
refused "$OUT" && ok "an unrecognised invocation is treated as a session, not exempted" \
  || bad "an unknown arg must default to guarded: $OUT"

# ── THE MARKER IS WHAT DECIDES, so removing it releases the seat ───────────
rm -f "$POOL/runner/RESERVED"
OUT="$(run_tty runner)"
ran "$OUT" && ok "releasing the marker releases the seat" \
  || bad "with no marker the seat must be free: $OUT"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
