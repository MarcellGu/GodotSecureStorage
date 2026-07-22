extends RefCounted

const TEST_CONTEXT = preload("res://tests/test_context.gd")
const STORAGE_CONTRACT_TEST = preload("res://tests/storage_contract_test.gd")
const STORAGE_SERVICE = preload("res://addons/SecureStorage/storage_service.gd")
const PRIMARY_NAMESPACE: String = "com.marcellgu.securestorage.contract_test"
const SECONDARY_NAMESPACE: String = "com.marcellgu.securestorage.contract_other"
const SECRET_SAMPLE: String = "sample-secret-never-log"


## 运行内存后端的统一契约与故障映射测试；context 收集结构化结果，无返回值，只修改并清理测试专用内存后端。
func run(context: TEST_CONTEXT) -> void:
	var storage: SecureStorage = SecureStorage.create_for_testing()
	var contract: STORAGE_CONTRACT_TEST = STORAGE_CONTRACT_TEST.new()
	var available: bool = contract.run(
			context,
			"内存后端统一契约",
			storage,
			PRIMARY_NAMESPACE,
			SECONDARY_NAMESPACE
	)
	if not available:
		return

	context.begin_suite("内存后端故障映射")

	context.begin_case("公开方法参数名")
	var service: RefCounted = STORAGE_SERVICE.new()
	context.check(service != null, "GDScript 包装器应可解析并实例化")
	var namespace_method_count: int = 0
	var namespace_methods: Array[String] = [
		"set_value",
		"get_value",
		"remove_value",
		"clear_namespace",
		"corrupt_value_for_testing",
	]
	for method: Dictionary in ClassDB.class_get_method_list("SecureStorage", true):
		if method["name"] not in namespace_methods:
			continue
		namespace_method_count += 1
		var arguments: Array = method["args"]
		context.check(not arguments.is_empty(), "命名空间方法应至少有一个参数")
		if not arguments.is_empty():
			context.check(arguments[0]["name"] == "storage_namespace", "命名空间入参应避免 GDScript 保留字")
	context.check(namespace_method_count == namespace_methods.size(), "应覆盖所有暴露命名空间入参的方法")
	context.end_case()

	context.begin_case("错误名称覆盖")
	var expected_names: Array[String] = [
		"OK",
		"INVALID_ARGUMENT",
		"UNAVAILABLE",
		"IO_ERROR",
		"CRYPTO_ERROR",
		"CORRUPT_DATA",
		"PERMISSION_DENIED",
		"PLATFORM_ERROR",
		"UNKNOWN",
	]
	for code: int in range(expected_names.size()):
		context.check(SecureStorageError.code_name(code) == expected_names[code], "错误名称应覆盖全部枚举")
	context.check(SecureStorageError.code_name(999) == "UNKNOWN", "未知错误码应归一为 UNKNOWN")
	context.end_case()

	context.begin_case("参数边界")
	var max_namespace: String = "a".repeat(128)
	var max_key: String = "键".repeat(512)
	var max_value: String = "界".repeat(349525) + "a"
	context.expect_ok(storage.set_value(max_namespace, max_key, max_value), "最大合法参数写入")
	context.expect_value(storage.get_value(max_namespace, max_key), max_value, "最大合法参数读取")
	_expect_error(context, storage.set_value("", "key", "value"), SecureStorageError.INVALID_ARGUMENT, "空 namespace")
	_expect_error(context, storage.set_value("a".repeat(129), "key", "value"), SecureStorageError.INVALID_ARGUMENT, "超长 namespace")
	_expect_error(context, storage.get_value("has/slash", "key"), SecureStorageError.INVALID_ARGUMENT, "非法 namespace 字符")
	_expect_error(context, storage.remove_value(PRIMARY_NAMESPACE, ""), SecureStorageError.INVALID_ARGUMENT, "空 key")
	_expect_error(context, storage.get_value(PRIMARY_NAMESPACE, "k".repeat(513)), SecureStorageError.INVALID_ARGUMENT, "超长 key")
	_expect_error(context, storage.set_value(PRIMARY_NAMESPACE, "large", max_value + "界"), SecureStorageError.INVALID_ARGUMENT, "超大 value")
	_expect_error(context, storage.clear_namespace("UPPER"), SecureStorageError.INVALID_ARGUMENT, "清空非法 namespace")
	context.expect_ok(storage.clear_namespace(max_namespace), "最大参数测试清理")
	context.end_case()

	context.begin_case("损坏数据")
	context.expect_ok(storage.set_value(PRIMARY_NAMESPACE, "corrupt", SECRET_SAMPLE), "损坏样本写入")
	storage.corrupt_value_for_testing(PRIMARY_NAMESPACE, "corrupt")
	var corrupt: SecureStorageResult = storage.get_value(PRIMARY_NAMESPACE, "corrupt")
	context.check(not corrupt.is_ok(), "损坏数据读取应失败")
	context.check(corrupt.get_error() == SecureStorageError.CORRUPT_DATA, "损坏数据应返回 CORRUPT_DATA")
	context.expect_ok(storage.set_value(PRIMARY_NAMESPACE, "corrupt", "replacement"), "覆盖损坏数据")
	context.expect_value(storage.get_value(PRIMARY_NAMESPACE, "corrupt"), "replacement", "覆盖后损坏标记应清除")
	storage.corrupt_value_for_testing(PRIMARY_NAMESPACE, "remove-corrupt")
	context.expect_ok(storage.remove_value(PRIMARY_NAMESPACE, "remove-corrupt"), "删除仅有损坏标记的键")
	storage.corrupt_value_for_testing(PRIMARY_NAMESPACE, "clear-corrupt")
	context.expect_ok(storage.clear_namespace(PRIMARY_NAMESPACE), "清空损坏标记")
	context.expect_missing(storage.get_value(PRIMARY_NAMESPACE, "clear-corrupt"), "清空后损坏标记应不存在")
	context.end_case()

	context.begin_case("后端不可用")
	storage.set_available_for_testing(false)
	context.check(not storage.is_available(), "不可用状态应被报告")
	_expect_error(context, storage.set_value(PRIMARY_NAMESPACE, "key", "value"), SecureStorageError.UNAVAILABLE, "不可用后端写入")
	_expect_error(context, storage.get_value(PRIMARY_NAMESPACE, "key"), SecureStorageError.UNAVAILABLE, "不可用后端读取")
	_expect_error(context, storage.remove_value(PRIMARY_NAMESPACE, "key"), SecureStorageError.UNAVAILABLE, "不可用后端删除")
	_expect_error(context, storage.clear_namespace(PRIMARY_NAMESPACE), SecureStorageError.UNAVAILABLE, "不可用后端清空")
	storage.set_available_for_testing(true)
	context.check(storage.is_available(), "恢复后的后端应可用")
	context.end_case()

	context.begin_case("故障测试清理")
	context.expect_ok(storage.clear_namespace(PRIMARY_NAMESPACE), "故障测试命名空间清理")
	context.end_case()

	context.end_suite()


## 断言指定操作失败并映射到预期错误；不会记录秘密值。
func _expect_error(context: TEST_CONTEXT, result: SecureStorageResult, expected: int, message: String) -> void:
	context.check(not result.is_ok(), message + "应失败")
	context.check(not result.is_found(), message + "失败结果不应标记 found")
	context.check(result.get_error() == expected, message + "应返回指定错误")
	context.check(not result.get_error_message().is_empty(), message + "应返回安全诊断")
