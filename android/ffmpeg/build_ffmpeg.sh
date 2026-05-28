#!/bin/bash
# Builds libffmpegJNI.so for all 4 Android ABIs from vendored JNI sources
# (ffmpeg_jni.cc + CMakeLists.txt in this directory) against upstream
# Media3 + FFmpeg cloned into WORK_DIR. Driven entirely by environment
# variables Gradle sets in the buildFfmpegJni task — no user-facing
# flags. Reruns are cheap once WORK_DIR is populated (Gradle UP-TO-DATE
# skips the script entirely when JNI sources haven't changed, and even
# when forced, the FFmpeg static libs are reused if present).
#
# Required env:
#   JNI_SRC      — this directory (vendored ffmpeg_jni.cc + CMakeLists.txt)
#   NDK_PATH     — Android NDK root
#   CMAKE_PATH   — directory containing the cmake + ninja binaries
#   OUTPUT_DIR   — where to drop the final libffmpegJNI.so per ABI
#   WORK_DIR     — scratch directory for upstream clones + intermediate
#                  build artefacts (lives under build/ so a clean wipes it)
#
# License: FFmpeg is LGPL v2.1. We link to it dynamically (consumers
# load libffmpegJNI.so at runtime), keeping the LGPL boundary intact and
# not imposing copyleft on the consuming app. The build below
# intentionally omits --enable-gpl and --enable-nonfree.

set -euo pipefail

: "${JNI_SRC:?JNI_SRC env var not set}"
: "${NDK_PATH:?NDK_PATH env var not set}"
: "${CMAKE_PATH:?CMAKE_PATH env var not set}"
: "${OUTPUT_DIR:?OUTPUT_DIR env var not set}"
: "${WORK_DIR:?WORK_DIR env var not set}"

MEDIA3_TAG="${MEDIA3_TAG:-1.9.2}"
FFMPEG_TAG="${FFMPEG_TAG:-release/6.0}"
ABIS="${ABIS:-armeabi-v7a arm64-v8a x86 x86_64}"
MIN_SDK="${MIN_SDK:-21}"

case "$(uname -s)" in
  Darwin*) HOST_PLATFORM=darwin-x86_64 ;;
  Linux*)  HOST_PLATFORM=linux-x86_64 ;;
  *) echo "Unsupported host: $(uname -s)" >&2; exit 1 ;;
esac

mkdir -p "$WORK_DIR" "$OUTPUT_DIR"
cd "$WORK_DIR"

# 1. Upstream sources — clone once, reuse on subsequent runs.
MEDIA3_DIR="$WORK_DIR/media3"
if [[ ! -d "$MEDIA3_DIR" ]]; then
  echo "[ffmpeg-build] cloning Media3 @${MEDIA3_TAG}"
  git clone --depth 1 --branch "$MEDIA3_TAG" \
    https://github.com/androidx/media.git "$MEDIA3_DIR"
fi

FFMPEG_DIR="$MEDIA3_DIR/libraries/decoder_ffmpeg/src/main/jni/ffmpeg"
if [[ ! -d "$FFMPEG_DIR" ]]; then
  echo "[ffmpeg-build] cloning FFmpeg @${FFMPEG_TAG}"
  git clone --depth 1 --branch "$FFMPEG_TAG" \
    https://git.ffmpeg.org/ffmpeg.git "$FFMPEG_DIR"
fi

# 2. Drop our extended JNI source + CMake config over the upstream copies
#    so the build produces a video-capable libffmpegJNI.so.
JNI_BUILD_DIR="$MEDIA3_DIR/libraries/decoder_ffmpeg/src/main/jni"
cp "$JNI_SRC/ffmpeg_jni.cc" "$JNI_BUILD_DIR/ffmpeg_jni.cc"
cp "$JNI_SRC/CMakeLists.txt" "$JNI_BUILD_DIR/CMakeLists.txt"

# 3. Build FFmpeg static libs per ABI (H.264 decoder only). The
#    sentinel below skips this step if all 4 ABIs already have the
#    static libs from a previous run — important because the FFmpeg
#    static build is the slow part (~30 min for 4 ABIs); subsequent
#    Gradle runs just need to re-link libffmpegJNI.so (~5 sec / ABI).
MODULE_PATH="$MEDIA3_DIR/libraries/decoder_ffmpeg/src/main"
NEED_STATIC_BUILD=0
for ABI in $ABIS; do
  if [[ ! -f "$JNI_BUILD_DIR/ffmpeg/android-libs/$ABI/libavcodec.a" ]]; then
    NEED_STATIC_BUILD=1
    break
  fi
done

if [[ "$NEED_STATIC_BUILD" -eq 1 ]]; then
  echo "[ffmpeg-build] building FFmpeg static libs (slow on first run)"
  chmod +x "$JNI_BUILD_DIR/build_ffmpeg.sh"
  "$JNI_BUILD_DIR/build_ffmpeg.sh" \
    "$MODULE_PATH" "$NDK_PATH" "$HOST_PLATFORM" "$MIN_SDK" h264
else
  echo "[ffmpeg-build] FFmpeg static libs already present, reusing"
fi

# 4. Cross-build libffmpegJNI.so per ABI via CMake + Ninja.
export PATH="$CMAKE_PATH:$PATH"
for ABI in $ABIS; do
  ABI_BUILD_DIR="$WORK_DIR/jni-out/$ABI"
  mkdir -p "$ABI_BUILD_DIR"
  cmake -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$NDK_PATH/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI="$ABI" \
    -DANDROID_PLATFORM="android-$MIN_SDK" \
    -DCMAKE_BUILD_TYPE=Release \
    -S "$JNI_BUILD_DIR" -B "$ABI_BUILD_DIR" >/dev/null
  ninja -C "$ABI_BUILD_DIR" >/dev/null

  DEST="$OUTPUT_DIR/$ABI"
  mkdir -p "$DEST"
  cp "$ABI_BUILD_DIR/libffmpegJNI.so" "$DEST/libffmpegJNI.so"
done

echo "[ffmpeg-build] libffmpegJNI.so ready in $OUTPUT_DIR"
