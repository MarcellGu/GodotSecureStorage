#!/bin/sh

# 本文件由 scripts/test.sh source，变量由公共驱动提供。
# shellcheck disable=SC2034,SC2154

adapter_label=Android
adb_bin=${ADB_BIN:-adb}
android_package_name=com.marcellgu.testsecurestorage

adapter_validate_environment() {
	for android_command in "$adb_bin" keytool; do
		command -v "$android_command" >/dev/null 2>&1 || {
			echo "缺少 Android E2E 依赖：$android_command" >&2
			exit 1
		}
	done
	"$adb_bin" get-state >/dev/null
	android_device_api=$("$adb_bin" shell getprop ro.build.version.sdk | tr -d '\r')
	if [ "$android_device_api" -lt 24 ]; then
		echo "Android 设备 API 不匹配：最低要求 24，实际 $android_device_api。" >&2
		exit 1
	fi
}

adapter_validate_candidate() {
	test -f "$addon_dir/bin/android/debug/SecureStorage-debug.aar"
	test -f "$addon_dir/bin/android/release/SecureStorage-release.aar"
	for target in template_debug template_release; do
		test -f "$addon_dir/bin/linux/libsecure_storage.linux.$target.x86_64.so"
	done
}

adapter_prepare() {
	android_release_path=${GODOT_ANDROID_KEYSTORE_RELEASE_PATH:-}
	android_release_user=${GODOT_ANDROID_KEYSTORE_RELEASE_USER:-}
	android_release_password=${GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD:-}
	if [ -n "$android_release_path$android_release_user$android_release_password" ]; then
		if [ -z "$android_release_path" ] ||
			[ -z "$android_release_user" ] ||
			[ -z "$android_release_password" ]; then
			echo "Android release keystore 的路径、用户和密码必须同时设置。" >&2
			exit 1
		fi
	else
		android_release_path="$stage/output/test-release.p12"
		android_release_user=securestoragetest
		android_release_password=securestoragetest
		keytool -genkeypair -noprompt \
			-keystore "$android_release_path" \
			-storetype PKCS12 \
			-storepass "$android_release_password" \
			-keypass "$android_release_password" \
			-alias "$android_release_user" \
			-keyalg RSA \
			-keysize 2048 \
			-validity 2 \
			-dname "CN=TestSecureStorage,OU=Test,O=AetherLab,L=Test,ST=Test,C=US" \
			>/dev/null 2>&1
	fi
	export GODOT_ANDROID_KEYSTORE_RELEASE_PATH="$android_release_path"
	export GODOT_ANDROID_KEYSTORE_RELEASE_USER="$android_release_user"
	export GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD="$android_release_password"
}

adapter_export() {
	android_apk="$stage/output/TestSecureStorage-$variant.apk"
	if ! "$godot_bin" --headless --path "$stage" \
		--install-android-build-template "$export_flag" \
		Android "$android_apk" >"$export_log" 2>&1; then
		return 1
	fi
	test -f "$android_apk"
}

adapter_install() {
	"$adb_bin" uninstall "$android_package_name" >/dev/null 2>&1 || true
	"$adb_bin" install -t "$android_apk" >/dev/null
}

android_refresh_logs() {
	"$adb_bin" logcat -d --pid="$android_app_pid" -v raw '*:V' \
		>"$secondary_log" || return 1
	"$adb_bin" logcat -d --pid="$android_app_pid" -v raw \
		'godot:I' 'Godot:I' '*:S' >"$primary_log" || return 1
}

android_classify_result() {
	if grep -Eq 'TEST_SECURE_STORAGE result=FAIL|ASSERTION_FAILED' "$primary_log"; then
		android_result=FAIL
	elif grep -Fq "$expected_marker" "$primary_log"; then
		android_result=PASS
	fi
}

android_verify_activity_finished() {
	android_activity_wait=0
	while [ "$android_activity_wait" -lt 15 ]; do
		if ! "$adb_bin" shell dumpsys activity activities |
			tr -d '\r' |
			grep -Ei "resumedActivity.*$android_package_name" >/dev/null; then
			return 0
		fi
		sleep 1
		android_activity_wait=$((android_activity_wait + 1))
	done
	return 1
}

android_read_entropy_bits() {
	"$adb_bin" shell cat /proc/sys/kernel/random/entropy_avail 2>/dev/null |
		tr -d '\r'
}

android_prepare_random_source() {
	android_is_emulator=$("$adb_bin" shell getprop ro.kernel.qemu 2>/dev/null |
		tr -d '\r')
	if [ "$android_is_emulator" != 1 ] || [ "$android_device_api" -ne 24 ]; then
		return 0
	fi

	# API 24 的干净模拟器快照可能耗尽阻塞池；宿主机播种后仅替换模拟器设备节点。
	if ! "$adb_bin" root >/dev/null; then
		echo "无法以 root 模式准备 Android API 24 模拟器随机源。" >&2
		return 1
	fi
	"$adb_bin" wait-for-device || return 1

	android_random_target=$(
		"$adb_bin" shell readlink /dev/random 2>/dev/null |
			tr -d '\r'
	)
	case "$android_random_target" in
	/dev/urandom) ;;
	'')
		if ! "$adb_bin" shell \
			'test -c /dev/random &&
				mv /dev/random /dev/random.blocking &&
				ln -s /dev/urandom /dev/random'; then
			echo "无法替换 Android API 24 模拟器的阻塞随机设备。" >&2
			return 1
		fi
		;;
	*)
		echo "Android API 24 模拟器随机设备目标异常：$android_random_target" >&2
		return 1
		;;
	esac

	if [ "$("$adb_bin" shell readlink /dev/random 2>/dev/null | tr -d '\r')" != /dev/urandom ]; then
		echo "Android API 24 模拟器随机设备替换校验失败。" >&2
		return 1
	fi
	if ! dd if=/dev/urandom bs=64 count=1 2>/dev/null |
		"$adb_bin" shell 'cat > /dev/urandom'; then
		echo "无法使用宿主机随机源播种 Android API 24 模拟器。" >&2
		return 1
	fi

	android_entropy_bits=$(android_read_entropy_bits)
	echo "Android API 24 模拟器已使用宿主机随机源播种；内核熵余量 ${android_entropy_bits:-未知} bits。"
}

android_capture_failure_diagnostics() {
	{
		printf '%s\n' '----- kernel entropy -----'
		"$adb_bin" shell cat /proc/sys/kernel/random/entropy_avail |
			tr -d '\r'
		printf '%s\n' '----- process file descriptors -----'
		"$adb_bin" shell run-as "$android_package_name" \
			ls -l "/proc/$android_app_pid/fd" |
			tr -d '\r'
		printf '%s\n' '----- native thread states -----'
		android_thread_ids=$(
			"$adb_bin" shell run-as "$android_package_name" \
				ls "/proc/$android_app_pid/task" 2>/dev/null |
				tr -d '\r'
		)
		for android_thread_id in $android_thread_ids; do
			case "$android_thread_id" in
			''|*[!0-9]*) continue ;;
			esac
			printf '%s\n' "----- thread tid=$android_thread_id -----"
			"$adb_bin" shell run-as "$android_package_name" \
				cat "/proc/$android_app_pid/task/$android_thread_id/status" |
				tr -d '\r' |
				sed -n \
					-e '/^Name:/p' \
					-e '/^State:/p' \
					-e '/^Tgid:/p' \
					-e '/^Pid:/p' \
					-e '/^PPid:/p' \
					-e '/^TracerPid:/p' \
					-e '/^Threads:/p' \
					-e '/^voluntary_ctxt_switches:/p' \
					-e '/^nonvoluntary_ctxt_switches:/p'
			for android_thread_file in wchan syscall stack; do
				printf '[%s]\n' "$android_thread_file"
				"$adb_bin" shell run-as "$android_package_name" \
					cat "/proc/$android_app_pid/task/$android_thread_id/$android_thread_file" |
					tr -d '\r'
				printf '\n'
			done
		done
		printf '%s\n' '----- Java thread dump request -----'
		"$adb_bin" shell run-as "$android_package_name" \
			kill -3 "$android_app_pid"
		sleep 2
		printf '%s\n' '----- Java thread dump logcat -----'
		"$adb_bin" logcat -d --pid="$android_app_pid" -v threadtime '*:V' |
			tail -n 800
		printf '%s\n' '----- Java thread dump file -----'
		"$adb_bin" shell cat /data/anr/traces.txt | tail -n 800
		printf '%s\n' '----- complete logcat tail -----'
		"$adb_bin" logcat -d -v threadtime '*:V' | tail -n 400
		printf '%s\n' '----- activity state -----'
		"$adb_bin" shell dumpsys activity activities | sed -n '1,240p'
		printf '%s\n' '----- package processes -----'
		"$adb_bin" shell ps -A | grep -F "$android_package_name"
	} >>"$secondary_log" 2>&1 || true
}

adapter_run() {
	"$adb_bin" shell am force-stop "$android_package_name" || return 1
	android_prepare_random_source || return 1
	"$adb_bin" logcat -c || return 1
	android_launch_log="$stage/output/launch-$variant-$phase.log"
	if ! "$adb_bin" shell monkey -p "$android_package_name" \
		-c android.intent.category.LAUNCHER 1 >"$android_launch_log" 2>&1; then
		sed -n '1,240p' "$android_launch_log" >&2
		return 1
	fi

	android_app_pid=
	android_pid_wait=0
	while [ "$android_pid_wait" -lt 100 ]; do
		android_app_pid=$("$adb_bin" shell pidof "$android_package_name" 2>/dev/null |
			tr -d '\r' |
			awk '{ print $1 }')
		if [ -n "$android_app_pid" ]; then
			break
		fi
		sleep 0.1
		android_pid_wait=$((android_pid_wait + 1))
	done
	if [ -z "$android_app_pid" ]; then
		sed -n '1,240p' "$android_launch_log" >&2
		return 1
	fi

	android_elapsed=0
	android_result=
	while [ "$android_elapsed" -lt "$test_timeout" ]; do
		android_refresh_logs || return 1
		android_classify_result
		if [ "$android_result" = FAIL ] || [ "$android_result" = PASS ]; then
			break
		fi
		if ! "$adb_bin" shell pidof "$android_package_name" 2>/dev/null |
			grep -q '[0-9]'; then
			android_result=EXITED
			break
		fi
		sleep 1
		android_elapsed=$((android_elapsed + 1))
	done

	# 关闭最后一次 logcat 快照与进程退出之间的竞态。
	android_refresh_logs || return 1
	android_classify_result
	android_activity_verified=false
	if [ "$android_result" = PASS ]; then
		if android_verify_activity_finished; then
			android_activity_verified=true
		else
			android_result=STILL_RUNNING
		fi
	fi

	# 再次刷新时 FAIL 优先；迟到的 PASS 仍必须完成 Activity 退出检查。
	android_refresh_logs || return 1
	if grep -Eq 'TEST_SECURE_STORAGE result=FAIL|ASSERTION_FAILED' "$primary_log"; then
		android_result=FAIL
	elif grep -Fq "$expected_marker" "$primary_log" &&
		[ "$android_result" != STILL_RUNNING ]; then
		android_result=PASS
	fi
	if [ "$android_result" = PASS ] && [ "$android_activity_verified" != true ]; then
		if android_verify_activity_finished; then
			android_activity_verified=true
		else
			android_result=STILL_RUNNING
		fi
	fi

	# Activity 终止后读取稳定日志；此后只允许 FAIL 覆盖已确认终态。
	android_refresh_logs || return 1
	if grep -Eq 'TEST_SECURE_STORAGE result=FAIL|ASSERTION_FAILED' "$primary_log"; then
		android_result=FAIL
	fi
	if [ "$android_result" != PASS ]; then
		android_capture_failure_diagnostics
	fi
	"$adb_bin" shell am force-stop "$android_package_name" >/dev/null 2>&1 || true
	[ "$android_result" = PASS ]
}

adapter_check_diagnostics() {
	android_scene_shader_error='ERROR: SceneShaderGLES3: Program linking failed:'
	android_uniform_error='Fragment shader active uniforms exceed GL_MAX_FRAGMENT_UNIFORM_VECTORS (261)'
	android_method_error='ERROR: Method/function failed.'
	android_resize_error='ERROR: Condition "p_size < 0" is true. Returning: ERR_INVALID_PARAMETER'
	android_scene_shader_error_count=$(
		grep -Fxc "$android_scene_shader_error" "$secondary_log" || true
	)
	android_uniform_error_count=$(
		grep -Fxc "$android_uniform_error" "$secondary_log" || true
	)
	android_method_error_count=$(
		grep -Fxc "$android_method_error" "$secondary_log" || true
	)
	android_resize_error_count=$(
		grep -Fxc "$android_resize_error" "$secondary_log" || true
	)

	if [ "$android_is_emulator" = 1 ] &&
		[ "$android_device_api" -eq 24 ] &&
		grep -Eq '^OpenGL API OpenGL ES 3\.0 .*SwiftShader' "$secondary_log" &&
		[ "$android_scene_shader_error_count" -gt 0 ] &&
		[ "$android_scene_shader_error_count" -eq "$android_uniform_error_count" ] &&
		[ "$android_scene_shader_error_count" -eq "$android_method_error_count" ] &&
		{
			[ "$android_resize_error_count" -eq 0 ] ||
				[ "$android_resize_error_count" -eq "$android_scene_shader_error_count" ]
		}; then
		echo "Android API 24 SwiftShader 已匹配 Godot 上游已知的 261 uniforms 诊断；继续检查其他错误。"
		! sed -E \
			-e '/^removeVertexArrayObject: ERROR: [0-9]+ not found in VAO state!$/d' \
			-e '/^ERROR: SceneShaderGLES3: Program linking failed:$/d' \
			-e '/^ERROR: Method\/function failed\.$/d' \
			-e '/^ERROR: Condition "p_size < 0" is true\. Returning: ERR_INVALID_PARAMETER$/d' \
			"$secondary_log" |
			grep -Eq \
				'SCRIPT ERROR|Parse Error|ERROR:|FATAL EXCEPTION|Fatal signal|SIG(SEGV|ABRT|BUS|ILL)|ANR in' \
				-
		return
	fi

	! sed -E \
		'/^removeVertexArrayObject: ERROR: [0-9]+ not found in VAO state!$/d' \
		"$secondary_log" |
	grep -Eq \
			'SCRIPT ERROR|Parse Error|ERROR:|FATAL EXCEPTION|Fatal signal|SIG(SEGV|ABRT|BUS|ILL)|ANR in' \
			-
}

adapter_cleanup() {
	"$adb_bin" shell am force-stop "$android_package_name" >/dev/null 2>&1 || true
}
