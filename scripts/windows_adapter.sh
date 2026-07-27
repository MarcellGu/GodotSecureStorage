#!/bin/sh

# 本文件由 scripts/test.sh source，变量由公共驱动提供。
# shellcheck disable=SC2034,SC2154

adapter_label=Windows

adapter_validate_environment() {
	case "$(uname -s)" in
		MINGW*|MSYS*|CYGWIN*) ;;
		*)
			echo "Windows E2E 只能在 Windows POSIX shell 中运行。" >&2
			exit 1
			;;
	esac
}

adapter_validate_candidate() {
	for target in template_debug template_release; do
		test -f "$addon_dir/bin/windows/secure_storage.windows.$target.x86_64.dll"
	done
}

adapter_export() {
	windows_output_dir="$stage/output/$variant"
	mkdir -p "$windows_output_dir"
	windows_executable="$windows_output_dir/TestSecureStorage.exe"
	if ! "$godot_bin" --recovery-mode --headless --path "$stage" "$export_flag" \
		Windows "$windows_executable" >"$export_log" 2>&1; then
		return 1
	fi
	windows_console_executable="$windows_output_dir/TestSecureStorage.console.exe"
	test -f "$windows_console_executable"
}

adapter_run() {
	SECURE_STORAGE_TEST_PHASE="$phase_override" \
		"$windows_console_executable" --headless >"$primary_log" 2>"$secondary_log" &
	windows_run_pid=$!
	windows_elapsed=0
	while kill -0 "$windows_run_pid" 2>/dev/null; do
		if [ "$windows_elapsed" -ge "$test_timeout" ]; then
			kill -TERM "$windows_run_pid" 2>/dev/null || true
			wait "$windows_run_pid" 2>/dev/null || true
			return 124
		fi
		sleep 1
		windows_elapsed=$((windows_elapsed + 1))
	done
	windows_status=0
	wait "$windows_run_pid" || windows_status=$?
	for windows_log in "$primary_log" "$secondary_log"; do
		tr -d '\r' <"$windows_log" >"$windows_log.normalized" || return 1
		mv "$windows_log.normalized" "$windows_log" || return 1
	done
	return "$windows_status"
}

adapter_check_diagnostics() {
	! grep -Eq 'SCRIPT ERROR|Parse Error|ERROR:' "$primary_log" "$secondary_log"
}

adapter_expected_marker_count() {
	grep -Fxc "$expected_marker" "$primary_log" || true
}
