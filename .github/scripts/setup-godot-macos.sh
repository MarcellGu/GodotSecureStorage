#!/bin/sh
set -eu

archive_dir="$RUNNER_TEMP/godot-editor-archive"
archive="$archive_dir/editor.zip"
install_dir="$RUNNER_TEMP/godot"
bin_dir="$RUNNER_TEMP/bin"
mkdir -p "$archive_dir"

verify_archive() {
	echo "897cb7f9799796c717ae75f31446aed883dc92b1d6c3b33d893cc7843fff2fa9  $archive" |
		shasum -a 256 -c -
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
		"https://github.com/godotengine/godot/releases/download/4.7.1-stable/Godot_v4.7.1-stable_macos.universal.zip" \
		-o "$archive"
fi
verify_archive

if [ -d "$install_dir" ]; then
	find "$install_dir" -mindepth 1 -depth -delete
fi
mkdir -p "$install_dir" "$bin_dir"
ditto -x -k "$archive" "$install_dir"
ln -s "$install_dir/Godot.app/Contents/MacOS/Godot" "$bin_dir/godot"
echo "$bin_dir" >>"$GITHUB_PATH"
