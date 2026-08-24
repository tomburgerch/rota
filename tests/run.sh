#!/usr/bin/env bash
# Run every tests/*.test.sh; one line per suite; nonzero exit if any failed.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
failed=0; total=0
for t in "$ROOT"/tests/*.test.sh; do
  [ -e "$t" ] || continue
  total=$((total+1))
  name="$(basename "$t")"
  out="$(bash "$t" 2>&1)"; rc=$?
  summary="$(printf '%s\n' "$out" | grep -E '[0-9]+ passed' | tail -1)"
  if [ "$rc" -eq 0 ]; then
    printf 'PASS  %-28s %s\n' "$name" "${summary:-ok}"
  else
    failed=$((failed+1))
    printf 'FAIL  %-28s %s (exit %d)\n' "$name" "${summary:-no summary}" "$rc"
    printf '%s\n' "$out" | grep -E 'FAIL|error' | sed 's/^/        /' | head -20
  fi
done
printf '%d suites, %d failed\n' "$total" "$failed"
[ "$failed" -eq 0 ]
