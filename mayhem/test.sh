#!/usr/bin/env bash
# wla-dx/mayhem/test.sh — RUN wla-dx's OWN regression suite (run_tests.sh over tests/) against the
# normal-flags binaries that mayhem/build.sh produced → CTRF. PATCH-grade oracle: it never compiles
# the assemblers (build.sh already did, with the project's normal flags).
#
# run_tests.sh walks tests/<arch>/<case>/, and for each case runs `make` — which assembles main.s with
# `wla-<arch>`, links with `wlalink`, and runs `byte_tester` to DIFF the produced bytes against the
# expected/embedded byte values. This is a KNOWN-ANSWER / golden-output suite: it asserts the assembler
# emits the EXACT expected machine code, not merely that it exits 0. A no-op / exit(0) "patch" produces
# empty/wrong object bytes and FAILS byte_tester, so it cannot reward-hack this oracle. run_tests.sh
# `set -e`-aborts on the FIRST failing case (printing it) and otherwise prints `OK (N tests)` at the end.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

# run_tests.sh looks for the assemblers/linker on PATH at $PWD/binaries (and $PWD/build/binaries).
# build.sh built the normal-flags suite into build-tests/binaries — stage it where run_tests.sh expects.
[ -d "$SRC/build-tests/binaries" ] || { echo "missing build-tests/binaries — run mayhem/build.sh first" >&2; exit 2; }
rm -rf "$SRC/binaries"
mkdir -p "$SRC/binaries"
cp -f "$SRC"/build-tests/binaries/* "$SRC/binaries/"

# run_tests.sh builds byte_tester itself and runs every tests/<arch>/<case>. NO_VALGRIND keeps it from
# requiring/using valgrind (not installed in the base, and not what we're testing here). It set -e aborts
# on the first failing case, so a clean run means ALL counted cases passed.
out="$(NO_VALGRIND=1 sh "$SRC/run_tests.sh" 2>&1)"; rc=$?
printf '%s\n' "$out" | tail -25

# Parse the final "OK (<N> tests)" summary line (only printed on a fully-clean run).
total=$(printf '%s\n' "$out" | sed -n 's/^OK (\([0-9][0-9]*\) tests)$/\1/p' | tail -1)

if [ "$rc" -eq 0 ] && [ -n "${total:-}" ]; then
  emit_ctrf "wla-dx-run_tests" "$total" 0
  exit $?
fi

# Suite aborted on a failing case (or summary unparseable). run_tests.sh stops at the first failure, so
# we can't get an exact pass/fail split; record at least one failure so the oracle reports a real failure.
echo "run_tests.sh failed (rc=$rc) or summary unparseable" >&2
emit_ctrf "wla-dx-run_tests" "${total:-0}" 1
exit $?
