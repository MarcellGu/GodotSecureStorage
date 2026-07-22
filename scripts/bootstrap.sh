#!/bin/sh
set -eu

godot_bin=${GODOT_BIN:-godot}
build_root=${SECURE_STORAGE_BUILD_ROOT:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/secure-storage-build}
deps_dir="$build_root/deps"
cpp_dir="$deps_dir/godot-cpp"
cpp_commit=${GODOT_CPP_COMMIT:-ba0edfed90512ec64aba51d4295a3e7e30112f86}

version=$($godot_bin --version)
case "$version" in
    4.7.1.*) ;;
    *)
        echo "需要 Godot 4.7.1，当前为：$version" >&2
        exit 1
        ;;
esac

mkdir -p "$deps_dir"
if [ ! -d "$cpp_dir/.git" ]; then
    git init "$cpp_dir"
    git -C "$cpp_dir" remote add origin https://github.com/godotengine/godot-cpp.git
    git -C "$cpp_dir" fetch --depth 1 origin "$cpp_commit"
    git -C "$cpp_dir" checkout --detach FETCH_HEAD
fi

actual_commit=$(git -C "$cpp_dir" rev-parse HEAD)
if [ "$actual_commit" != "$cpp_commit" ]; then
    echo "godot-cpp 提交不匹配：$actual_commit" >&2
    exit 1
fi
if ! git -C "$cpp_dir" diff --quiet --ignore-submodules --; then
    echo "godot-cpp 工作树被修改，请更换干净的 SECURE_STORAGE_BUILD_ROOT。" >&2
    exit 1
fi

if ! command -v scons >/dev/null 2>&1; then
    echo "缺少 SCons 4.10.1。" >&2
    exit 1
fi
scons_version=$(scons --version | sed -n 's/^[[:space:]]*SCons: v\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')
if [ "$scons_version" != "4.10.1" ]; then
    echo "需要 SCons 4.10.1，当前为：${scons_version:-未知}" >&2
    exit 1
fi

api_file="$deps_dir/extension_api_4.7.1.json"
if [ ! -f "$api_file" ]; then
    (
        cd "$deps_dir"
        "$godot_bin" --headless --dump-extension-api
        mv extension_api.json "$api_file"
    )
fi

printf '%s\n' "$build_root"
