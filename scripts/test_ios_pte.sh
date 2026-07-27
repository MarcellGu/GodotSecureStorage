#!/bin/sh
set -eu

project_dir=$(CDPATH='' cd -P -- "$(dirname -- "$0")/.." && pwd -P)
build_root=${SECURE_STORAGE_BUILD_ROOT:-${TMPDIR:-/tmp}/secure-storage-build}
godot_bin=${GODOT_BIN:-godot}
godot_version_expected=${GODOT_VERSION:-4.7.1-stable}
apple_access_group=${SECURE_STORAGE_APPLE_ACCESS_GROUP:-}
open_xcode=${SECURE_STORAGE_PTE_OPEN_XCODE:-1}
addon_source=${SECURE_STORAGE_ADDON_DIR:-$project_dir/addon}
team_id=${apple_access_group%%.*}

prompt_value() {
	prompt=$1
	if [ ! -t 0 ]; then
		echo "缺少配置且当前终端不可交互：$prompt" >&2
		return 1
	fi
	printf '%s：' "$prompt" >&2
	IFS= read -r answer || return 1
	printf '%s\n' "$answer"
}

case "${CI:-}" in
	1|true|TRUE)
		echo "test_ios_pte.sh 只供本机人工签收，不能在 CI 中运行。" >&2
		exit 1
		;;
esac
if [ -z "$apple_access_group" ]; then
	apple_access_group=$(prompt_value \
		"请输入完整 Apple Keychain access group（例如 ABCDE12345.com.example.game）") || exit 1
	team_id=${apple_access_group%%.*}
fi
case "$apple_access_group" in
	''|*[!A-Za-z0-9.-]*)
		echo "SECURE_STORAGE_APPLE_ACCESS_GROUP 必须是非空的 Apple access group 标识。" >&2
		exit 1
		;;
esac
case "$team_id" in
	''|*[!A-Za-z0-9]*)
		echo "Apple access group 必须以字母数字 Team ID 开头。" >&2
		exit 1
		;;
esac
case "$apple_access_group" in
	"$team_id".*) ;;
	*)
		echo "Apple access group 必须包含 Team ID 与组名。" >&2
		exit 1
		;;
esac
case "$open_xcode" in
	0|1) ;;
	*) echo "SECURE_STORAGE_PTE_OPEN_XCODE 必须为 0 或 1。" >&2; exit 1 ;;
esac
if [ "$(uname -s)" != Darwin ]; then
	echo "test_ios_pte.sh 只能在 macOS 上运行。" >&2
	exit 1
fi
if ! command -v "$godot_bin" >/dev/null 2>&1 &&
	[ -z "${GODOT_BIN:-}" ]; then
	godot_bin=$(prompt_value "找不到 godot，请输入 Godot 4.7.1 可执行文件路径") || exit 1
fi
if [ ! -d "$addon_source" ] &&
	[ -z "${SECURE_STORAGE_ADDON_DIR:-}" ]; then
	addon_source=$(prompt_value "找不到默认 addon，请输入候选插件目录") || exit 1
fi
for command in "$godot_bin" plutil; do
	command -v "$command" >/dev/null 2>&1 || {
		echo "缺少 iOS PTE 依赖：$command" >&2
		exit 1
	}
done
if [ "$open_xcode" -eq 1 ]; then
	command -v open >/dev/null 2>&1 || {
		echo "缺少 iOS PTE 依赖：open" >&2
		exit 1
	}
fi
godot_version=$("$godot_bin" --version | tr -d '\r' | sed -n '1p')
godot_version_runtime=$(printf '%s\n' "$godot_version_expected" | sed 's/-stable$/.stable/')
case "$godot_version" in
	"$godot_version_runtime".*) ;;
	*) echo "TestSecureStorage 需要 Godot $godot_version_expected，实际为：$godot_version" >&2; exit 1 ;;
esac

mkdir -p "$build_root"
build_root=$(CDPATH='' cd -P -- "$build_root" && pwd -P)
case "$build_root" in
	"$project_dir"|"$project_dir"/*)
		echo "SECURE_STORAGE_BUILD_ROOT 必须位于仓库外：$build_root" >&2
		exit 1
		;;
esac
addon_dir=$(CDPATH='' cd -P -- "$addon_source" && pwd -P)
for target in template_debug template_release; do
	test -d "$addon_dir/bin/ios/libsecure_storage.ios.$target.xcframework"
	test -d "$addon_dir/bin/ios/libgodot-cpp.ios.$target.xcframework"
	test -d "$addon_dir/bin/macos/libsecure_storage.macos.$target.framework"
done
for file in plugin.cfg plugin.gd export_plugin.gd secure_storage.gd secure_storage.gdextension icon.svg; do
	test -f "$addon_dir/$file"
done

stage="$build_root/pte/ios"
if [ -d "$stage" ]; then
	find "$stage" -mindepth 1 -depth -delete
fi
mkdir -p "$stage/addons" "$stage/output" "$stage/addon"
: >"$stage/output/.gdignore"
for file in project.godot export_presets.cfg main.tscn main.gd; do
	cp "$project_dir/$file" "$stage/$file"
done
configured_project="$stage/project.godot.configured"
sed "s|^apple_access_group=.*$|apple_access_group=\"$apple_access_group\"|" \
	"$stage/project.godot" >"$configured_project"
mv "$configured_project" "$stage/project.godot"
configured_presets="$stage/export_presets.cfg.configured"
sed "s/application\\/app_store_team_id=\"TESTTEAM00\"/application\\/app_store_team_id=\"$team_id\"/" \
	"$stage/export_presets.cfg" >"$configured_presets"
mv "$configured_presets" "$stage/export_presets.cfg"
cp -R "$addon_dir/." "$stage/addon/"

projects=
for variant in debug release; do
	output_dir="$stage/output/$variant"
	mkdir -p "$output_dir"
	if [ "$variant" = debug ]; then
		export_flag=--export-debug
	else
		export_flag=--export-release
	fi
	export_log="$stage/output/export-$variant.log"
	if ! "$godot_bin" --headless --path "$stage" "$export_flag" iOS \
		"$output_dir/TestSecureStorage.ipa" >"$export_log" 2>&1; then
		sed -n '1,240p' "$export_log" >&2
		exit 1
	fi
	if grep -En 'SCRIPT ERROR|Parse Error|ERROR:' "$export_log"; then
		exit 1
	fi
	project="$output_dir/TestSecureStorage.xcodeproj"
	entitlements="$output_dir/TestSecureStorage/TestSecureStorage.entitlements"
	test -d "$project"
	test -f "$entitlements"
	if plutil -extract keychain-access-groups xml1 -o - "$entitlements" >/dev/null 2>&1; then
		plutil -remove keychain-access-groups "$entitlements"
	fi
	plutil -insert keychain-access-groups \
		-json "[\"$apple_access_group\"]" "$entitlements"
	test "$(plutil -extract keychain-access-groups.0 raw -o - "$entitlements")" = \
		"$apple_access_group"
	echo "TestSecureStorage iOS $variant PTE：$project"
	projects="$projects
$project"
done

echo "在 Xcode 的 Signing & Capabilities 中确认 Team ${team_id}，选择真机并运行；控制台必须输出 result=PASS。"
if [ "$open_xcode" -eq 1 ]; then
	printf '%s\n' "$projects" | while IFS= read -r project; do
		[ -n "$project" ] && open -a Xcode "$project"
	done
fi
