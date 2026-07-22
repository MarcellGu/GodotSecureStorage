extends Node

const TEST_CONTEXT = preload("res://tests/test_context.gd")
const MEMORY_BACKEND_TEST = preload("res://tests/memory_backend_test.gd")
const PLATFORM_BACKEND_TEST = preload("res://tests/platform_backend_test.gd")


## 运行结构化内存测试，并在显式传入 --real 时追加真实平台套件；无参数，结束时按 suite、case 和 check 汇总并设置进程退出码。
func _ready() -> void:
	var context: TEST_CONTEXT = TEST_CONTEXT.new()
	var memory_tests: MEMORY_BACKEND_TEST = MEMORY_BACKEND_TEST.new()
	memory_tests.run(context)
	var arguments: PackedStringArray = OS.get_cmdline_user_args()
	if arguments.has("--real"):
		var platform_tests: PLATFORM_BACKEND_TEST = PLATFORM_BACKEND_TEST.new()
		platform_tests.run(context)
	context.print_summary()
	get_tree().quit(1 if context.has_failures() else 0)
