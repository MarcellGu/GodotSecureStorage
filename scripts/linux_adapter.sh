#!/bin/sh

# 本文件由 scripts/test.sh source，变量由公共驱动提供。
# shellcheck disable=SC2016,SC2034,SC2154

adapter_label=Linux

adapter_validate_environment() {
	if [ "$(uname -s)" != Linux ]; then
		echo "Linux E2E 只能在 Linux 上运行。" >&2
		exit 1
	fi
	for linux_command in dbus-run-session gnome-keyring-daemon openssl timeout; do
		command -v "$linux_command" >/dev/null 2>&1 || {
			echo "缺少 Linux E2E 依赖：$linux_command" >&2
			exit 1
		}
	done
}

adapter_validate_candidate() {
	for target in template_debug template_release; do
		test -f "$addon_dir/bin/linux/libsecure_storage.linux.$target.x86_64.so"
	done
}

adapter_export() {
	linux_output_dir="$stage/output/$variant"
	mkdir -p "$linux_output_dir"
	linux_executable="$linux_output_dir/TestSecureStorage"
	if ! "$godot_bin" --recovery-mode --verbose --headless \
		--path "$stage" "$export_flag" \
		Linux "$linux_executable" >"$export_log" 2>&1; then
		gdb --batch --return-child-result \
			-ex 'set pagination off' \
			-ex run \
			-ex 'thread apply all backtrace' \
			--args "$godot_bin" --recovery-mode --verbose --headless \
			--path "$stage" "$export_flag" \
			Linux "$linux_executable" >>"$export_log" 2>&1 || true
		return 1
	fi
	test -f "$linux_executable" || return 1
	chmod +x "$linux_executable" || return 1
}

adapter_install() {
	linux_runtime_home="$stage/output/home-$variant"
	linux_runtime_data="$linux_runtime_home/.local/share"
	linux_password_file="$stage/output/keyring-$variant.password"
	mkdir -p "$linux_runtime_home" "$linux_runtime_data"
	chmod 700 "$linux_runtime_home"
	openssl rand -hex 32 >"$linux_password_file"
	chmod 600 "$linux_password_file"
}

adapter_run() {
	linux_runtime_dir="$stage/output/runtime-$variant-$phase"
	mkdir -p "$linux_runtime_dir" || return 1
	chmod 700 "$linux_runtime_dir" || return 1
	SECURE_STORAGE_TEST_PHASE="$phase_override" \
		HOME="$linux_runtime_home" \
		XDG_DATA_HOME="$linux_runtime_data" \
		XDG_RUNTIME_DIR="$linux_runtime_dir" \
		timeout "$test_timeout" dbus-run-session -- sh -eu -c '
			unset GNOME_KEYRING_CONTROL GNOME_KEYRING_PID
			gnome-keyring-daemon --unlock --components=secrets <"$2" >/dev/null
			exec "$1" --headless
		' sh "$linux_executable" "$linux_password_file" \
		>"$primary_log" 2>"$secondary_log"
}

adapter_check_diagnostics() {
	! grep -Eq 'SCRIPT ERROR|Parse Error|ERROR:' "$primary_log" "$secondary_log"
}

adapter_expected_marker_count() {
	grep -Fxc "$expected_marker" "$primary_log" || true
}

adapter_finish_variant() {
	: >"$linux_password_file"
}

adapter_cleanup() {
	if [ -n "${linux_password_file:-}" ] && [ -f "$linux_password_file" ]; then
		: >"$linux_password_file"
	fi
}
