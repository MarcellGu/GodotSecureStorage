@tool
extends EditorExportPlugin

# @tool 让脚本在 Godot 编辑器中运行；它只参与导出，不进入游戏业务逻辑。

const GDEXTENSION_FILE: String = "secure_storage.gdextension"
const ANDROID_DEBUG_AAR: String = "bin/android/debug/SecureStorage-debug.aar"
const ANDROID_RELEASE_AAR: String = "bin/android/release/SecureStorage-release.aar"


## 把插件内相对路径解析为稳定的 Godot 资源路径；路径以本脚本所在目录为基准。
func _get_addon_resource_path(relative_path: String) -> String:
	return get_script().resource_path.get_base_dir().path_join(relative_path)


## 返回导出插件的稳定名称。
func _get_name() -> String:
	return "SecureStorage"


## 判断目标平台是否需要本导出插件；platform 为当前导出目标，返回 Android 或 iOS 支持状态。
func _supports_platform(platform: EditorExportPlatform) -> bool:
	# Windows/Linux/macOS 的 GDExtension 可由描述文件直接导出，不需要额外钩子。
	return platform is EditorExportPlatformAndroid or platform is EditorExportPlatformIOS


## 在导出开始时补充 Apple 系统框架链接参数；features 描述目标、其余参数由 Godot 提供，无返回值，仅修改本次 iOS Xcode 工程。
func _export_begin(features: PackedStringArray, _is_debug: bool, _path: String, _flags: int) -> void:
	# Objective-C++ 后端直接调用 Security、CoreFoundation 与 Foundation。
	if features.has("ios"):
		add_apple_embedded_platform_linker_flags(
			"-framework Security -framework CoreFoundation -framework Foundation"
		)


## Android 只加载 Kotlin AAR；跳过无 Android library 的 GDExtension 描述，避免运行时尝试加载不存在的原生库。
func _export_file(
		path: String,
		_type: String,
		features: PackedStringArray
) -> void:
	if (
			features.has("android")
			and path == _get_addon_resource_path(GDEXTENSION_FILE)
	):
		# skip() 只跳过当前文件，不会跳过整个 addon。
		skip()


## 返回 Android Plugin v2 的 AAR；platform 为 Android 目标，debug 选择构建类型，缺少文件时由 Godot 导出器报告失败。
func _get_android_libraries(platform: EditorExportPlatform, debug: bool) -> PackedStringArray:
	if not platform is EditorExportPlatformAndroid:
		return PackedStringArray()
	var libraries: PackedStringArray = PackedStringArray()
	# Android 导出器会把返回的 AAR 合并进最终 APK/AAB。
	if debug:
		libraries.append(_get_addon_resource_path(ANDROID_DEBUG_AAR))
	else:
		libraries.append(_get_addon_resource_path(ANDROID_RELEASE_AAR))
	return libraries
