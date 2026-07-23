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
apple_bundle_version_pattern='^(0|[1-9][0-9]{0,3})\.(0|[1-9][0-9]?)\.(0|[1-9][0-9]?)$'

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

prepare_macos_framework() {
    framework_name="libsecure_storage.macos.$target"
    framework_dir="$work_dir/addons/SecureStorage/bin/macos/$framework_name.framework"
    framework_plist="$framework_dir/Resources/Info.plist"
    case "$target" in
        template_debug) bundle_variant=debug ;;
        template_release) bundle_variant=release ;;
    esac
    bundle_version=$(awk -F '"' '/^version[[:space:]]*=/{ print $2; exit }' "$work_dir/addon/plugin.cfg")
    if [ -z "$bundle_version" ]; then
        echo "无法从 plugin.cfg 读取 framework 版本。" >&2
        exit 1
    fi
    apple_bundle_version=$(printf '%s\n' "$bundle_version" | sed -nE 's/^([0-9]+\.[0-9]+\.[0-9]+)([.-][0-9A-Za-z.-]+)?$/\1/p')
    if [ -z "$apple_bundle_version" ]; then
        echo "plugin.cfg 版本必须是三段式 SemVer：$bundle_version" >&2
        exit 1
    fi
    if ! printf '%s\n' "$apple_bundle_version" | grep -Eq "$apple_bundle_version_pattern"; then
        echo "framework 版本超出 Apple 限制（major 最多 4 位，minor/patch 最多 2 位，且不得包含前导零）：$apple_bundle_version" >&2
        exit 1
    fi

    mkdir -p "$framework_dir/Resources"
    plutil -create xml1 "$framework_plist"
    plutil -insert CFBundleDevelopmentRegion -string en "$framework_plist"
    plutil -insert CFBundleExecutable -string "$framework_name" "$framework_plist"
    plutil -insert CFBundleIdentifier -string "com.marcellgu.securestorage.macos.$bundle_variant" "$framework_plist"
    plutil -insert CFBundleInfoDictionaryVersion -string 6.0 "$framework_plist"
    plutil -insert CFBundleName -string "$framework_name" "$framework_plist"
    plutil -insert CFBundlePackageType -string FMWK "$framework_plist"
    plutil -insert CFBundleShortVersionString -string "$apple_bundle_version" "$framework_plist"
    plutil -insert CFBundleVersion -string "$apple_bundle_version" "$framework_plist"
    plutil -insert CFBundleSupportedPlatforms -json '["MacOSX"]' "$framework_plist"
    plutil -lint "$framework_plist" >/dev/null
    codesign --force --sign - --timestamp=none "$framework_dir" >/dev/null
}

validate_macos_framework() {
    framework_name="libsecure_storage.macos.$target"
    framework_dir="$project_dir/addons/SecureStorage/bin/macos/$framework_name.framework"
    framework_plist="$framework_dir/Resources/Info.plist"
    test -f "$framework_dir/$framework_name"
    plutil -lint "$framework_plist" >/dev/null
    if [ "$(plutil -extract CFBundleExecutable raw -o - "$framework_plist")" != "$framework_name" ]; then
        echo "framework 的 CFBundleExecutable 与二进制名称不一致。" >&2
        exit 1
    fi
    if [ "$(plutil -extract CFBundlePackageType raw -o - "$framework_plist")" != FMWK ]; then
        echo "framework 的 CFBundlePackageType 无效。" >&2
        exit 1
    fi
    bundle_short_version=$(plutil -extract CFBundleShortVersionString raw -o - "$framework_plist")
    bundle_build_version=$(plutil -extract CFBundleVersion raw -o - "$framework_plist")
    if printf '%s\n%s\n' "$bundle_short_version" "$bundle_build_version" | grep -Eqv "$apple_bundle_version_pattern"; then
        echo "framework 的版本字段不符合 Apple 分段限制。" >&2
        exit 1
    fi
    if ! codesign --verify --deep --strict "$framework_dir"; then
        echo "framework 的 ad-hoc 签名无效。" >&2
        exit 1
    fi
    signature_info=$(codesign --display --verbose=4 "$framework_dir" 2>&1) || {
        echo "framework 缺少 macOS 动态加载所需的 ad-hoc 签名。" >&2
        exit 1
    }
    if ! printf '%s\n' "$signature_info" | grep -Fqx 'Signature=adhoc'; then
        echo "framework 构建产物只能使用不含开发者身份的 ad-hoc 签名。" >&2
        exit 1
    fi
}

case "$platform" in
    macos)
        run_scons
        prepare_macos_framework
        ;;
    windows|linux)
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

cp "$project_dir/LICENSE" "$work_dir/addons/SecureStorage/LICENSE"
mkdir -p "$project_dir/addons/SecureStorage"
if [ "$platform" = macos ]; then
    final_framework="$project_dir/addons/SecureStorage/bin/macos/libsecure_storage.macos.$target.framework"
    if [ -d "$final_framework" ]; then
        find "$final_framework" -depth -delete
    fi
fi
cp -R "$work_dir/addons/SecureStorage/." "$project_dir/addons/SecureStorage/"
if [ "$platform" = macos ]; then
    validate_macos_framework
fi
printf '已生成 %s\n' "$project_dir/addons/SecureStorage"
