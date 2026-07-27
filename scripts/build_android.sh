#!/bin/sh
set -eu

project_dir=$(CDPATH='' cd -P -- "$(dirname -- "$0")/.." && pwd -P)
build_root=${SECURE_STORAGE_BUILD_ROOT:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/secure-storage-build}
addon_dir=${SECURE_STORAGE_ADDON_DIR:-$project_dir/addon}
android_sdk=${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}
java_version_expected=${JAVA_VERSION:-17}
android_platform_api=${ANDROID_PLATFORM_API:-36}
android_build_tools_version=${ANDROID_BUILD_TOOLS_VERSION:-36.0.0}

remove_path() {
    remove_target=$1
    if [ -e "$remove_target" ] || [ -L "$remove_target" ]; then
        find "$remove_target" -depth -delete
    fi
}

mkdir -p "$build_root" "$addon_dir"
build_root=$(CDPATH='' cd -P -- "$build_root" && pwd -P)
addon_dir=$(CDPATH='' cd -P -- "$addon_dir" && pwd -P)
case "$build_root" in
    "$project_dir"|"$project_dir"/*)
        echo "SECURE_STORAGE_BUILD_ROOT 必须位于仓库外：$build_root" >&2
        exit 1
        ;;
esac
case "$addon_dir" in
    /|"$project_dir")
        echo "SECURE_STORAGE_ADDON_DIR 不能是文件系统或仓库根目录：$addon_dir" >&2
        exit 1
        ;;
esac

for required_command in java python3 unzip; do
    if ! command -v "$required_command" >/dev/null 2>&1; then
        echo "Android 构建缺少命令：$required_command" >&2
        exit 1
    fi
done
java_major=$(java -version 2>&1 |
    awk -F '"' '/version "/ { split($2, parts, "."); print parts[1]; exit }')
if [ "$java_major" != "$java_version_expected" ]; then
    echo "Android 构建需要 JDK $java_version_expected，当前 major 为：${java_major:-未知}" >&2
    exit 1
fi
if [ -z "$android_sdk" ] || [ ! -d "$android_sdk" ]; then
    echo "必须通过 ANDROID_SDK_ROOT 或 ANDROID_HOME 指定 Android SDK。" >&2
    exit 1
fi
if [ ! -f "$android_sdk/platforms/android-$android_platform_api/android.jar" ]; then
    echo "Android SDK 缺少 platform android-$android_platform_api。" >&2
    exit 1
fi
if [ ! -d "$android_sdk/build-tools/$android_build_tools_version" ]; then
    echo "Android SDK 缺少 Build Tools $android_build_tools_version。" >&2
    exit 1
fi
if [ ! -x "$project_dir/android/gradlew" ]; then
    echo "android/gradlew 不存在或不可执行。" >&2
    exit 1
fi

gradle_output="$build_root/gradle-build"
gradle_project_cache="$build_root/gradle-project-cache"
gradle_user_home="$build_root/gradle-home"
kotlin_project_dir="$build_root/kotlin-project"
stage_dir="$build_root/stage/android"
remove_path "$stage_dir"
mkdir -p \
    "$gradle_output" \
    "$gradle_project_cache" \
    "$gradle_user_home" \
    "$kotlin_project_dir" \
    "$stage_dir/debug" \
    "$stage_dir/release"

SECURE_STORAGE_BUILD_ROOT="$build_root" \
GRADLE_USER_HOME="$gradle_user_home" \
    "$project_dir/android/gradlew" \
    --no-daemon \
    -p "$project_dir/android" \
    --project-cache-dir "$gradle_project_cache" \
    -PsecureStorageBuildRoot="$gradle_output" \
    -Pkotlin.project.persistent.dir="$kotlin_project_dir" \
    :plugin:assembleDebug \
    :plugin:assembleRelease

validate_aar() {
    validation_variant=$1
    validation_aar=$2
    validation_dir="$build_root/aar-validation-$validation_variant"
    remove_path "$validation_dir"
    mkdir -p "$validation_dir"

    for validation_entry in AndroidManifest.xml classes.jar; do
        if ! unzip -Z1 "$validation_aar" | grep -Fqx "$validation_entry"; then
            echo "Android $validation_variant AAR 缺少 $validation_entry。" >&2
            exit 1
        fi
    done
    unzip -q "$validation_aar" -d "$validation_dir"
    if ! unzip -Z1 "$validation_dir/classes.jar" |
        grep -Fqx 'com/marcellgu/securestorage/AndroidBackend.class'; then
        echo "Android $validation_variant AAR 缺少 AndroidBackend.class。" >&2
        exit 1
    fi
    if unzip -Z1 "$validation_aar" | grep -Eq '(^|/)jni/|(^|/).*\.so$'; then
        echo "Android AAR 不得包含 JNI、NDK 或 GDExtension 共享库。" >&2
        exit 1
    fi

    python3 - "$validation_dir/AndroidManifest.xml" <<'PY'
import sys
import xml.etree.ElementTree as ET

android = "{http://schemas.android.com/apk/res/android}"
root = ET.parse(sys.argv[1]).getroot()
uses_sdk = root.find("uses-sdk")
if uses_sdk is None or uses_sdk.get(android + "minSdkVersion") != "24":
    raise SystemExit("Android AAR manifest 必须声明 minSdkVersion=24。")
application = root.find("application")
if application is None:
    raise SystemExit("Android AAR manifest 缺少 application。")
matches = [
    element
    for element in application.findall("meta-data")
    if element.get(android + "name") == "org.godotengine.plugin.v2.AndroidBackend"
    and element.get(android + "value")
    == "com.marcellgu.securestorage.AndroidBackend"
]
if len(matches) != 1:
    raise SystemExit("Android AAR 的 Godot Plugin v2 元数据无效。")
PY
}

for variant in debug release; do
    source_aar="$gradle_output/plugin/outputs/aar/plugin-$variant.aar"
    if [ ! -f "$source_aar" ]; then
        echo "Gradle 构建缺少 $variant AAR：$source_aar" >&2
        exit 1
    fi
    validate_aar "$variant" "$source_aar"
    case "$variant" in
        debug) target_aar="$stage_dir/debug/SecureStorage-debug.aar" ;;
        release) target_aar="$stage_dir/release/SecureStorage-release.aar" ;;
    esac
    cp "$source_aar" "$target_aar"
done

mkdir -p "$addon_dir/bin"
destination="$addon_dir/bin/android"
replacement="$addon_dir/bin/.android.new.$$"
remove_path "$replacement"
cp -R "$stage_dir" "$replacement"
remove_path "$destination"
mv "$replacement" "$destination"

printf '已生成 %s\n' "$destination"
