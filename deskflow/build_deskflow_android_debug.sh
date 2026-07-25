#!/usr/bin/env bash
set -Eeuo pipefail

FREERDP_VERSION="${FREERDP_VERSION:-3.30.0}"
APP_ID="${APP_ID:-com.zhaoyufeng.deskflow}"
VERSION_NAME="${VERSION_NAME:-0.1.0-test}"
VERSION_CODE="${VERSION_CODE:-100}"
COMPILE_API="${COMPILE_API:-37}"
BUILD_TOOLS_VERSION="${BUILD_TOOLS_VERSION:-37.0.0}"
NDK_VERSION="${NDK_VERSION:-29.0.13113456}"
CMAKE_VERSION="${CMAKE_VERSION:-4.1.2}"
ANDROID_HOME="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-$ANDROID_HOME}"
WORK_ROOT="${RUNNER_TEMP:-$HOME/.cache}/deskflow-android"
SRC_DIR="$WORK_ROOT/FreeRDP-$FREERDP_VERSION"
STUDIO_DIR="$SRC_DIR/client/Android/Studio"
OUTPUT_DIR="${GITHUB_WORKSPACE:-$PWD}/deskflow-output"
FINAL_APK="$OUTPUT_DIR/DeskFlow-v${VERSION_NAME}-arm64-v8a-debug.apk"
LOG="$OUTPUT_DIR/DeskFlow-v${VERSION_NAME}-build.log"

section() {
  echo
  echo "========================================================================"
  echo "$1"
  echo "========================================================================"
}

fail() {
  echo "错误：$*" >&2
  exit 1
}

mkdir -p "$WORK_ROOT" "$OUTPUT_DIR"
exec > >(tee "$LOG") 2>&1

section "1. 验证 GitHub Ubuntu 构建环境"
[ -n "$ANDROID_HOME" ] || fail "ANDROID_HOME 未设置"
SDKMANAGER="$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager"
if [ ! -x "$SDKMANAGER" ]; then
  SDKMANAGER="$(find "$ANDROID_HOME/cmdline-tools" -type f -name sdkmanager | sort | tail -n 1)"
fi
[ -x "$SDKMANAGER" ] || fail "找不到 sdkmanager"
command -v git >/dev/null || fail "缺少 git"
command -v python3 >/dev/null || fail "缺少 python3"
command -v java >/dev/null || fail "缺少 Java"
java -version

section "2. 安装官方 Android SDK/NDK/CMake"
yes | "$SDKMANAGER" --licenses >/dev/null || true
"$SDKMANAGER" \
  "platform-tools" \
  "platforms;android-$COMPILE_API" \
  "build-tools;$BUILD_TOOLS_VERSION" \
  "ndk;$NDK_VERSION" \
  "cmake;$CMAKE_VERSION"

export ANDROID_HOME ANDROID_SDK_ROOT
export ANDROID_NDK_HOME="$ANDROID_HOME/ndk/$NDK_VERSION"
export ANDROID_NDK_ROOT="$ANDROID_NDK_HOME"
export PATH="$ANDROID_HOME/platform-tools:$PATH"

section "3. 获取 FreeRDP 官方源码"
rm -rf "$SRC_DIR"
git clone --depth 1 --branch "$FREERDP_VERSION" \
  https://github.com/FreeRDP/FreeRDP.git "$SRC_DIR"
[ -x "$STUDIO_DIR/gradlew" ] || fail "找不到 FreeRDP Android Gradle 工程"
git -C "$SRC_DIR" describe --tags --exact-match

section "4. 应用 DeskFlow 品牌和 ARM64 配置"
python3 - "$STUDIO_DIR" "$APP_ID" <<'PY'
from pathlib import Path
import re
import sys

studio = Path(sys.argv[1])
app_id = sys.argv[2]

module = studio / "aFreeRDP" / "build.gradle"
text = module.read_text(encoding="utf-8")
text, n = re.subn(
    r'applicationId\s+"com\.freerdp\.afreerdp"',
    f'applicationId "{app_id}"',
    text,
    count=1,
)
if n != 1:
    raise SystemExit("applicationId 修改失败")
module.write_text(text, encoding="utf-8")

strings = studio / "aFreeRDP" / "src" / "main" / "res" / "values" / "strings.xml"
text = strings.read_text(encoding="utf-8")
text, n = re.subn(
    r'(<string\s+name="app_title"[^>]*>).*?(</string>)',
    r'\1DeskFlow\2',
    text,
    count=1,
)
if n != 1:
    raise SystemExit("app_title 修改失败")
strings.write_text(text, encoding="utf-8")

manifest = studio / "aFreeRDP" / "src" / "main" / "AndroidManifest.xml"
text = manifest.read_text(encoding="utf-8")
text = text.replace('android:label="aFreeRDP"', 'android:label="DeskFlow"', 1)
text = text.replace(
    'android:authorities="com.freerdp.afreerdp.fileprovider"',
    f'android:authorities="{app_id}.fileprovider"',
    1,
)
manifest.write_text(text, encoding="utf-8")
PY

cat > "$STUDIO_DIR/release.properties" <<EOF_PROPERTIES
COMPILE_API=$COMPILE_API
TARGET_API=$COMPILE_API
MIN_API=29
TOOLS_VERSION=$BUILD_TOOLS_VERSION
NDK_VERSION=$NDK_VERSION
CMAKE_VERSION=$CMAKE_VERSION
BUILD_UNIVERSAL=false
SPLIT_ENABLED=true
SPLIT_ARCHITECTURES=arm64-v8a
ABI_FILTERS=arm64-v8a
VERSION_NAME=$VERSION_NAME
VERSION_CODE=$VERSION_CODE
CMAKE_ARGUMENTS=-DWITH_FFMPEG=ON;-DWITH_OPENH264=ON;-DWITH_OPUS=ON;-DWITH_WEBP=ON;-DWITH_JPEG=ON;-DWITH_PNG=ON;-DWITH_CJSON=ON;-DWITH_OPENSSL=ON
EOF_PROPERTIES

section "5. 编译 DeskFlow ARM64 Debug APK"
cd "$STUDIO_DIR"
./gradlew --no-daemon --stacktrace --warning-mode all :aFreeRDP:assembleDebug

section "6. 验证并归档 APK"
SOURCE_APK="$(find "$STUDIO_DIR/aFreeRDP/build/outputs/apk" -type f -name '*arm64-v8a*debug*.apk' | sort | tail -n 1)"
if [ -z "$SOURCE_APK" ]; then
  SOURCE_APK="$(find "$STUDIO_DIR/aFreeRDP/build/outputs/apk" -type f -name '*debug*.apk' | sort | tail -n 1)"
fi
[ -f "$SOURCE_APK" ] || fail "没有生成 Debug APK"
install -m 0644 "$SOURCE_APK" "$FINAL_APK"
sha256sum "$FINAL_APK" | tee "$FINAL_APK.sha256"
ls -lh "$FINAL_APK" "$FINAL_APK.sha256"
