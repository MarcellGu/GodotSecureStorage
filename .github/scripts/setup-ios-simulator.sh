#!/bin/sh
set -eu

sudo xcode-select -s /Applications/Xcode_16.4.app
xcrun simctl create TestSecureStorage-CI \
	com.apple.CoreSimulator.SimDeviceType.iPhone-16 \
	com.apple.CoreSimulator.SimRuntime.iOS-18-5 >"$RUNNER_TEMP/ios-simulator-id"
xcrun simctl boot "$(cat "$RUNNER_TEMP/ios-simulator-id")"
xcrun simctl bootstatus "$(cat "$RUNNER_TEMP/ios-simulator-id")" -b
