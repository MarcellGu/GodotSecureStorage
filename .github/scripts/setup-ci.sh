#!/bin/sh
set -eu

archive_dir="$RUNNER_TEMP/ci-tool-archives"
tool_dir="$RUNNER_TEMP/ci-tools"
mkdir -p "$archive_dir" "$tool_dir"
cache_invalid=false

invalidate_cached_file() {
	if [ "${CACHE_HIT:-}" = true ] && [ "$cache_invalid" = false ]; then
		./.github/scripts/invalidate-cache.sh "${CACHE_KEY:-}"
		cache_invalid=true
	fi
	if [ -e "$1" ] || [ -L "$1" ]; then
		find "$1" -depth -delete
	fi
}

actionlint_archive="$archive_dir/actionlint.tar.gz"
if [ ! -f "$actionlint_archive" ] ||
	! echo "8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8  $actionlint_archive" |
		sha256sum -c -; then
	invalidate_cached_file "$actionlint_archive"
fi
if [ ! -f "$actionlint_archive" ]; then
	curl -fsSL --retry 5 --retry-all-errors --retry-delay 2 \
		"https://github.com/rhysd/actionlint/releases/download/v1.7.12/actionlint_1.7.12_linux_amd64.tar.gz" \
		-o "$actionlint_archive"
fi
echo "8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8  $actionlint_archive" |
	sha256sum -c -
tar -xzf "$actionlint_archive" -C "$tool_dir" actionlint

shellcheck_archive="$archive_dir/shellcheck.tar.xz"
if [ ! -f "$shellcheck_archive" ] ||
	! echo "6c881ab0698e4e6ea235245f22832860544f17ba386442fe7e9d629f8cbedf87  $shellcheck_archive" |
		sha256sum -c -; then
	invalidate_cached_file "$shellcheck_archive"
fi
if [ ! -f "$shellcheck_archive" ]; then
	curl -fsSL --retry 5 --retry-all-errors --retry-delay 2 \
		"https://github.com/koalaman/shellcheck/releases/download/v0.10.0/shellcheck-v0.10.0.linux.x86_64.tar.xz" \
		-o "$shellcheck_archive"
fi
echo "6c881ab0698e4e6ea235245f22832860544f17ba386442fe7e9d629f8cbedf87  $shellcheck_archive" |
	sha256sum -c -
tar -xJf "$shellcheck_archive" -C "$RUNNER_TEMP"
mv "$RUNNER_TEMP/shellcheck-v0.10.0/shellcheck" "$tool_dir/shellcheck"
echo "$tool_dir" >>"$GITHUB_PATH"
