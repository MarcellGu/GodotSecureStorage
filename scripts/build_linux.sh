#!/bin/sh
set -eu

project_dir=$(CDPATH='' cd -P -- "$(dirname -- "$0")/.." && pwd -P)
build_root=${SECURE_STORAGE_BUILD_ROOT:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/secure-storage-build}
addon_dir=${SECURE_STORAGE_ADDON_DIR:-$project_dir/addon}
godot_bin=${GODOT_BIN:-godot}
godot_version_expected=${GODOT_VERSION:-4.7.1-stable}
godot_cpp_commit=${GODOT_CPP_COMMIT:-ba0edfed90512ec64aba51d4295a3e7e30112f86}
scons_version_expected=${SCONS_VERSION:-4.10.1}
libsecret_min_version=0.19.0

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

if [ "$(uname -s)" != Linux ]; then
    echo "build_linux.sh 必须在 Linux 运行。" >&2
    exit 1
fi
for required_command in file git nm pkg-config readelf scons; do
    if ! command -v "$required_command" >/dev/null 2>&1; then
        echo "Linux 构建缺少命令：$required_command" >&2
        exit 1
    fi
done
if ! pkg-config --atleast-version="$libsecret_min_version" libsecret-1; then
    actual_libsecret_version=$(pkg-config --modversion libsecret-1 2>/dev/null || true)
    echo \
        "Linux 构建需要 libsecret-1 >= $libsecret_min_version，当前为：${actual_libsecret_version:-未安装}" \
        >&2
    exit 1
fi

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

export SCONS_CACHE="$build_root/scons-cache"
mkdir -p "$SCONS_CACHE" "$build_root/obj" "$build_root/sconsign"
stage_dir="$build_root/stage/linux"
remove_path "$stage_dir"
mkdir -p "$stage_dir"
scons_source_dir="$build_root/work/linux"
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

for target in template_debug template_release; do
    object_dir="$build_root/obj/linux-$target-x86_64"
    sconsign_file="$build_root/sconsign/linux-$target-x86_64.dblite"
    mkdir -p "$object_dir"
    scons -C "$scons_source_dir" \
        platform=linux \
        arch=x86_64 \
        target="$target" \
        custom_api_file="$api_file" \
        godot_cpp_dir=godot-cpp \
        build_dir="$object_dir" \
        output_dir="$stage_dir" \
        sconsign_file="$sconsign_file" \
        repository_dir="$project_dir"

    library="$stage_dir/libsecure_storage.linux.$target.x86_64.so"
    if [ ! -f "$library" ]; then
        echo "Linux 构建缺少共享库：$library" >&2
        exit 1
    fi
    file "$library" | grep -Eq 'ELF 64-bit.*x86-64'
    nm -D --defined-only "$library" | grep -Fq secure_storage_library_init
    if ! readelf -d "$library" | grep -Eq 'NEEDED.*libsecret-1'; then
        echo "Linux 后端必须直接链接 libsecret-1。" >&2
        exit 1
    fi
done

mkdir -p "$addon_dir/bin"
destination="$addon_dir/bin/linux"
replacement="$addon_dir/bin/.linux.new.$$"
remove_path "$replacement"
cp -R "$stage_dir" "$replacement"
remove_path "$destination"
mv "$replacement" "$destination"

printf '已生成 %s\n' "$destination"
