@tool
extends EditorExportPlugin

const PLUGIN_NAME: String = "SecureStorage"
const ANDROID_DEBUG_AAR: String = "SecureStorage/bin/android/debug/SecureStorage-debug.aar"
const ANDROID_RELEASE_AAR: String = "SecureStorage/bin/android/release/SecureStorage-release.aar"


## 返回导出插件的稳定名称；无参数、无副作用，也不会暴露目标平台差异。
func _get_name() -> String:
	return PLUGIN_NAME


## 判断目标平台是否需要本导出插件；platform 为当前导出目标，返回 Android 或 iOS 支持状态且无副作用。
func _supports_platform(platform: EditorExportPlatform) -> bool:
	return platform is EditorExportPlatformAndroid or platform is EditorExportPlatformIOS


## 在导出开始时补充 Apple 系统框架链接参数；features 描述目标、其余参数由 Godot 提供，无返回值，仅修改本次 iOS Xcode 工程。
func _export_begin(features: PackedStringArray, _is_debug: bool, _path: String, _flags: int) -> void:
	if features.has("ios"):
		add_apple_embedded_platform_linker_flags("-framework Security -framework CoreFoundation")


## 返回 Android Plugin v2 的 AAR；platform 为 Android 目标，debug 选择构建类型，缺少文件时由 Godot 导出器报告失败。
func _get_android_libraries(platform: EditorExportPlatform, debug: bool) -> PackedStringArray:
	if not platform is EditorExportPlatformAndroid:
		return PackedStringArray()
	var libraries: PackedStringArray = PackedStringArray()
	if debug:
		libraries.append(ANDROID_DEBUG_AAR)
	else:
		libraries.append(ANDROID_RELEASE_AAR)
	return libraries
