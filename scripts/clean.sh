#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
build_root=${SECURE_STORAGE_BUILD_ROOT:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/secure-storage-build}

addon_dir="$project_dir/addons"
if [ -d "$addon_dir" ]; then
    find "$addon_dir" -mindepth 1 -depth -delete
    rmdir "$addon_dir"
fi
work_dir="$build_root/work"
if [ -d "$work_dir" ]; then
    find "$work_dir" -mindepth 1 -depth -delete
    rmdir "$work_dir"
fi
if [ "${1:-}" = "--all" ] && [ -d "$build_root" ]; then
    case "$build_root" in /|/tmp|"") echo "拒绝清理过宽的目录：$build_root" >&2; exit 1 ;; esac
    find "$build_root" -mindepth 1 -depth -delete
    rmdir "$build_root"
fi
