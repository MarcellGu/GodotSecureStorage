@tool
extends EditorPlugin

# 这个轻量编辑器插件只负责注册/注销 export_plugin.gd。
const EXPORT_PLUGIN_SCRIPT: Script = preload("./export_plugin.gd")

# 保存实例，退出插件时必须把同一个对象传给 remove_export_plugin。
var _export_plugin: EditorExportPlugin


## 创建并注册导出插件；无参数和返回值，会改变编辑器导出配置，脚本实例化失败时输出不含秘密值的错误。
func _enter_tree() -> void:
	# preload 在解析期取得脚本，new() 的返回值仍先按 Variant 做运行时检查。
	var instance: Variant = EXPORT_PLUGIN_SCRIPT.new()
	if not instance is EditorExportPlugin:
		push_error("SecureStorage：无法创建导出插件。")
		return
	var export_plugin: EditorExportPlugin = instance as EditorExportPlugin
	# 类型确认后保存强类型引用并交给编辑器。
	_export_plugin = export_plugin
	add_export_plugin(_export_plugin)


## 注销并释放导出插件；无参数和返回值，仅在插件已注册时产生编辑器状态副作用。
func _exit_tree() -> void:
	# 插件可能在 _enter_tree 失败后退出，因此先判断 null。
	if _export_plugin != null:
		remove_export_plugin(_export_plugin)
		_export_plugin = null
