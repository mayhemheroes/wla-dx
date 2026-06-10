#!/usr/bin/env bash
# wla-dx/mayhem/build.sh — build the WLA-DX multi-arch assembler + linker suite as the fuzz target,
# plus a clean normal-flags build of the same binaries for wla-dx's own functional test (mayhem/test.sh).
#
# WLA-DX is a multi-architecture macro assembler (wla-z80, wla-6502, wla-65816, wla-gb, …) + a linker
# (wlalink), built with CMake. Each wla-<arch> binary PARSES an attacker-controlled assembly source
# file and assembles it to an object file — the whole front end (scanner, preprocessor, parser, macro
# expansion, phase_1..phase_4, instruction encoding) runs on the input. That's the natural fuzz surface:
# a FILE-INPUT (CLI) target `wla-<arch> -o <out.o> <asm-file>`, no libFuzzer harness. The old integration
# fuzzed `wla-z80` on a `.s` file; we preserve that target name (wla-z80) and add wla-6502.
#
# Two builds from two separate CMake build dirs:
#   (1) NORMAL-flags build  -> build-tests/binaries/wla-*   (honest oracle for test.sh; no sanitizer noise)
#   (2) SANITIZED build      -> /mayhem/wla-z80, /mayhem/wla-6502  (the fuzz targets; built WITH $SANITIZER_FLAGS)
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs from the ENV, overridable. SANITIZER_FLAGS uses `=` (no colon) on purpose — `=` only fills
# when the var is UNSET, so an explicit EMPTY value (--build-arg SANITIZER_FLAGS=) is honored and builds
# with NO sanitizers (the assembler's natural crash). WLA-DX links libm (CMakeLists adds `m` on UNIX), so
# the empty-sanitizer build links cleanly with no extra flags.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer -g}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}"
: "${MAYHEM_JOBS:=$(nproc)}"
export SANITIZER_FLAGS DEBUG_FLAGS CC MAYHEM_JOBS

cd "$SRC"

# WLA-DX's CMakeLists compiles with `-pedantic-errors -Wall -Wextra -ansi` (warnings only, NOT -Werror
# unless STRICT_ANSI_WARNINGS=ON, which defaults OFF). Adding the sanitizer flags via CMAKE_C_FLAGS does
# not introduce new warnings, so -Werror is not a concern. We append our flags to CMAKE_C_FLAGS and the
# EXE linker flags so BOTH the compile and the link of the instrumented project carry the sanitizer.
# Build type RelWithDebInfo (the project default); $SANITIZER_FLAGS carries -g.

# The two Mayhem fuzz targets (preserve the old wla-z80; add wla-6502 — a second common architecture).
TARGETS=(wla-z80 wla-6502)

# ---------------------------------------------------------------------------
# (1) TEST build — wla-dx's OWN flags, no sanitizer. Builds the WHOLE suite (every wla-* assembler +
#     wlalink), because wla-dx's own regression suite (tests/, driven by run_tests.sh) exercises all
#     architectures and the linker, validating assembled bytes with byte_tester (a known-answer /
#     golden-output oracle — a no-op patch produces wrong bytes and FAILS it). The build lands in
#     build-tests/binaries/; mayhem/test.sh puts that on PATH and runs run_tests.sh.
# ---------------------------------------------------------------------------
rm -rf "$SRC/build-tests"
cmake -S "$SRC" -B "$SRC/build-tests" \
  -DCMAKE_C_COMPILER="$CC" \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo >/dev/null
cmake --build "$SRC/build-tests" -j"$MAYHEM_JOBS"

# ---------------------------------------------------------------------------
# (2) FUZZ build — the PROJECT itself compiled WITH $SANITIZER_FLAGS so the fuzzed code is instrumented
#     (ASan+UBSan, halting, by default). Each wla-<arch> is a file-input Mayhem target at /mayhem/wla-<arch>.
#
#     LeakSanitizer OFF for these targets: wla-* are short-lived assemblers that allocate global/parse
#     buffers and, on many error paths, exit without freeing (they rely on process exit to reclaim
#     memory). LSan (which runs at exit, as part of ASan) would report benign "leaks" on a large fraction
#     of inputs, flooding the fuzzer with spurious crashes and stopping it exploring real memory-safety
#     defects. We disable ONLY leak detection (keeping ASan's heap/stack/global overflow + use-after-free
#     and ALL of UBSan, still halting). Baked into each binary via a weak __asan_default_options so it
#     holds no matter how the binary is launched (fuzzer, standalone, smoke test, Mayhem) — not only when
#     ASAN_OPTIONS is set. (Cohort precedent: cproc — same arena-by-exit compiler pattern.)
# ---------------------------------------------------------------------------
rm -rf "$SRC/build-fuzz"
cmake -S "$SRC" -B "$SRC/build-fuzz" \
  -DCMAKE_C_COMPILER="$CC" \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DCMAKE_C_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS" \
  -DCMAKE_EXE_LINKER_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS" >/dev/null
cmake --build "$SRC/build-fuzz" -j"$MAYHEM_JOBS" --target "${TARGETS[@]}"

# Copy the sanitized assemblers to the /mayhem root (the Mayhemfile target paths).
for t in "${TARGETS[@]}"; do
  cp -f "$SRC/build-fuzz/binaries/$t" "/mayhem/$t"
done

# When ASan is active, relink each target with a weak __asan_default_options override that turns LSan
# off (the override only takes effect if ASan is linked in; when SANITIZER_FLAGS is empty we skip it).
# Relink from CMake's per-target object dir + the override object, reusing the link libraries (-lm).
if printf '%s' "$SANITIZER_FLAGS" | grep -q address; then
  cat > /tmp/asan_opts.c <<'EOF'
/* Disable LeakSanitizer for the wla-* assemblers: they are arena-by-exit (allocate global/parse
   buffers, exit without freeing on many paths), so LSan would report benign leaks on a large
   fraction of inputs. Keeps the rest of ASan + all of UBSan active and halting. */
const char *__asan_default_options(void) { return "detect_leaks=0"; }
EOF
  $CC $SANITIZER_FLAGS $DEBUG_FLAGS -c /tmp/asan_opts.c -o /tmp/asan_opts.o
  for t in "${TARGETS[@]}"; do
    objdir="$SRC/build-fuzz/CMakeFiles/$t.dir"
    mapfile -t objs < <(find "$objdir" -name '*.o' | sort)
    $CC $SANITIZER_FLAGS $DEBUG_FLAGS "${objs[@]}" /tmp/asan_opts.o -lm -o "/mayhem/$t"
  done
fi

echo "build.sh: built sanitized fuzz targets (/mayhem/wla-*) and test oracles (build-tests/binaries/wla-*):"
for t in "${TARGETS[@]}"; do ls -l "/mayhem/$t" "$SRC/build-tests/binaries/$t"; done
