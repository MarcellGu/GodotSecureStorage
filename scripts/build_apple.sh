#!/bin/sh
set -eu

project_dir=$(CDPATH='' cd -P -- "$(dirname -- "$0")/.." && pwd -P)
build_root=${SECURE_STORAGE_BUILD_ROOT:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/secure-storage-build}
addon_dir=${SECURE_STORAGE_ADDON_DIR:-$project_dir/addon}
godot_bin=${GODOT_BIN:-godot}
godot_version_expected=${GODOT_VERSION:-4.7.1-stable}
godot_cpp_commit=${GODOT_CPP_COMMIT:-ba0edfed90512ec64aba51d4295a3e7e30112f86}
scons_version_expected=${SCONS_VERSION:-4.10.1}
apple_bundle_version_pattern='^(0|[1-9][0-9]{0,3})\.(0|[1-9][0-9]?)\.(0|[1-9][0-9]?)$'

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

for required_command in \
    codesign \
    git \
    lipo \
    nm \
    otool \
    plutil \
    scons \
    xcodebuild \
    xcrun; do
    if ! command -v "$required_command" >/dev/null 2>&1; then
        echo "Apple 构建缺少命令：$required_command" >&2
        exit 1
    fi
done

godot_version=$("$godot_bin" --version)
godot_version_core=${godot_version_expected%-stable}
case "$godot_version" in
    "$godot_version_core".*) ;;
    *)
        echo "需要 Godot $godot_version_expected，当前为：$godot_version" >&2
        exit 1
        ;;
esac
scons_version=$(scons --version |
    sed -n 's/^[[:space:]]*SCons: v\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')
if [ "$scons_version" != "$scons_version_expected" ]; then
    echo "需要 SCons $scons_version_expected，当前为：${scons_version:-未知}" >&2
    exit 1
fi

deps_dir="$build_root/deps"
godot_cpp_dir="$deps_dir/godot-cpp"
mkdir -p "$deps_dir"
if [ ! -d "$godot_cpp_dir/.git" ]; then
    git init "$godot_cpp_dir"
    git -C "$godot_cpp_dir" remote add origin https://github.com/godotengine/godot-cpp.git
    fetch_succeeded=false
    for fetch_attempt in 1 2 3 4 5; do
        if git -C "$godot_cpp_dir" fetch --depth 1 origin "$godot_cpp_commit"; then
            fetch_succeeded=true
            break
        fi
        sleep "$fetch_attempt"
    done
    if [ "$fetch_succeeded" != true ]; then
        echo "重试后仍无法取得 godot-cpp：$godot_cpp_commit" >&2
        exit 1
    fi
    git -C "$godot_cpp_dir" checkout --detach FETCH_HEAD
fi
actual_godot_cpp_commit=$(git -C "$godot_cpp_dir" rev-parse HEAD)
if [ "$actual_godot_cpp_commit" != "$godot_cpp_commit" ]; then
    echo "godot-cpp 提交不匹配：$actual_godot_cpp_commit" >&2
    exit 1
fi
godot_cpp_status=$(git -C "$godot_cpp_dir" \
    status --porcelain --untracked-files=all --ignore-submodules=all)
if [ -n "$godot_cpp_status" ]; then
    echo "godot-cpp 工作树被修改，请更换干净的 SECURE_STORAGE_BUILD_ROOT。" >&2
    exit 1
fi

api_file="$deps_dir/extension_api_${godot_version_core}.json"
api_work_dir="$build_root/api-work"
remove_path "$api_work_dir"
mkdir -p "$api_work_dir"
(
    cd "$api_work_dir"
    "$godot_bin" --headless --dump-extension-api
)
test -f "$api_work_dir/extension_api.json"
mv "$api_work_dir/extension_api.json" "$api_file"
remove_path "$api_work_dir"

plugin_cfg="$addon_dir/plugin.cfg"
if [ ! -f "$plugin_cfg" ]; then
    echo "SECURE_STORAGE_ADDON_DIR 缺少 plugin.cfg：$addon_dir" >&2
    exit 1
fi
bundle_version=$(sed -n 's/^version = "\([^"]*\)"$/\1/p' "$plugin_cfg")
apple_bundle_version=$(printf '%s\n' "$bundle_version" |
    sed -nE 's/^([0-9]+\.[0-9]+\.[0-9]+)([.-][0-9A-Za-z.-]+)?$/\1/p')
if [ -z "$apple_bundle_version" ] ||
    ! printf '%s\n' "$apple_bundle_version" | grep -Eq "$apple_bundle_version_pattern"; then
    echo "plugin.cfg version 不符合 Apple 三段式版本限制：${bundle_version:-缺失}" >&2
    exit 1
fi

export SCONS_CACHE="$build_root/scons-cache"
mkdir -p "$SCONS_CACHE" "$build_root/obj" "$build_root/sconsign"
stage_root="$build_root/stage/apple"
remove_path "$stage_root"
mkdir -p "$stage_root/macos" "$stage_root/ios" "$stage_root/raw-ios"
scons_source_dir="$build_root/work/apple"
remove_path "$scons_source_dir"
mkdir -p "$scons_source_dir"
cp "$project_dir"/src/SConstruct \
    "$project_dir"/src/apple.mm \
    "$project_dir"/src/backend.hpp \
    "$project_dir"/src/extension.cpp \
    "$project_dir"/src/linux.cpp \
    "$project_dir"/src/windows.cpp \
    "$scons_source_dir"
git -c advice.detachedHead=false clone --no-hardlinks --quiet \
    "$godot_cpp_dir" "$scons_source_dir/godot-cpp"

run_scons() {
    build_platform=$1
    build_arch=$2
    build_target=$3
    build_output=$4
    build_name=$5
    shift 5
    build_object_dir="$build_root/obj/$build_name"
    build_sconsign="$build_root/sconsign/$build_name.dblite"
    mkdir -p "$build_object_dir" "$build_output"
    scons -C "$scons_source_dir" \
        platform="$build_platform" \
        arch="$build_arch" \
        target="$build_target" \
        custom_api_file="$api_file" \
        godot_cpp_dir=godot-cpp \
        build_dir="$build_object_dir" \
        output_dir="$build_output" \
        sconsign_file="$build_sconsign" \
        repository_dir="$project_dir" \
        "$@"
}

prepare_macos_framework() {
    framework_target=$1
    framework_name="libsecure_storage.macos.$framework_target"
    framework_dir="$stage_root/macos/$framework_name.framework"
    framework_binary="$framework_dir/$framework_name"
    framework_plist="$framework_dir/Resources/Info.plist"
    case "$framework_target" in
        template_debug) bundle_variant=debug ;;
        template_release) bundle_variant=release ;;
        *) echo "未知 macOS target：$framework_target" >&2; exit 1 ;;
    esac

    test -f "$framework_binary"
    mkdir -p "$framework_dir/Resources"
    plutil -create xml1 "$framework_plist"
    plutil -insert CFBundleDevelopmentRegion -string en "$framework_plist"
    plutil -insert CFBundleExecutable -string "$framework_name" "$framework_plist"
    plutil -insert CFBundleIdentifier \
        -string "com.marcellgu.securestorage.macos.$bundle_variant" "$framework_plist"
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
    framework_target=$1
    framework_name="libsecure_storage.macos.$framework_target"
    framework_dir="$stage_root/macos/$framework_name.framework"
    framework_binary="$framework_dir/$framework_name"
    framework_plist="$framework_dir/Resources/Info.plist"

    test -f "$framework_binary"
    plutil -lint "$framework_plist" >/dev/null
    test "$(plutil -extract CFBundleExecutable raw -o - "$framework_plist")" = "$framework_name"
    test "$(plutil -extract CFBundlePackageType raw -o - "$framework_plist")" = FMWK
    codesign --verify --deep --strict "$framework_dir"
    signature_info=$(codesign --display --verbose=4 "$framework_dir" 2>&1)
    printf '%s\n' "$signature_info" | grep -Fqx 'Signature=adhoc'

    framework_arches=$(lipo -archs "$framework_binary")
    case " $framework_arches " in *" arm64 "*) ;; *)
        echo "$framework_name 缺少 arm64 slice。" >&2
        exit 1
    esac
    case " $framework_arches " in *" x86_64 "*) ;; *)
        echo "$framework_name 缺少 x86_64 slice。" >&2
        exit 1
    esac
    test "$(otool -D "$framework_binary" | sed -n '2p')" = \
        "@rpath/$framework_name.framework/$framework_name"
    framework_symbols=$(nm -gU "$framework_binary")
    printf '%s\n' "$framework_symbols" |
        grep -F _secure_storage_library_init >/dev/null
}

validate_ios_xcframework() {
    validation_xcframework=$1
    validation_plist="$validation_xcframework/Info.plist"
    plutil -lint "$validation_plist" >/dev/null
    validation_plist_dump=$(plutil -p "$validation_plist")
    for validation_identifier in ios-arm64 ios-arm64_x86_64-simulator; do
        if ! printf '%s\n' "$validation_plist_dump" |
            grep -Fq "\"LibraryIdentifier\" => \"$validation_identifier\""; then
            echo "XCFramework 缺少 $validation_identifier：$validation_xcframework" >&2
            exit 1
        fi
    done

    validation_device_library=$(find "$validation_xcframework/ios-arm64" \
        -maxdepth 1 -type f -name '*.a')
    validation_simulator_library=$(find "$validation_xcframework/ios-arm64_x86_64-simulator" \
        -maxdepth 1 -type f -name '*.a')
    test "$(printf '%s\n' "$validation_device_library" | grep -c .)" -eq 1
    test "$(printf '%s\n' "$validation_simulator_library" | grep -c .)" -eq 1
    test "$(lipo -archs "$validation_device_library")" = arm64
    validation_simulator_arches=$(lipo -archs "$validation_simulator_library")
    case " $validation_simulator_arches " in *" arm64 "*) ;; *)
        echo "iOS simulator library 缺少 arm64：$validation_simulator_library" >&2
        exit 1
    esac
    case " $validation_simulator_arches " in *" x86_64 "*) ;; *)
        echo "iOS simulator library 缺少 x86_64：$validation_simulator_library" >&2
        exit 1
    esac
}

for target in template_debug template_release; do
    run_scons \
        macos universal "$target" "$stage_root/macos" \
        "macos-$target-universal" \
        macos_deployment_target=10.15
    prepare_macos_framework "$target"
    validate_macos_framework "$target"

    device_output="$stage_root/raw-ios/$target/device"
    simulator_output="$stage_root/raw-ios/$target/simulator"
    run_scons \
        ios arm64 "$target" "$device_output" \
        "ios-$target-arm64" \
        ios_min_version=15.0 \
        ios_simulator=no
    run_scons \
        ios universal "$target" "$simulator_output" \
        "ios-$target-universal-simulator" \
        ios_min_version=15.0 \
        ios_simulator=yes

    device_library="$device_output/libsecure_storage.ios.$target.a"
    simulator_library="$simulator_output/libsecure_storage.ios.$target.simulator.a"
    godot_device_library="$scons_source_dir/godot-cpp/bin/libgodot-cpp.ios.$target.arm64.a"
    godot_simulator_library="$scons_source_dir/godot-cpp/bin/libgodot-cpp.ios.$target.universal.simulator.a"
    for required_library in \
        "$device_library" \
        "$simulator_library" \
        "$godot_device_library" \
        "$godot_simulator_library"; do
        if [ ! -f "$required_library" ]; then
            echo "iOS 构建缺少静态库：$required_library" >&2
            exit 1
        fi
    done

    secure_xcframework="$stage_root/ios/libsecure_storage.ios.$target.xcframework"
    godot_xcframework="$stage_root/ios/libgodot-cpp.ios.$target.xcframework"
    xcodebuild -create-xcframework \
        -library "$device_library" \
        -library "$simulator_library" \
        -output "$secure_xcframework"
    xcodebuild -create-xcframework \
        -library "$godot_device_library" \
        -library "$godot_simulator_library" \
        -output "$godot_xcframework"
    validate_ios_xcframework "$secure_xcframework"
    validate_ios_xcframework "$godot_xcframework"

    secure_device_archive=$(find "$secure_xcframework/ios-arm64" -maxdepth 1 -type f -name '*.a')
    secure_simulator_archive=$(find "$secure_xcframework/ios-arm64_x86_64-simulator" \
        -maxdepth 1 -type f -name '*.a')
    secure_device_symbols=$(nm -gU "$secure_device_archive")
    printf '%s\n' "$secure_device_symbols" |
        grep -F _secure_storage_library_init >/dev/null
    secure_simulator_symbols=$(nm -gU "$secure_simulator_archive")
    printf '%s\n' "$secure_simulator_symbols" |
        grep -F _secure_storage_library_init >/dev/null
done

mkdir -p "$addon_dir/bin"
for apple_platform in macos ios; do
    destination="$addon_dir/bin/$apple_platform"
    replacement="$addon_dir/bin/.$apple_platform.new.$$"
    remove_path "$replacement"
    cp -R "$stage_root/$apple_platform" "$replacement"
    remove_path "$destination"
    mv "$replacement" "$destination"
done

printf '已生成 %s 与 %s\n' "$addon_dir/bin/macos" "$addon_dir/bin/ios"
