#!/bin/sh
set -eu

archive_dir="$RUNNER_TEMP/godot-export-templates"
archive="$archive_dir/templates.tpz"
unpack_dir="$RUNNER_TEMP/template-unpack"
target_root="$HOME/Library/Application Support/Godot/export_templates"
target="$target_root/4.7.1.stable"
mkdir -p "$archive_dir"

verify_archive() {
	echo "86409db6200b6f8fd3230989c2d2002851f3dd18acf11d7bdbafddf5a0dd0f72  $archive" |
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
		"https://github.com/godotengine/godot/releases/download/4.7.1-stable/Godot_v4.7.1-stable_export_templates.tpz" \
		-o "$archive"
fi
verify_archive

if [ -d "$unpack_dir" ]; then
	find "$unpack_dir" -mindepth 1 -depth -delete
fi
mkdir -p "$unpack_dir" "$target_root"
ditto -x -k "$archive" "$unpack_dir"
if [ -d "$target" ]; then
	find "$target" -mindepth 1 -depth -delete
	rmdir "$target"
fi
mv "$unpack_dir/templates" "$target"
