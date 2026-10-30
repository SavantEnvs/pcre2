#!/usr/bin/env bash
#
# mayhem/build.sh — build PCRE2's fuzz harnesses (8/16/32-bit code units x link sizes 2/3/4, the
# same nine OSS-Fuzz builds) with ASan+UBSan, their standalone reproducers, and the project's own
# test suite with NORMAL flags. Runs in /mayhem as `mayhem`; re-runnable and offline.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# deps/sljit is a git submodule; fetch it only if the checkout lacks it (a no-op on the offline re-run).
[ -f deps/sljit/sljit_src/sljitLir.c ] || git submodule update --init deps/sljit

# Generated autotools files are gitignored upstream; (re)create them every run.
./autogen.sh >/dev/null

# Never inherit flags from the environment into configure.
unset CFLAGS CXXFLAGS LDFLAGS CPPFLAGS

# libFuzzer coverage instrumentation for the code under test (the final link adds the engine itself).
COV_FLAGS="-fsanitize=fuzzer-no-link"

# Leak detection off, at build time (the hook object is linked into every fuzz + standalone binary).
LSAN_OFF="$SRC/build-lsan-off.o"
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$LSAN_OFF"

# ---- 1) sanitized fuzz builds: one out-of-tree build per link size ------------------------------
for ls in 2 3 4; do
  sfx=""; [ "$ls" = 2 ] || sfx="_${ls}l"
  bdir="$SRC/build-fuzz-${ls}l"
  rm -rf "$bdir"; mkdir -p "$bdir"
  ( cd "$bdir"
    "$SRC/configure" --enable-fuzz-support --enable-never-backslash-C \
        --with-match-limit=1000000 --with-match-limit-depth=1000000 \
        --enable-jit --enable-pcre2-16 --enable-pcre2-32 --with-link-size="$ls" \
        CC="$CC" CFLAGS="$SANITIZER_FLAGS $COV_FLAGS $DEBUG_FLAGS" LDFLAGS="$SANITIZER_FLAGS" >/dev/null
    make -j"$MAYHEM_JOBS" libpcre2-8.la libpcre2-16.la libpcre2-32.la \
        .libs/libpcre2-fuzzsupport.a .libs/libpcre2-fuzzsupport-16.a .libs/libpcre2-fuzzsupport-32.a >/dev/null
  )
  for bits in "" 16 32; do
    n="pcre2_fuzzer${bits:+_$bits}${sfx}"
    fs="$bdir/.libs/libpcre2-fuzzsupport${bits:+-$bits}.a"
    lib="$bdir/.libs/libpcre2-${bits:-8}.a"
    $CXX $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE "$LSAN_OFF" "$fs" "$lib" -o "$SRC/$n"
    $CC $SANITIZER_FLAGS $COV_FLAGS $DEBUG_FLAGS "$STANDALONE_FUZZ_MAIN" "$LSAN_OFF" "$fs" "$lib" -o "$SRC/$n-standalone"
  done
done

# ---- 2) the project's own test suite, NORMAL flags (test.sh only runs it) -----------------------
tdir="$SRC/build-tests"
rm -rf "$tdir"; mkdir -p "$tdir"
( cd "$tdir"
  "$SRC/configure" --enable-jit --enable-pcre2-16 --enable-pcre2-32 \
      CC="$CC" CFLAGS="-O2 $COVERAGE_FLAGS" LDFLAGS="$COVERAGE_FLAGS" >/dev/null
  make -j"$MAYHEM_JOBS" check TESTS= >/dev/null
)
