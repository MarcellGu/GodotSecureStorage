#!/bin/sh
set -eu

archive_dir="$RUNNER_TEMP/godot-editor-archive"
archive="$archive_dir/editor.zip"
install_dir="$RUNNER_TEMP/godot"
mkdir -p "$archive_dir"

verify_archive() {
	echo "c7a289051eaefb460b0106b60e9cd5bee0ef55fd102dcb2bed1eb356cf3d90a1  $archive" |
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
		"https://github.com/godotengine/godot/releases/download/4.7.1-stable/Godot_v4.7.1-stable_win64.exe.zip" \
		-o "$archive"
fi
verify_archive

if [ -d "$install_dir" ]; then
	find "$install_dir" -mindepth 1 -depth -delete
fi
mkdir -p "$install_dir"
7z x -y "$archive" "-o$install_dir" >/dev/null
test -f "$install_dir/Godot_v4.7.1-stable_win64.exe"
test -f "$install_dir/Godot_v4.7.1-stable_win64_console.exe"

mkdir -p "$install_dir/bin"
printf '%s\n' \
	'#!/bin/sh' \
	"exec \"\$(dirname \"\$0\")/../Godot_v4.7.1-stable_win64_console.exe\" \"\$@\"" \
	>"$install_dir/bin/godot"
chmod +x "$install_dir/bin/godot"

if command -v cygpath >/dev/null 2>&1; then
	cygpath -u "$install_dir/bin" >>"$GITHUB_PATH"
else
	printf '%s\n' "$install_dir/bin" >>"$GITHUB_PATH"
fi
