#!/bin/sh
set -eu

case "${1:-}" in
	prepare-host)
		test -e /dev/kvm
		sudo chmod 0666 /dev/kvm
		test -r /dev/kvm
		test -w /dev/kvm
		;;
	validate-device)
		adb wait-for-device
		test "$(adb shell getprop ro.build.version.sdk | tr -d '\r')" = 24
		test "$(adb shell getprop sys.boot_completed | tr -d '\r')" = 1
		adb emu avd snapshot save default_boot
		test -f "$HOME/.android/avd/test.avd/snapshots/default_boot/snapshot.pb"
		;;
	validate-cache)
		test -f "$HOME/.android/avd/test.ini"
		test -f "$HOME/.android/avd/test.avd/snapshots/default_boot/snapshot.pb"
		test -x "$ANDROID_HOME/emulator/qemu-img"
		for android_snapshot_image in cache.img.qcow2 userdata-qemu.img.qcow2; do
			android_snapshot_path="$HOME/.android/avd/test.avd/$android_snapshot_image"
			test -f "$android_snapshot_path"
			"$ANDROID_HOME/emulator/qemu-img" snapshot -l "$android_snapshot_path" |
				awk '$2 == "default_boot" { found = 1 } END { exit !found }'
		done
		;;
	clear-cache)
		if [ -d "$HOME/.android/avd" ]; then
			find "$HOME/.android/avd" -mindepth 1 -depth -delete
		fi
		;;
	*)
		echo "用法：setup-android-emulator.sh prepare-host|validate-device|validate-cache|clear-cache" >&2
		exit 1
		;;
esac
