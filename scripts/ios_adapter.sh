#!/bin/sh

# 本文件由 scripts/test.sh source，变量由公共驱动提供。
# shellcheck disable=SC2034,SC2154

adapter_label=iOS
allow_expected_platform_error=${SECURE_STORAGE_TEST_ALLOW_EXPECTED_PLATFORM_ERROR:-0}
apple_access_group=${SECURE_STORAGE_APPLE_ACCESS_GROUP:-}
ios_bundle_id=com.marcellgu.testsecurestorage
ios_team_id=${apple_access_group%%.*}
if [ "${GITHUB_ACTIONS:-}" = true ]; then
	allow_expected_platform_error=1
	apple_access_group=TESTTEAM00.com.marcellgu.testsecurestorage
	ios_team_id=TESTTEAM00
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
	case "$ios_team_id" in
		''|*[!A-Za-z0-9]*)
			echo "Apple access group 必须以字母数字 Team ID 开头。" >&2
			exit 1
			;;
	esac
	case "$apple_access_group" in
		"$ios_team_id".*) ;;
		*)
			echo "Apple access group 必须包含 Team ID 与组名。" >&2
			exit 1
			;;
	esac
	if [ "$(uname -s)" != Darwin ]; then
		echo "iOS E2E 只能在 macOS 上运行。" >&2
		exit 1
	fi
	for ios_command in codesign lipo plutil xcodebuild xcrun; do
		command -v "$ios_command" >/dev/null 2>&1 || {
			echo "缺少 iOS E2E 依赖：$ios_command" >&2
			exit 1
		}
	done
	ios_simulator_id=${SECURE_STORAGE_IOS_SIMULATOR_UDID:-}
	if [ -z "$ios_simulator_id" ]; then
		ios_simulator_id=$(xcrun simctl list devices booted |
			awk -F '[()]' '/Booted/ { print $2; exit }')
	fi
	if [ -z "$ios_simulator_id" ]; then
		echo "没有已启动的 iOS Simulator；请启动一个或设置 SECURE_STORAGE_IOS_SIMULATOR_UDID。" >&2
		exit 1
	fi
}

adapter_validate_candidate() {
	for target in template_debug template_release; do
		test -d "$addon_dir/bin/ios/libsecure_storage.ios.$target.xcframework"
		test -d "$addon_dir/bin/ios/libgodot-cpp.ios.$target.xcframework"
		test -d "$addon_dir/bin/macos/libsecure_storage.macos.$target.framework"
	done
}

adapter_configure_project() {
	ios_configured_project="$stage/project.godot.configured"
	sed "s|^apple_access_group=.*$|apple_access_group=\"$apple_access_group\"|" \
		"$stage/project.godot" >"$ios_configured_project"
	mv "$ios_configured_project" "$stage/project.godot"
	grep -Fqx "apple_access_group=\"$apple_access_group\"" "$stage/project.godot"

	ios_configured_presets="$stage/export_presets.cfg.configured"
	sed "s/application\\/app_store_team_id=\"TESTTEAM00\"/application\\/app_store_team_id=\"$ios_team_id\"/" \
		"$stage/export_presets.cfg" >"$ios_configured_presets"
	mv "$ios_configured_presets" "$stage/export_presets.cfg"
	if ! grep -Fqx "application/app_store_team_id=\"$ios_team_id\"" \
		"$stage/export_presets.cfg"; then
		echo "TestSecureStorage iOS Team ID 注入失败。" >&2
		exit 1
	fi
}

adapter_export() {
	ios_output_dir="$stage/output/$variant"
	mkdir -p "$ios_output_dir"
	ios_export_path="$ios_output_dir/TestSecureStorage.ipa"
	if [ "$variant" = debug ]; then
		ios_configuration=Debug
	else
		ios_configuration=Release
	fi
	if ! "$godot_bin" --headless --path "$stage" "$export_flag" \
		iOS "$ios_export_path" >"$export_log" 2>&1; then
		return 1
	fi

	ios_project="$ios_output_dir/TestSecureStorage.xcodeproj"
	test -d "$ios_project" || return 1
	ios_godot_simulator_library="$ios_output_dir/TestSecureStorage.xcframework/ios-arm64_x86_64-simulator/libgodot.a"
	test -f "$ios_godot_simulator_library" || return 1
	ios_xcode_entitlements="$ios_output_dir/TestSecureStorage/TestSecureStorage.entitlements"
	test -f "$ios_xcode_entitlements" || return 1
	if plutil -extract keychain-access-groups xml1 -o - \
		"$ios_xcode_entitlements" >/dev/null 2>&1; then
		plutil -remove keychain-access-groups "$ios_xcode_entitlements" || return 1
	fi
	if [ "$allow_expected_platform_error" -eq 0 ]; then
		plutil -insert keychain-access-groups \
			-json "[\"$apple_access_group\"]" "$ios_xcode_entitlements" || return 1
		test "$(plutil -extract keychain-access-groups.0 raw -o - \
			"$ios_xcode_entitlements")" = "$apple_access_group" || return 1
	fi

	ios_simulator_architectures=$(lipo -archs "$ios_godot_simulator_library") ||
		return 1
	ios_host_architecture=$(uname -m)
	case " $ios_simulator_architectures " in
		*" $ios_host_architecture "*) ios_simulator_architecture=$ios_host_architecture ;;
		*" x86_64 "*) ios_simulator_architecture=x86_64 ;;
		*" arm64 "*) ios_simulator_architecture=arm64 ;;
		*)
			echo "Godot iOS Simulator 模板没有可用架构：$ios_simulator_architectures" >&2
			return 1
			;;
	esac

	ios_derived_data="$ios_output_dir/DerivedData"
	ios_build_log="$stage/output/xcodebuild-$variant.log"
	if ! xcodebuild \
		-project "$ios_project" \
		-scheme TestSecureStorage \
		-configuration "$ios_configuration" \
		-sdk iphonesimulator \
		-destination "generic/platform=iOS Simulator" \
		-derivedDataPath "$ios_derived_data" \
		CODE_SIGNING_ALLOWED=YES \
		CODE_SIGNING_REQUIRED=YES \
		CODE_SIGN_STYLE=Manual \
		CODE_SIGN_IDENTITY=- \
		DEVELOPMENT_TEAM= \
		ARCHS="$ios_simulator_architecture" \
		ONLY_ACTIVE_ARCH=YES \
		build >"$ios_build_log" 2>&1; then
		sed -n '1,240p' "$ios_build_log" >&2
		return 1
	fi
	ios_app_count=$(find "$ios_derived_data/Build/Products" -maxdepth 2 -type d \
		-name 'TestSecureStorage.app' | wc -l | tr -d ' ')
	if [ "$ios_app_count" -ne 1 ]; then
		echo "iOS $variant 构建结果必须恰好包含一个 TestSecureStorage.app。" >&2
		return 1
	fi
	ios_app=$(find "$ios_derived_data/Build/Products" -maxdepth 2 -type d \
		-name 'TestSecureStorage.app')
	lipo "$ios_app/TestSecureStorage" \
		-verify_arch "$ios_simulator_architecture" || return 1

	codesign --verify --deep --strict "$ios_app" || return 1
	ios_simulated_entitlements_count=$(find \
		"$ios_derived_data/Build/Intermediates.noindex" -type f \
		-name 'TestSecureStorage.app-Simulated.xcent' | wc -l | tr -d ' ')
	if [ "$ios_simulated_entitlements_count" -ne 1 ]; then
		echo "iOS $variant 构建结果必须恰好包含一个 Simulator entitlement。" >&2
		return 1
	fi
	ios_simulated_entitlements=$(find \
		"$ios_derived_data/Build/Intermediates.noindex" -type f \
		-name 'TestSecureStorage.app-Simulated.xcent')
	if [ "$allow_expected_platform_error" -eq 1 ]; then
		if plutil -extract keychain-access-groups xml1 -o - \
			"$ios_simulated_entitlements" >/dev/null 2>&1; then
			echo "iOS CI ad-hoc 宿主不得获得测试 access group entitlement。" >&2
			return 1
		fi
	else
		test "$(plutil -extract keychain-access-groups.0 raw -o - \
			"$ios_simulated_entitlements")" = "$apple_access_group" || return 1
	fi
}

adapter_install() {
	xcrun simctl terminate "$ios_simulator_id" "$ios_bundle_id" >/dev/null 2>&1 || true
	xcrun simctl uninstall "$ios_simulator_id" "$ios_bundle_id" >/dev/null 2>&1 || true
	xcrun simctl install "$ios_simulator_id" "$ios_app"
}

ios_stop_log_streams() {
	if [ -n "${ios_log_pid:-}" ]; then
		kill -TERM "$ios_log_pid" 2>/dev/null || true
		wait "$ios_log_pid" 2>/dev/null || true
		ios_log_pid=
	fi
	if [ -n "${ios_process_log_pid:-}" ]; then
		kill -TERM "$ios_process_log_pid" 2>/dev/null || true
		wait "$ios_process_log_pid" 2>/dev/null || true
		ios_process_log_pid=
	fi
}

adapter_run() {
	ios_stdout_log="$stage/output/run-$variant-$phase.stdout.log"
	ios_stderr_log="$stage/output/run-$variant-$phase.stderr.log"
	ios_launch_log="$stage/output/launch-$variant-$phase.log"
	ios_result=
	: >"$ios_stdout_log" || return 1
	: >"$ios_stderr_log" || return 1
	xcrun simctl spawn "$ios_simulator_id" log stream \
		--style compact \
		--level debug \
		--predicate "process == 'TestSecureStorage'" \
		>"$secondary_log" 2>&1 &
	ios_process_log_pid=$!
	xcrun simctl spawn "$ios_simulator_id" log stream \
		--style compact \
		--level debug \
		--predicate "process == 'TestSecureStorage' && subsystem == '$ios_bundle_id'" \
		>"$primary_log" 2>&1 &
	ios_log_pid=$!
	sleep 1
	if ! SIMCTL_CHILD_SECURE_STORAGE_TEST_PHASE="$phase_override" \
		xcrun simctl launch \
			--terminate-running-process \
			--stdout="$ios_stdout_log" \
			--stderr="$ios_stderr_log" \
			"$ios_simulator_id" "$ios_bundle_id" >"$ios_launch_log" 2>&1; then
		ios_stop_log_streams
		sed -n '1,240p' "$ios_launch_log" >&2
		return 1
	fi

	ios_elapsed=0
	while [ "$ios_elapsed" -lt "$test_timeout" ]; do
		if grep -Eq 'TEST_SECURE_STORAGE result=FAIL|ASSERTION_FAILED' "$primary_log"; then
			ios_result=FAIL
			break
		fi
		if [ "$phase" = write ] &&
			[ "$allow_expected_platform_error" -eq 1 ] &&
			grep -F "$error_prefix" "$primary_log" | grep -Fq '(-34018)' &&
			grep -F "$error_prefix" "$secondary_log" | grep -Fq '(-34018)'; then
			ios_result=EXPECTED_ERROR
			break
		fi
		if grep -Fq "$expected_marker" "$primary_log" &&
			grep -Fq "$expected_marker" "$secondary_log"; then
			ios_result=PASS
			break
		fi
		sleep 1
		ios_elapsed=$((ios_elapsed + 1))
	done
	if [ "$ios_result" = PASS ] || [ "$ios_result" = EXPECTED_ERROR ]; then
		sleep 1
		if ! xcrun simctl terminate \
			"$ios_simulator_id" "$ios_bundle_id" >/dev/null 2>&1; then
			ios_result=TERMINATE_FAILED
		fi
	else
		xcrun simctl terminate "$ios_simulator_id" "$ios_bundle_id" >/dev/null 2>&1 || true
	fi
	ios_stop_log_streams
	[ "$ios_result" = PASS ] || [ "$ios_result" = EXPECTED_ERROR ]
}

adapter_accept_expected_error() {
	[ "${ios_result:-}" = EXPECTED_ERROR ] &&
		[ "$phase" = write ] &&
		[ "$allow_expected_platform_error" -eq 1 ] &&
		[ "$(grep -Fc "$error_prefix" "$primary_log" || true)" -eq 1 ] &&
		[ "$(grep -Fc 'TEST_SECURE_STORAGE ' "$primary_log" || true)" -eq 1 ] &&
		grep -F "$error_prefix" "$primary_log" | grep -Fq '(-34018)' &&
		grep -F "$error_prefix" "$secondary_log" | grep -Fq '(-34018)' &&
		! grep -Eq 'TEST_SECURE_STORAGE result=FAIL|ASSERTION_FAILED' "$primary_log" &&
		! grep -Eq 'SCRIPT ERROR|Parse Error|ERROR:' \
			"$secondary_log" "$ios_stdout_log" "$ios_stderr_log"
}

adapter_check_diagnostics() {
	! grep -Eq 'SCRIPT ERROR|Parse Error|ERROR:' \
		"$secondary_log" "$ios_stdout_log" "$ios_stderr_log"
}

adapter_show_logs() {
	sed -n '1,240p' "$primary_log"
	sed -n '1,240p' "$secondary_log"
	sed -n '1,240p' "$ios_stdout_log"
	sed -n '1,240p' "$ios_stderr_log"
}

adapter_cleanup() {
	ios_stop_log_streams
	if [ -n "${ios_simulator_id:-}" ]; then
		xcrun simctl terminate "$ios_simulator_id" "$ios_bundle_id" >/dev/null 2>&1 || true
	fi
}
