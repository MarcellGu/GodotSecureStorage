#!/bin/sh
set -eu

project_dir=$(CDPATH='' cd -P -- "$(dirname -- "$0")/.." && pwd -P)
build_root=${SECURE_STORAGE_BUILD_ROOT:-${TMPDIR:-/tmp}/secure-storage-build}
godot_bin=${GODOT_BIN:-godot}
godot_version_expected=${GODOT_VERSION:-4.7.1-stable}
apple_access_group=${SECURE_STORAGE_APPLE_ACCESS_GROUP:-}
open_xcode=${SECURE_STORAGE_PTE_OPEN_XCODE:-1}
addon_source=${SECURE_STORAGE_ADDON_DIR:-$project_dir/addon}
bundle_id=com.marcellgu.testsecurestorage
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
		echo "test_macos_pte.sh 只供本机人工签收，不能在 CI 中运行。" >&2
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
	echo "test_macos_pte.sh 只能在 macOS 上运行。" >&2
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
		echo "缺少 macOS PTE 依赖：$command" >&2
		exit 1
	}
done
if [ "$open_xcode" -eq 1 ]; then
	command -v open >/dev/null 2>&1 || {
		echo "缺少 macOS PTE 依赖：open" >&2
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
	test -d "$addon_dir/bin/macos/libsecure_storage.macos.$target.framework"
done
for file in plugin.cfg plugin.gd export_plugin.gd secure_storage.gd secure_storage.gdextension icon.svg; do
	test -f "$addon_dir/$file"
done

stage="$build_root/pte/macos"
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
cp -R "$addon_dir/." "$stage/addon/"

generate_xcode_host() {
	host_dir=$1
	source_app=$2
	run_configuration=$3
	mkdir -p "$host_dir/TestSecureStorage.xcodeproj/xcshareddata/xcschemes"
	cp -R "$source_app" "$host_dir/SourceApp.app"

	cat >"$host_dir/placeholder.c" <<'EOF'
int main(void) {
	return 0;
}
EOF
	cat >"$host_dir/TestSecureStorage.entitlements" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>keychain-access-groups</key>
	<array>
		<string>$apple_access_group</string>
	</array>
	<key>com.apple.security.cs.disable-library-validation</key>
	<true/>
</dict>
</plist>
EOF
	cat >"$host_dir/prepare-godot-app.sh" <<'EOF'
#!/bin/sh
set -eu
source_contents="$SRCROOT/SourceApp.app/Contents"
product_contents="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH"
rm -rf "$product_contents/Resources" "$product_contents/Frameworks"
ditto "$source_contents/Resources" "$product_contents/Resources"
if [ -d "$source_contents/Frameworks" ]; then
	ditto "$source_contents/Frameworks" "$product_contents/Frameworks"
fi
ditto "$source_contents/MacOS/TestSecureStorage" "$TARGET_BUILD_DIR/$EXECUTABLE_PATH"
chmod +x "$TARGET_BUILD_DIR/$EXECUTABLE_PATH"
if [ -d "$product_contents/Frameworks" ]; then
	find "$product_contents/Frameworks" -type d -name '*.framework' -prune |
		while IFS= read -r framework; do
			info_plist="$framework/Resources/Info.plist"
			if [ ! -d "$framework/Versions" ] && [ -f "$info_plist" ]; then
				executable=$(plutil -extract CFBundleExecutable raw -o - "$info_plist")
				mkdir -p "$framework/Versions/A"
				mv "$framework/Resources" "$framework/Versions/A/Resources"
				mv "$framework/$executable" "$framework/Versions/A/$executable"
				rm -rf "$framework/_CodeSignature"
				ln -s A "$framework/Versions/Current"
				ln -s Versions/Current/Resources "$framework/Resources"
				ln -s "Versions/Current/$executable" "$framework/$executable"
			fi
			if [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
				codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" \
					--timestamp=none "$framework"
			fi
		done
fi
EOF
	cat >"$host_dir/TestSecureStorage.xcodeproj/project.pbxproj" <<EOF
// !\$*UTF8*\$!
{
	archiveVersion = 1;
	classes = {};
	objectVersion = 56;
	objects = {
		AA0000000000000000000001 = {isa = PBXBuildFile; fileRef = AA0000000000000000000002; };
		AA0000000000000000000002 = {isa = PBXFileReference; lastKnownFileType = sourcecode.c.c; path = placeholder.c; sourceTree = "<group>"; };
		AA0000000000000000000003 = {isa = PBXFileReference; lastKnownFileType = text.plist.entitlements; path = TestSecureStorage.entitlements; sourceTree = "<group>"; };
		AA0000000000000000000004 = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = TestSecureStorage.app; sourceTree = BUILT_PRODUCTS_DIR; };
		AA0000000000000000000005 = {isa = PBXFileReference; lastKnownFileType = wrapper.application; path = SourceApp.app; sourceTree = "<group>"; };
		AA0000000000000000000010 = {
			isa = PBXGroup;
			children = (
				AA0000000000000000000002,
				AA0000000000000000000003,
				AA0000000000000000000005,
				AA0000000000000000000011,
			);
			sourceTree = "<group>";
		};
		AA0000000000000000000011 = {
			isa = PBXGroup;
			children = (AA0000000000000000000004,);
			name = Products;
			sourceTree = "<group>";
		};
		AA0000000000000000000020 = {
			isa = PBXNativeTarget;
			buildConfigurationList = AA0000000000000000000051;
			buildPhases = (
				AA0000000000000000000030,
				AA0000000000000000000031,
			);
			buildRules = ();
			dependencies = ();
			name = TestSecureStorage;
			productName = TestSecureStorage;
			productReference = AA0000000000000000000004;
			productType = "com.apple.product-type.application";
		};
		AA0000000000000000000021 = {
			isa = PBXProject;
			attributes = {
				BuildIndependentTargetsInParallel = 1;
				LastUpgradeCheck = 2600;
				TargetAttributes = {
					AA0000000000000000000020 = {
						DevelopmentTeam = $team_id;
						ProvisioningStyle = Automatic;
						SystemCapabilities = {
							com.apple.Keychain = { enabled = 1; };
						};
					};
				};
			};
			buildConfigurationList = AA0000000000000000000050;
			compatibilityVersion = "Xcode 14.0";
			developmentRegion = en;
			hasScannedForEncodings = 0;
			knownRegions = (en, Base);
			mainGroup = AA0000000000000000000010;
			productRefGroup = AA0000000000000000000011;
			projectDirPath = "";
			projectRoot = "";
			targets = (AA0000000000000000000020,);
		};
		AA0000000000000000000030 = {
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (AA0000000000000000000001,);
			runOnlyForDeploymentPostprocessing = 0;
		};
		AA0000000000000000000031 = {
			isa = PBXShellScriptBuildPhase;
			alwaysOutOfDate = 1;
			buildActionMask = 2147483647;
			files = ();
			inputPaths = ();
			name = "Install Godot Export";
			outputPaths = ();
			runOnlyForDeploymentPostprocessing = 0;
			shellPath = /bin/sh;
			shellScript = "sh \"\$SRCROOT/prepare-godot-app.sh\"";
		};
		AA0000000000000000000040 = {
			isa = XCBuildConfiguration;
			buildSettings = {
				CLANG_ENABLE_MODULES = YES;
				MACOSX_DEPLOYMENT_TARGET = 13.0;
				SDKROOT = macosx;
			};
			name = Debug;
		};
		AA0000000000000000000041 = {
			isa = XCBuildConfiguration;
			buildSettings = {
				CLANG_ENABLE_MODULES = YES;
				MACOSX_DEPLOYMENT_TARGET = 13.0;
				SDKROOT = macosx;
			};
			name = Release;
		};
		AA0000000000000000000042 = {
			isa = XCBuildConfiguration;
			buildSettings = {
				CODE_SIGN_ENTITLEMENTS = TestSecureStorage.entitlements;
				CODE_SIGN_STYLE = Automatic;
				DEVELOPMENT_TEAM = $team_id;
				ENABLE_HARDENED_RUNTIME = YES;
				ENABLE_USER_SCRIPT_SANDBOXING = NO;
				EXECUTABLE_NAME = TestSecureStorage;
				GENERATE_INFOPLIST_FILE = NO;
				INFOPLIST_FILE = SourceApp.app/Contents/Info.plist;
				PRODUCT_BUNDLE_IDENTIFIER = $bundle_id;
				PRODUCT_NAME = TestSecureStorage;
			};
			name = Debug;
		};
		AA0000000000000000000043 = {
			isa = XCBuildConfiguration;
			buildSettings = {
				CODE_SIGN_ENTITLEMENTS = TestSecureStorage.entitlements;
				CODE_SIGN_STYLE = Automatic;
				DEVELOPMENT_TEAM = $team_id;
				ENABLE_HARDENED_RUNTIME = YES;
				ENABLE_USER_SCRIPT_SANDBOXING = NO;
				EXECUTABLE_NAME = TestSecureStorage;
				GENERATE_INFOPLIST_FILE = NO;
				INFOPLIST_FILE = SourceApp.app/Contents/Info.plist;
				PRODUCT_BUNDLE_IDENTIFIER = $bundle_id;
				PRODUCT_NAME = TestSecureStorage;
			};
			name = Release;
		};
		AA0000000000000000000050 = {
			isa = XCConfigurationList;
			buildConfigurations = (
				AA0000000000000000000040,
				AA0000000000000000000041,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		};
		AA0000000000000000000051 = {
			isa = XCConfigurationList;
			buildConfigurations = (
				AA0000000000000000000042,
				AA0000000000000000000043,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		};
	};
	rootObject = AA0000000000000000000021;
}
EOF
	cat >"$host_dir/TestSecureStorage.xcodeproj/xcshareddata/xcschemes/TestSecureStorage.xcscheme" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2600" version="1.7">
	<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
		<BuildActionEntries>
			<BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">
				<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="AA0000000000000000000020" BuildableName="TestSecureStorage.app" BlueprintName="TestSecureStorage" ReferencedContainer="container:TestSecureStorage.xcodeproj"/>
			</BuildActionEntry>
		</BuildActionEntries>
	</BuildAction>
	<RunAction buildConfiguration="$run_configuration" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES">
		<BuildableProductRunnable runnableDebuggingMode="0">
			<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="AA0000000000000000000020" BuildableName="TestSecureStorage.app" BlueprintName="TestSecureStorage" ReferencedContainer="container:TestSecureStorage.xcodeproj"/>
		</BuildableProductRunnable>
		<CommandLineArguments>
			<CommandLineArgument argument="--headless" isEnabled="YES"/>
		</CommandLineArguments>
	</RunAction>
	<ProfileAction buildConfiguration="$run_configuration" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES">
		<BuildableProductRunnable runnableDebuggingMode="0">
			<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="AA0000000000000000000020" BuildableName="TestSecureStorage.app" BlueprintName="TestSecureStorage" ReferencedContainer="container:TestSecureStorage.xcodeproj"/>
		</BuildableProductRunnable>
	</ProfileAction>
	<AnalyzeAction buildConfiguration="$run_configuration"/>
	<ArchiveAction buildConfiguration="$run_configuration" revealArchiveInOrganizer="YES"/>
</Scheme>
EOF
}

projects=
for variant in debug release; do
	output_dir="$stage/output/$variant"
	app="$output_dir/GodotExport.app"
	mkdir -p "$output_dir"
	if [ "$variant" = debug ]; then
		export_flag=--export-debug
		run_configuration=Debug
	else
		export_flag=--export-release
		run_configuration=Release
	fi
	export_log="$stage/output/export-$variant.log"
	if ! "$godot_bin" --headless --path "$stage" "$export_flag" macOS \
		"$app" >"$export_log" 2>&1; then
		sed -n '1,240p' "$export_log" >&2
		exit 1
	fi
	if grep -En 'SCRIPT ERROR|Parse Error|ERROR:' "$export_log"; then
		exit 1
	fi
	test -x "$app/Contents/MacOS/TestSecureStorage"
	host_dir="$output_dir/xcode-host"
	generate_xcode_host "$host_dir" "$app" "$run_configuration"
	project="$host_dir/TestSecureStorage.xcodeproj"
	echo "TestSecureStorage macOS $variant PTE：$project"
	projects="$projects
$project"
done

echo "在 Xcode 的 Signing & Capabilities 中确认 Team ${team_id}，选择 My Mac 并运行；控制台必须输出 result=PASS。"
if [ "$open_xcode" -eq 1 ]; then
	printf '%s\n' "$projects" | while IFS= read -r project; do
		[ -n "$project" ] && open -a Xcode "$project"
	done
fi
