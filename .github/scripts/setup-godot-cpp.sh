#!/bin/sh
set -eu

cache_hit=${1:-}
godot_cpp_dir="$RUNNER_TEMP/secure-storage-build/deps/godot-cpp"

verify_checkout() {
	test "$(git -C "$godot_cpp_dir" rev-parse HEAD)" = \
		ba0edfed90512ec64aba51d4295a3e7e30112f86 &&
		test -z "$(git -C "$godot_cpp_dir" status \
			--porcelain --untracked-files=all --ignore-submodules=all)"
}

install_checkout() {
	if [ -e "$godot_cpp_dir" ] || [ -L "$godot_cpp_dir" ]; then
		find "$godot_cpp_dir" -depth -delete
	fi
	mkdir -p "$RUNNER_TEMP/secure-storage-build/deps"
	git init "$godot_cpp_dir"
	git -C "$godot_cpp_dir" remote add origin \
		"https://github.com/godotengine/godot-cpp.git"
	git -C "$godot_cpp_dir" fetch --depth 1 origin \
		ba0edfed90512ec64aba51d4295a3e7e30112f86
	git -C "$godot_cpp_dir" checkout --detach FETCH_HEAD
}

case "$cache_hit" in
	true)
		if ! verify_checkout; then
			./.github/scripts/invalidate-cache.sh "${CACHE_KEY:-}"
			install_checkout
		fi
		;;
	''|false) install_checkout ;;
	*)
		echo "setup-godot-cpp.sh 收到未知 cache-hit：$cache_hit" >&2
		exit 1
		;;
esac

verify_checkout
