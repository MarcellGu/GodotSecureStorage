#!/bin/sh
set -eu

wheel="$RUNNER_TEMP/scons-4.10.1-py3-none-any.whl"

verify_wheel() {
	echo "bd9d1c52f908d874eba92a8c0c0a8dcf2ed9f3b88ab956d0fce1da479c4e7126  $wheel" |
		shasum -a 256 -c -
}

if [ ! -f "$wheel" ] || ! verify_wheel; then
	if [ "${CACHE_HIT:-}" = true ]; then
		./.github/scripts/invalidate-cache.sh "${CACHE_KEY:-}"
	fi
	if [ -e "$wheel" ] || [ -L "$wheel" ]; then
		find "$wheel" -depth -delete
	fi
fi
if [ ! -f "$wheel" ]; then
	curl -fsSL --retry 5 --retry-all-errors --retry-delay 2 \
		"https://files.pythonhosted.org/packages/ce/bf/931fb9fbb87234c32b8b1b1c15fba23472a10777c12043336675633809a7/scons-4.10.1-py3-none-any.whl" \
		-o "$wheel"
fi
verify_wheel

python3 -m venv "$RUNNER_TEMP/scons"
"$RUNNER_TEMP/scons/bin/python" -m pip install --no-deps "$wheel"
"$RUNNER_TEMP/scons/bin/scons" --version | grep -F "SCons: v4.10.1"
echo "$RUNNER_TEMP/scons/bin" >>"$GITHUB_PATH"
