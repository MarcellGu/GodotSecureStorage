#!/bin/sh
# shellcheck disable=SC2034,SC2154
set -eu

if [ "$#" -ne 1 ]; then
	echo "用法：$0 <android|ios|linux|macos|windows>" >&2
	exit 1
fi

platform=$1
case "$platform" in
	android|ios|linux|macos|windows) ;;
	*)
		echo "不支持的 E2E 平台：$platform" >&2
		exit 1
		;;
esac

project_dir=$(CDPATH='' cd -P -- "$(dirname -- "$0")/.." && pwd -P)
adapter="$project_dir/scripts/${platform}_adapter.sh"
test -f "$adapter"

adapter_validate_environment() { :; }
adapter_validate_candidate() { :; }
adapter_configure_project() { :; }
adapter_prepare() { :; }
adapter_export() { return 1; }
adapter_install() { :; }
adapter_run() { return 1; }
adapter_accept_expected_error() { return 1; }
adapter_check_diagnostics() { return 1; }
adapter_expected_marker_count() {
	grep -Fc "$expected_marker" "$primary_log" || true
}
adapter_show_logs() {
	sed -n '1,240p' "$primary_log"
	sed -n '1,240p' "$secondary_log"
}
adapter_finish_variant() { :; }
adapter_cleanup() { :; }

# adapter 路径已由上方固定平台白名单解析。
# shellcheck source=/dev/null
. "$adapter"

build_root=${SECURE_STORAGE_BUILD_ROOT:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/secure-storage-build}
godot_bin=${GODOT_BIN:-godot}
godot_version_expected=${GODOT_VERSION:-4.7.1-stable}
test_timeout=${SECURE_STORAGE_TEST_TIMEOUT:-180}
addon_source=${SECURE_STORAGE_ADDON_DIR:-$project_dir/addon}

case "$test_timeout" in
	''|*[!0-9]*)
		echo "SECURE_STORAGE_TEST_TIMEOUT 必须是正整数秒数。" >&2
		exit 1
		;;
	0)
		echo "SECURE_STORAGE_TEST_TIMEOUT 必须大于零。" >&2
		exit 1
		;;
esac

command -v "$godot_bin" >/dev/null 2>&1 || {
	echo "缺少 ${adapter_label} E2E 依赖：$godot_bin" >&2
	exit 1
}
adapter_validate_environment

godot_version=$("$godot_bin" --version | tr -d '\r' | sed -n '1p')
godot_version_runtime=$(printf '%s\n' "$godot_version_expected" | sed 's/-stable$/.stable/')
case "$godot_version" in
	"$godot_version_runtime".*) ;;
	*)
		echo "TestSecureStorage 需要 Godot $godot_version_expected，实际为：$godot_version" >&2
		exit 1
		;;
esac

mkdir -p "$build_root"
build_root=$(CDPATH='' cd -P -- "$build_root" && pwd -P)
case "$build_root" in
	"$project_dir"|"$project_dir"/*)
		echo "SECURE_STORAGE_BUILD_ROOT 必须位于仓库外：$build_root" >&2
		exit 1
		;;
esac

addon_dir=$(CDPATH='' cd -P -- "$addon_source" && pwd -P)
for file in plugin.cfg plugin.gd export_plugin.gd secure_storage.gd secure_storage.gdextension icon.svg; do
	test -f "$addon_dir/$file"
done
adapter_validate_candidate

stage="$build_root/test/$platform"
if [ -d "$stage" ]; then
	find "$stage" -mindepth 1 -depth -delete
fi
mkdir -p "$stage/addons" "$stage/output" "$stage/addon"
: >"$stage/output/.gdignore"
for file in project.godot export_presets.cfg main.tscn main.gd; do
	cp "$project_dir/$file" "$stage/$file"
done
cp -R "$addon_dir/." "$stage/addon/"
adapter_configure_project

trap 'adapter_cleanup' EXIT
trap 'exit 130' HUP INT TERM
adapter_prepare

for variant in debug release; do
	export_log="$stage/output/export-$variant.log"
	if [ "$variant" = debug ]; then
		export_flag=--export-debug
		runtime_variant=DEBUG
	else
		export_flag=--export-release
		runtime_variant=RELEASE
	fi
	if ! adapter_export; then
		tail -n 240 "$export_log" >&2
		exit 1
	fi
	if grep -En 'SCRIPT ERROR|Parse Error|ERROR:' "$export_log"; then
		exit 1
	fi

	adapter_install
	variant_expected_error=0
	for phase in write read; do
		if [ "$phase" = write ]; then
			phase_override=WRITE
			expected_marker="TEST_SECURE_STORAGE phase=WRITE variant=$runtime_variant result=PASS"
		else
			phase_override=READ
			expected_marker="TEST_SECURE_STORAGE variant=$runtime_variant result=PASS"
		fi
		error_prefix="TEST_SECURE_STORAGE variant=$runtime_variant result=ERROR error_type=3 message="
		primary_log="$stage/output/run-$variant-$phase.primary.log"
		secondary_log="$stage/output/run-$variant-$phase.secondary.log"
		: >"$primary_log"
		: >"$secondary_log"

		run_status=0
		adapter_run || run_status=$?
		if adapter_accept_expected_error; then
			adapter_show_logs
			echo "TestSecureStorage ${adapter_label} $variant 已接受 CI ad-hoc 预期平台错误；未执行真实平台持久化 READ。"
			variant_expected_error=1
			break
		fi

		if [ "$run_status" -ne 0 ] ||
			[ "$(adapter_expected_marker_count)" -ne 1 ] ||
			[ "$(grep -Fc 'TEST_SECURE_STORAGE ' "$primary_log" || true)" -ne 1 ] ||
			grep -Eq 'TEST_SECURE_STORAGE result=FAIL|ASSERTION_FAILED' \
				"$primary_log" "$secondary_log" ||
			! adapter_check_diagnostics; then
			adapter_show_logs >&2
			echo "TestSecureStorage ${adapter_label} $variant/$phase 未通过，状态 ${run_status}。" >&2
			exit 1
		fi
		adapter_show_logs
	done
	adapter_finish_variant
	if [ "$variant_expected_error" -eq 1 ]; then
		continue
	fi
done

trap - EXIT HUP INT TERM
adapter_cleanup
