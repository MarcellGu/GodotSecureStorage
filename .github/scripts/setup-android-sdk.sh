#!/bin/sh
set -eu

test -x "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager"
if ! yes | "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" --licenses >/dev/null; then
	echo "接受 Android SDK licenses 失败。" >&2
	exit 1
fi
"$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" \
	"platforms;android-36" \
	"build-tools;36.0.0" \
	"platform-tools"
