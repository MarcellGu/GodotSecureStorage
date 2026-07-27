#!/bin/sh
set -eu

archive_dir="$RUNNER_TEMP/godot-editor-archive"
archive="$archive_dir/editor.zip"
install_dir="$RUNNER_TEMP/godot"
mkdir -p "$archive_dir"

verify_archive() {
	echo "c7ff14fd28472c8d4f193043de30278dcf7e5241a1dcf7566b02e27addaa33ba  $archive" |
		sha256sum -c -
}

if [ ! -f "$archive" ] || ! verify_archive; then
	if [ "${CACHE_HIT:-}" = true ]; then
		./.github/scripts/invalidate-cache.sh "${CACHE_KEY:-}"
	fi
	if [ -e "$archive" ] || [ -L "$archive" ]; then
		find "$archive" -depth -delete
	fi
fi
if [ ! -f "$archive" ]; then
	curl -fsSL --retry 5 --retry-all-errors --retry-delay 2 \
		"https://github.com/godotengine/godot/releases/download/4.7.1-stable/Godot_v4.7.1-stable_linux.x86_64.zip" \
		-o "$archive"
fi
verify_archive

if [ -d "$install_dir" ]; then
	find "$install_dir" -mindepth 1 -depth -delete
fi
mkdir -p "$install_dir"
unzip -q "$archive" -d "$install_dir"
mv "$install_dir/Godot_v4.7.1-stable_linux.x86_64" "$install_dir/godot"
echo "$install_dir" >>"$GITHUB_PATH"
