@tool
extends EditorPlugin

const EXPORT_PLUGIN_SCRIPT: Script = preload("res://addons/SecureStorage/export_plugin.gd")

var _export_plugin: EditorExportPlugin


## 创建并注册导出插件；无参数和返回值，会改变编辑器导出配置，脚本实例化失败时输出不含秘密值的错误。
func _enter_tree() -> void:
	var instance: Variant = EXPORT_PLUGIN_SCRIPT.new()
	if not instance is EditorExportPlugin:
		push_error("SecureStorage：无法创建导出插件。")
		return
	var export_plugin: EditorExportPlugin = instance as EditorExportPlugin
	_export_plugin = export_plugin
	add_export_plugin(_export_plugin)


## 注销并释放导出插件；无参数和返回值，仅在插件已注册时产生编辑器状态副作用。
func _exit_tree() -> void:
	if _export_plugin != null:
		remove_export_plugin(_export_plugin)
		_export_plugin = null
