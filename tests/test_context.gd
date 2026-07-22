extends RefCounted

var _suite_count: int = 0
var _case_count: int = 0
var _check_count: int = 0
var _failure_count: int = 0
var _current_suite: String = ""
var _current_case: String = ""
var _case_check_start: int = 0
var _case_failure_start: int = 0


## 开始一个测试套件；name 仅用于结构化日志且不得包含秘密值，无返回值，会增加套件计数。
func begin_suite(name: String) -> void:
	_current_suite = name
	_suite_count += 1
	print("\n[SUITE] " + name)


## 结束当前测试套件；无参数和返回值，只清理当前套件名称，不改变测试结果。
func end_suite() -> void:
	_current_suite = ""


## 开始一个测试案例；name 仅用于结构化日志且不得包含秘密值，无返回值，会记录案例的断言起点。
func begin_case(name: String) -> void:
	_current_case = name
	_case_count += 1
	_case_check_start = _check_count
	_case_failure_start = _failure_count


## 结束当前测试案例；无参数和返回值，会输出案例级 PASS 或 FAIL，但不输出秘密值和实际载荷。
func end_case() -> void:
	var case_checks: int = _check_count - _case_check_start
	var case_failures: int = _failure_count - _case_failure_start
	if case_failures == 0:
		print("  [PASS] %s (%d checks)" % [_current_case, case_checks])
	else:
		print("  [FAIL] %s (%d/%d failed)" % [_current_case, case_failures, case_checks])
	_current_case = ""


## 记录一个布尔断言；condition 是判断结果，message 只能描述固定预期且不得包含秘密值，无返回值，失败时增加失败计数。
func check(condition: bool, message: String) -> void:
	_check_count += 1
	if not condition:
		_failure_count += 1
		push_error("[%s/%s] %s" % [_current_suite, _current_case, message])


## 断言统一结果成功；result 为待检查结果，message 不得包含秘密值，无返回值，失败信息只包含统一错误名称。
func expect_ok(result: SecureStorageResult, message: String) -> void:
	check(result.is_ok(), message + "，实际错误：" + SecureStorageError.code_name(result.get_error()))


## 断言结果成功、存在且值匹配；result 为结果、expected 仅在内存中比较、message 不得含秘密值，无返回值且不会记录实际值。
func expect_value(result: SecureStorageResult, expected: String, message: String) -> void:
	check(result.is_ok(), message + "：操作应成功")
	check(result.is_found(), message + "：键应存在")
	check(result.get_value() == expected, message + "：内容应匹配")


## 断言结果成功但键不存在；result 为待检查结果，message 不得包含秘密值，无返回值，会记录两项断言。
func expect_missing(result: SecureStorageResult, message: String) -> void:
	check(result.is_ok(), message + "：操作应成功")
	check(not result.is_found(), message + "：键应不存在")


## 返回是否出现任何失败；无参数和副作用，返回 true 表示至少一个断言失败。
func has_failures() -> bool:
	return _failure_count > 0


## 输出最终结构化汇总；无参数和返回值，不输出测试数据，失败时通过 Godot 错误日志报告统计信息。
func print_summary() -> void:
	var summary: String = "%d suites, %d cases, %d checks" % [_suite_count, _case_count, _check_count]
	if _failure_count == 0:
		print("\n[PASS] SecureStorage：" + summary)
	else:
		push_error("[FAIL] SecureStorage：%s, %d failed" % [summary, _failure_count])
