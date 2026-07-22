#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
build_root=${SECURE_STORAGE_BUILD_ROOT:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/secure-storage-build}
godot_bin=${GODOT_BIN:-godot}
mode=${1:-memory}
case "$mode" in memory|real) ;; *) echo "用法：test.sh [memory|real]" >&2; exit 1 ;; esac
skip_build=${SECURE_STORAGE_TEST_SKIP_BUILD:-0}
case "$skip_build" in
    0|1) ;;
    *) echo "SECURE_STORAGE_TEST_SKIP_BUILD 必须为 0 或 1。" >&2; exit 1 ;;
esac
test_timeout=${SECURE_STORAGE_TEST_TIMEOUT:-}
if [ -n "$test_timeout" ] && ! command -v timeout >/dev/null 2>&1; then
    echo "设置 SECURE_STORAGE_TEST_TIMEOUT 时需要 timeout 命令。" >&2
    exit 1
fi

host=$(uname -s)
case "$host" in
    Darwin) platform=macos; arch=arm64 ;;
    Linux) platform=linux; arch=x86_64 ;;
    MINGW*|MSYS*|CYGWIN*) platform=windows; arch=x86_64 ;;
    *) echo "当前系统无法运行测试：$host" >&2; exit 1 ;;
esac

work_dir="$build_root/work/$platform-template_debug-$arch"
if [ "$skip_build" = 0 ]; then
    "$project_dir/scripts/build.sh" "$platform" template_debug "$arch" >/dev/null
elif [ ! -f "$work_dir/project.godot" ] || [ ! -f "$work_dir/addons/SecureStorage/secure_storage.gdextension" ]; then
    echo "找不到预编译测试项目，请先构建 $platform template_debug ${arch}。" >&2
    exit 1
fi
if [ "$platform" = macos ]; then
    test_framework="$work_dir/addons/SecureStorage/bin/macos/libsecure_storage.macos.template_debug.framework"
    codesign --force --sign - --timestamp=none "$test_framework" >/dev/null
    codesign --verify --deep --strict "$test_framework"
fi
output_file=$(mktemp "${TMPDIR:-/tmp}/secure-storage-tests.XXXXXX")
trap 'test ! -f "$output_file" || find "$output_file" -delete' EXIT INT TERM

run_godot() {
    if [ -n "$test_timeout" ]; then
        timeout "$test_timeout" "$godot_bin" "$@"
    else
        "$godot_bin" "$@"
    fi
}

mkdir -p "$work_dir/.godot"
printf '%s\n' 'res://addons/SecureStorage/secure_storage.gdextension' >"$work_dir/.godot/extension_list.cfg"
if [ "$mode" = real ]; then
    if run_godot --headless --path "$work_dir" -- --real >"$output_file" 2>&1; then
        :
    else
        status=$?
        sed -n '1,240p' "$output_file" >&2
        if [ "$status" -eq 124 ] && [ -n "$test_timeout" ]; then
            echo "Godot 真实后端测试超过 ${test_timeout}。" >&2
        else
            echo "Godot 真实后端测试失败。" >&2
        fi
        exit "$status"
    fi
else
    if run_godot --headless --path "$work_dir" >"$output_file" 2>&1; then
        :
    else
        status=$?
        sed -n '1,240p' "$output_file" >&2
        if [ "$status" -eq 124 ] && [ -n "$test_timeout" ]; then
            echo "Godot 内存后端测试超过 ${test_timeout}。" >&2
        else
            echo "Godot 内存后端测试失败。" >&2
        fi
        exit "$status"
    fi
fi

if grep -F 'sample-secret-never-log' "$output_file"; then
    echo "测试日志泄露了秘密样本。" >&2
    exit 1
fi
if grep -En 'SCRIPT ERROR|Parse Error|ERROR:' "$output_file"; then
    echo "Godot 输出包含错误。" >&2
    exit 1
fi
if [ "$mode" = real ]; then
    case "$platform" in
        macos) platform_suite='[SUITE] 真实平台后端统一契约 [macOS]' ;;
        windows) platform_suite='[SUITE] 真实平台后端统一契约 [Windows]' ;;
        linux) platform_suite='[SUITE] 真实平台后端统一契约 [Linux]' ;;
    esac
    if ! grep -F "$platform_suite" "$output_file" >/dev/null; then
        sed -n '1,240p' "$output_file" >&2
        echo "Godot 未执行预期的真实平台后端套件：$platform" >&2
        exit 1
    fi
fi
sed -n '1,240p' "$output_file"
