#!/usr/bin/env bash
# Run every test suite, one after another, and print one line per suite.
#   bash scripts/test-all.sh              all nine suites
#   bash scripts/test-all.sh ci backup    only these
#   bash scripts/test-all.sh --clean      afterwards, remove the suites' leftovers
# Full output of each suite: /tmp/mini-deploy-suites/<name>.txt. Exit 1 if any suite failed.
# Services must run the current code: restart them after editing a script (see CLAUDE.md).
set -uo pipefail
REPO=/mnt/c/Users/indra/Code/mini-deploy
ALL=(deploy build webhook sites ci admin upload backup smoke)
clean=0
names=()
for a in "$@"; do
  case "$a" in
    --clean) clean=1 ;;
    *) names+=("$a") ;;
  esac
done
[ ${#names[@]} -eq 0 ] && names=("${ALL[@]}")

out=/tmp/mini-deploy-suites
mkdir -p "$out"
failed=0
for s in "${names[@]}"; do
  if [ ! -f "$REPO/scripts/test-$s.sh" ]; then echo "$s: no such suite"; failed=1; continue; fi
  start=$(date +%s)
  bash "$REPO/scripts/test-$s.sh" > "$out/$s.txt" 2>&1
  verdict=$(grep -E '^(ALL PASSED|SOMETHING FAILED)$' "$out/$s.txt" | tail -1)
  fails=$(grep -c '^FAIL' "$out/$s.txt")
  [ "$verdict" = "ALL PASSED" ] && [ "$fails" -eq 0 ] || failed=1
  printf '%-8s %-16s %4ss  %s FAIL line(s)\n' "$s" "${verdict:-NO VERDICT}" "$(( $(date +%s) - start ))" "$fails"
done

if [ $clean -eq 1 ]; then
  # The suites' leftovers go; this run's outputs (/tmp/mini-deploy-suites) stay.
  python3 "$REPO/scripts/clean-test-leftovers.py" --yes | tail -1
fi
[ $failed -eq 0 ] && echo "EVERY SUITE PASSED" || echo "SOMETHING FAILED (see $out)"
exit $failed
