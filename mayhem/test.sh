#!/usr/bin/env bash
#
# mayhem/test.sh — RUN PCRE2's OWN functional suite (built by mayhem/build.sh in build-tests/).
# exit 0 = pass. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
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

TDIR="$SRC/build-tests"
for f in pcre2test pcre2grep pcre2_jit_test pcre2posix_test; do
  [ -x "$TDIR/$f" ] || { echo "missing $TDIR/$f — mayhem/build.sh did not build the test suite" >&2; exit 2; }
done
cd "$TDIR"
export srcdir="$SRC"
log="$(mktemp)"; trap 'rm -f "$log"' EXIT

passed=0; failed=0; skipped=0

# RunTest: golden-output comparisons of pcre2test against testdata/testoutput* (8/16/32-bit, +/- JIT).
if "$SRC/RunTest" >"$log" 2>&1; then rt=0; else rt=$?; fi
cat "$log"
p=$(grep -c '^  OK' "$log" || true); s=$(grep -c '^  Skipped' "$log" || true)
f=$(grep -ciE 'fail|differ' "$log" || true)
if [ "$rt" -ne 0 ] && [ "$f" -eq 0 ]; then f=1; fi
if [ "$rt" -eq 0 ] && { [ "$p" -eq 0 ] || ! grep -q '^All tests passed' "$log"; }; then f=$((f + 1)); fi
passed=$((passed + p)); skipped=$((skipped + s)); failed=$((failed + f))

# RunGrepTest: pcre2grep output compared with testdata/grepoutput*.
if "$SRC/RunGrepTest" >"$log" 2>&1 && grep -q '^Testing pcre2grep main features' "$log"; then
  cat "$log"; passed=$((passed + 1))
else cat "$log"; failed=$((failed + 1)); fi

# JIT regression tests: self-checking; require the success banner.
if ./pcre2_jit_test >"$log" 2>&1 && grep -q 'successfully passed' "$log"; then
  tail -3 "$log"; passed=$((passed + 1))
else tail -20 "$log"; failed=$((failed + 1)); fi

# POSIX wrapper tests: require its own pass banner.
if ./pcre2posix_test >"$log" 2>&1; then
  cat "$log"; passed=$((passed + 1))
else cat "$log"; failed=$((failed + 1)); fi

emit_ctrf "pcre2-runtest" "$passed" "$failed" "$skipped"
