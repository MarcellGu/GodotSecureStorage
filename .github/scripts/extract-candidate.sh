#!/bin/sh
set -eux

candidate_dir="$RUNNER_TEMP/candidate"
extract_dir="$RUNNER_TEMP/extracted"
archive="$candidate_dir/SecureStorage.zip"
checksum="$candidate_dir/SecureStorage.zip.sha256"

test -d "$candidate_dir"
test "$(find "$candidate_dir" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" -eq 2
test "$(find "$candidate_dir" -maxdepth 1 -type f -name '*.zip' | wc -l | tr -d ' ')" -eq 1
test "$(find "$candidate_dir" -maxdepth 1 -type f -name '*.sha256' | wc -l | tr -d ' ')" -eq 1

if command -v sha256sum >/dev/null 2>&1; then
	actual_hash=$(sha256sum <"$archive" | awk '{ print $1 }')
else
	actual_hash=$(shasum -a 256 <"$archive" | awk '{ print $1 }')
fi
test "$(cat "$checksum")" = "$actual_hash  SecureStorage.zip"

mkdir -p "$extract_dir"
test -z "$(find "$extract_dir" -mindepth 1 -print -quit)"
case "$(uname -s)" in
	MINGW*|MSYS*|CYGWIN*)
		archive_windows=$(cygpath -w "$archive")
		extract_dir_windows=$(cygpath -w "$extract_dir")
		7z x -y "$archive_windows" "-o$extract_dir_windows"
		;;
	*)
		unzip -q "$archive" -d "$extract_dir"
		;;
esac
addon_directory="$extract_dir/addons/SecureStorage"
for file in \
	export_plugin.gd \
	icon.svg \
	plugin.cfg \
	plugin.gd \
	secure_storage.gd \
	secure_storage.gdextension; do
	test -f "$addon_directory/$file"
	test ! -L "$addon_directory/$file"
done

printf 'SECURE_STORAGE_ADDON_DIR=%s\n' "$addon_directory" >>"$GITHUB_ENV"
