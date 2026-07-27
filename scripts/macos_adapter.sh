#!/bin/sh

# 本文件由 scripts/test.sh source，变量由公共驱动提供。
# shellcheck disable=SC2034,SC2154

adapter_label=macOS
allow_expected_platform_error=${SECURE_STORAGE_TEST_ALLOW_EXPECTED_PLATFORM_ERROR:-0}
apple_access_group=${SECURE_STORAGE_APPLE_ACCESS_GROUP:-}
if [ "${GITHUB_ACTIONS:-}" = true ]; then
	allow_expected_platform_error=1
	apple_access_group=TESTTEAM00.com.marcellgu.testsecurestorage
fi

adapter_validate_environment() {
	case "$allow_expected_platform_error" in
		0|1) ;;
		*)
			echo "SECURE_STORAGE_TEST_ALLOW_EXPECTED_PLATFORM_ERROR 必须为 0 或 1。" >&2
			exit 1
			;;
	esac
	case "$apple_access_group" in
		''|*[!A-Za-z0-9.-]*)
			echo "SECURE_STORAGE_APPLE_ACCESS_GROUP 必须是非空的 Apple access group 标识。" >&2
			exit 1
			;;
	esac
	if [ "$(uname -s)" != Darwin ]; then
		echo "macOS E2E 只能在 macOS 上运行。" >&2
		exit 1
	fi
	command -v codesign >/dev/null 2>&1 || {
		echo "缺少 macOS E2E 依赖：codesign" >&2
		exit 1
	}
}

adapter_validate_candidate() {
	for target in template_debug template_release; do
		test -d "$addon_dir/bin/macos/libsecure_storage.macos.$target.framework"
	done
}

adapter_configure_project() {
	macos_configured_project="$stage/project.godot.configured"
	sed "s|^apple_access_group=.*$|apple_access_group=\"$apple_access_group\"|" \
		"$stage/project.godot" >"$macos_configured_project"
	mv "$macos_configured_project" "$stage/project.godot"
	grep -Fqx "apple_access_group=\"$apple_access_group\"" "$stage/project.godot"
}

adapter_export() {
	macos_app="$stage/output/$variant/TestSecureStorage.app"
	mkdir -p "$(dirname -- "$macos_app")"
	if ! "$godot_bin" --headless --path "$stage" "$export_flag" \
		macOS "$macos_app" >"$export_log" 2>&1; then
		return 1
	fi
	codesign --verify --deep --strict "$macos_app" || return 1
	macos_binary="$macos_app/Contents/MacOS/TestSecureStorage"
	test -x "$macos_binary"
}

adapter_run() {
	SECURE_STORAGE_TEST_PHASE="$phase_override" \
		"$macos_binary" --headless >"$primary_log" 2>"$secondary_log" &
	macos_run_pid=$!
	macos_elapsed=0
	while kill -0 "$macos_run_pid" 2>/dev/null; do
		if [ "$macos_elapsed" -ge "$test_timeout" ]; then
			kill -TERM "$macos_run_pid" 2>/dev/null || true
			wait "$macos_run_pid" 2>/dev/null || true
			return 124
		fi
		sleep 1
		macos_elapsed=$((macos_elapsed + 1))
	done
	macos_status=0
	wait "$macos_run_pid" || macos_status=$?
	return "$macos_status"
}

adapter_accept_expected_error() {
	[ "$phase" = write ] &&
		[ "$allow_expected_platform_error" -eq 1 ] &&
		[ "$run_status" -eq 1 ] &&
		[ "$(grep -Fc "$error_prefix" "$primary_log" || true)" -eq 1 ] &&
		[ "$(grep -Fc 'TEST_SECURE_STORAGE ' "$primary_log" || true)" -eq 1 ] &&
		grep -F "$error_prefix" "$primary_log" | grep -Fq '(-34018)' &&
		! grep -Eq 'TEST_SECURE_STORAGE result=FAIL|ASSERTION_FAILED' \
			"$primary_log" "$secondary_log" &&
		! grep -Eq \
			'SCRIPT ERROR|Parse Error|ERROR:|Segmentation fault|Abort trap|SIG(SEGV|ABRT|BUS|ILL)' \
			"$primary_log" "$secondary_log"
}

adapter_check_diagnostics() {
	! grep -Eq 'SCRIPT ERROR|Parse Error|ERROR:' "$primary_log" "$secondary_log"
}

adapter_expected_marker_count() {
	grep -Fxc "$expected_marker" "$primary_log" || true
}
