#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$BASH_SOURCE")/../.." && pwd)"
LOCK="$ROOT/OpenDDE/sdaa/source.sdaa.lock"
get_pin() {
    sed -n "s/^$1=//p" "$LOCK"
}
REPOSITORY="$(get_pin kalign_source_repository)"
TAG="$(get_pin kalign_source_tag)"
COMMIT="$(get_pin kalign_source_commit)"
EXPECTED_SHA="$(get_pin kalign_binary_sha256)"
EXPECTED_GCC="$(get_pin kalign_build_gcc)"
EXPECTED_CMAKE="$(get_pin kalign_build_cmake)"

actual_gcc="$(gcc -dumpfullversion)"
actual_cmake="$(cmake --version | sed -nE '1s/.*version ([0-9.]+).*/\1/p')"
[[ "$actual_gcc" == "$EXPECTED_GCC" ]] || {
    echo "GCC mismatch: expected $EXPECTED_GCC, found $actual_gcc" >&2
    exit 1
}
[[ "$actual_cmake" == "$EXPECTED_CMAKE" ]] || {
    echo "CMake mismatch: expected $EXPECTED_CMAKE, found $actual_cmake" >&2
    exit 1
}

SRC="$ROOT/work/sdaa/build/kalign-src"
BUILD="$ROOT/work/sdaa/build/kalign-build"
PREFIX="$ROOT/work/sdaa/build/kalign-install"
VENDOR="$ROOT/vendor/kalign-3.6.0"
mkdir -p "$ROOT/work/sdaa/build" "$ROOT/work/sdaa/logs"

if [[ ! -d "$SRC/.git" ]]; then
    git clone --depth 1 --branch "$TAG" "$REPOSITORY" "$SRC"
fi
actual_commit="$(git -C "$SRC" rev-parse HEAD)"
[[ "$actual_commit" == "$COMMIT" ]] || {
    echo "Kalign source mismatch: expected $COMMIT, found $actual_commit" >&2
    exit 1
}

cmake -S "$SRC" -B "$BUILD"     -DCMAKE_BUILD_TYPE=Release     -DCMAKE_INSTALL_PREFIX="$PREFIX"     -DBUILD_SHARED_LIBS=OFF     -DENABLE_SSE=OFF     -DENABLE_AVX=OFF     -DENABLE_AVX2=OFF     -DUSE_THREADPOOL=ON     2>&1 | tee "$ROOT/work/sdaa/logs/kalign-configure.log"
cmake --build "$BUILD" --parallel 8     2>&1 | tee "$ROOT/work/sdaa/logs/kalign-build.log"
cmake --install "$BUILD"     2>&1 | tee "$ROOT/work/sdaa/logs/kalign-install.log"

install -D -m 0755 "$PREFIX/bin/kalign" "$VENDOR/bin/kalign"
install -D -m 0644 "$SRC/COPYING" "$VENDOR/LICENSE"
actual_sha="$(sha256sum "$VENDOR/bin/kalign" | awk '{print $1}')"
[[ "$actual_sha" == "$EXPECTED_SHA" ]] || {
    echo "Kalign binary checksum mismatch: expected $EXPECTED_SHA, found $actual_sha" >&2
    exit 1
}
[[ "$("$VENDOR/bin/kalign" --version)" == "kalign 3.6.0" ]]
printf 'Kalign %s built from %s (%s/%s); sha256=%s\n' "$TAG" "$COMMIT" "$actual_gcc" "$actual_cmake" "$actual_sha"
