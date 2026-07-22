#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
build_root=${SECURE_STORAGE_BUILD_ROOT:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/secure-storage-build}
SCONS_CACHE=${SCONS_CACHE:-$build_root/scons-cache}
export SCONS_CACHE
host=$(uname -s)
case "$host" in
    Darwin) default_platform=macos; default_arch=arm64 ;;
    Linux) default_platform=linux; default_arch=x86_64 ;;
    MINGW*|MSYS*|CYGWIN*) default_platform=windows; default_arch=x86_64 ;;
    *) echo "无法识别当前构建平台：$host" >&2; exit 1 ;;
esac

platform=${1:-$default_platform}
target=${2:-template_debug}
arch=${3:-$default_arch}
case "$platform" in macos|ios|windows|linux|android) ;; *) echo "不支持的平台：$platform" >&2; exit 1 ;; esac
case "$target" in template_debug|template_release) ;; *) echo "不支持的目标：$target" >&2; exit 1 ;; esac
case "$arch" in arm64|x86_64|universal) ;; *) echo "不支持的架构：$arch" >&2; exit 1 ;; esac
case "$platform" in ios|android) arch=arm64 ;; esac

"$project_dir/scripts/bootstrap.sh" >/dev/null
deps_dir="$build_root/deps"
work_dir="$build_root/work/$platform-$target-$arch"
object_dir="$build_root/obj/$platform-$target-$arch"
sconsign_dir="$build_root/sconsign"
sconsign_file="$sconsign_dir/$platform-$target-$arch.dblite"
if [ -d "$work_dir" ]; then
    find "$work_dir" -mindepth 1 -depth -delete
fi
mkdir -p "$work_dir" "$work_dir/.deps" "$work_dir/addons/SecureStorage" "$object_dir" "$sconsign_dir" "$SCONS_CACHE"
cp -R "$project_dir/src/native" "$project_dir/src/addon" "$project_dir/src/android" "$work_dir/"
cp "$project_dir/src/SConstruct" "$project_dir/src/project.godot" "$work_dir/"
cp -R "$project_dir/tests" "$work_dir/"
ln -s "$deps_dir/godot-cpp" "$work_dir/.deps/godot-cpp"
cp "$deps_dir/extension_api_4.7.1.json" "$work_dir/.deps/extension_api_4.7.1.json"

run_scons() {
    (
        cd "$work_dir"
        scons platform="$platform" arch="$arch" target="$target" \
            custom_api_file="$work_dir/.deps/extension_api_4.7.1.json" \
            godot_cpp_dir="$work_dir/.deps/godot-cpp" build_dir="$object_dir" \
            sconsign_file="$sconsign_file"
    )
}

case "$platform" in
    macos|windows|linux)
        run_scons
        ;;
    ios)
        run_scons
        output_dir="$work_dir/addons/SecureStorage/bin/ios"
        mkdir -p "$output_dir"
        xcodebuild -create-xcframework \
            -library "$object_dir/ios/libsecure_storage.ios.$target.a" \
            -output "$output_dir/libsecure_storage.ios.$target.xcframework"
        xcodebuild -create-xcframework \
            -library "$deps_dir/godot-cpp/bin/libgodot-cpp.ios.$target.arm64.a" \
            -output "$output_dir/libgodot-cpp.ios.$target.xcframework"
        ;;
    android)
        scons -C "$deps_dir/godot-cpp" platform=android arch=arm64 target="$target" \
            custom_api_file="$deps_dir/extension_api_4.7.1.json"
        if [ "$target" = template_release ]; then
            gradle_task=:plugin:assembleRelease
            aar_source="$work_dir/android/plugin/build/outputs/aar/plugin-release.aar"
            aar_target="$work_dir/addons/SecureStorage/bin/android/release/SecureStorage-release.aar"
        else
            gradle_task=:plugin:assembleDebug
            aar_source="$work_dir/android/plugin/build/outputs/aar/plugin-debug.aar"
            aar_target="$work_dir/addons/SecureStorage/bin/android/debug/SecureStorage-debug.aar"
        fi
        GRADLE_USER_HOME="$build_root/gradle-home" "$work_dir/android/gradlew" -p "$work_dir/android" "$gradle_task"
        mkdir -p "$(dirname -- "$aar_target")"
        cp "$aar_source" "$aar_target"
        ;;
esac

mkdir -p "$project_dir/addons/SecureStorage"
cp -R "$work_dir/addons/SecureStorage/." "$project_dir/addons/SecureStorage/"
printf '已生成 %s\n' "$project_dir/addons/SecureStorage"
