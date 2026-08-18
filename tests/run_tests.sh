#!/usr/bin/env bash
# Test driver.
#
# The suite is split into area files under tests/cases/. Each area runs in its
# own process with its own scratch tree, so areas run in parallel by default.
#
# Usage:
#   tests/run_tests.sh                     # every area
#   tests/run_tests.sh --list              # names only
#   tests/run_tests.sh --filter local      # areas whose name matches
#   tests/run_tests.sh --filter 'sync|forge'
#   tests/run_tests.sh --jobs 1            # serialize (for a readable trace)
#   AI_PR_LOOP_TEST_FILTER=autoresume tests/run_tests.sh
#
# The filter is an extended regular expression matched against the area name
# (the file name without its numeric prefix and .sh suffix).
#
# Environment:
#   AI_PR_LOOP_TEST_FILTER     same as --filter
#   AI_PR_LOOP_TEST_JOBS       same as --jobs
#   AI_PR_LOOP_TEST_KEEP_WORK  keep each area's scratch tree (see harness)
#   AI_PR_LOOP_TEST_FAIL_FAST  stop an area at its first failure
#
# Parallelism note: two areas drive run.sh against the repository's own
# state/ tree (see SERIALIZED below) and would clobber each other's fixture
# directories, so they always share one lane. Every other area keeps its
# fixtures inside its own mktemp scratch tree and is safe to run concurrently.

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"

# Areas that write to $ROOT/state and therefore cannot run beside each other.
SERIALIZED='flags autoresume'

FILTER="${AI_PR_LOOP_TEST_FILTER:-}"
JOBS="${AI_PR_LOOP_TEST_JOBS:-}"
LIST_ONLY=0
RUN_ONE=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --filter)
      [[ $# -ge 2 ]] || { printf 'run_tests.sh: --filter needs a pattern\n' >&2; exit 2; }
      FILTER="$2"; shift 2 ;;
    --filter=*) FILTER="${1#--filter=}"; shift ;;
    --jobs)
      [[ $# -ge 2 ]] || { printf 'run_tests.sh: --jobs needs a number\n' >&2; exit 2; }
      JOBS="$2"; shift 2 ;;
    --jobs=*)   JOBS="${1#--jobs=}"; shift ;;
    --list)     LIST_ONLY=1; shift ;;
    # Internal: run exactly one area file and print a machine-readable tally.
    --_area)    RUN_ONE="$2"; shift 2 ;;
    -h|--help)  sed -n '2,28p' "$0"; exit 0 ;;
    *) printf 'run_tests.sh: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

area_name() {  # <path> -> name without numeric prefix and .sh
  local b="${1##*/}"; b="${b%.sh}"; printf '%s\n' "${b#*-}"
}

# --- child: one area, one scratch tree -------------------------------------
if [[ -n "$RUN_ONE" ]]; then
  . "$TESTS_DIR/lib/harness.sh"
  . "$TESTS_DIR/lib/stubs.sh"
  . "$ROOT/lib/common.sh"
  . "$RUN_ONE"
  printf '@@TALLY %s %s %s\n' "$PASS" "$FAIL" "$SKIPPED"
  (( FAIL == 0 )) || exit 1
  exit 0
fi

SELECTED=()
for f in "$TESTS_DIR"/cases/*.sh; do
  [[ -e "$f" ]] || continue
  n=$(area_name "$f")
  if [[ -n "$FILTER" ]]; then
    printf '%s\n' "$n" | grep -Eq -- "$FILTER" || continue
  fi
  SELECTED+=("$f")
done

if (( LIST_ONLY == 1 )); then
  for f in "$TESTS_DIR"/cases/*.sh; do
    [[ -e "$f" ]] && printf '%s\n' "$(area_name "$f")"
  done
  exit 0
fi

if (( ${#SELECTED[@]} == 0 )); then
  printf 'run_tests.sh: no area matches %s (try --list)\n' "${FILTER:-<empty>}" >&2
  exit 2
fi

if [[ -z "$JOBS" ]]; then
  JOBS=$(nproc 2>/dev/null || echo 4)
  (( JOBS > 6 )) && JOBS=6
fi
[[ "$JOBS" =~ ^[0-9]+$ ]] && (( JOBS >= 1 )) || JOBS=1

OUT_DIR=$(mktemp -d) || exit 1
trap 'rm -rf "$OUT_DIR"' EXIT

# Build lanes: the serialized areas share lane 0, everything else gets its own.
LANES=(); SERIAL_LANE=''
for f in "${SELECTED[@]}"; do
  n=$(area_name "$f")
  if [[ " $SERIALIZED " == *" $n "* ]]; then
    SERIAL_LANE="$SERIAL_LANE $f"
  else
    LANES+=("$f")
  fi
done
[[ -z "$SERIAL_LANE" ]] || LANES=("$SERIAL_LANE" "${LANES[@]+"${LANES[@]}"}")

run_lane() {  # <lane> — one or more area files, run in sequence
  local f n rc=0
  for f in $1; do
    n=$(area_name "$f")
    "$BASH" "$TESTS_DIR/run_tests.sh" --_area "$f" > "$OUT_DIR/$n.log" 2>&1 || rc=1
  done
  return $rc
}
BASH="$(command -v bash)"

running=0
for lane in "${LANES[@]}"; do
  run_lane "$lane" &
  running=$((running + 1))
  if (( running >= JOBS )); then wait -n 2>/dev/null || wait; running=$((running - 1)); fi
done
wait

# --- report in area order --------------------------------------------------
PASS=0; FAIL=0; SKIPPED=0
for f in "${SELECTED[@]}"; do
  n=$(area_name "$f")
  [[ -f "$OUT_DIR/$n.log" ]] || continue
  grep -v '^@@TALLY ' "$OUT_DIR/$n.log" >&2
  read -r _ p x s < <(grep '^@@TALLY ' "$OUT_DIR/$n.log" | tail -1)
  PASS=$((PASS + ${p:-0})); FAIL=$((FAIL + ${x:-0})); SKIPPED=$((SKIPPED + ${s:-0}))
  printf '%-12s %s passed, %s failed, %s skipped\n' "$n" "${p:-?}" "${x:-?}" "${s:-?}"
done

printf '\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIPPED"
(( FAIL == 0 )) || exit 1
exit 0
