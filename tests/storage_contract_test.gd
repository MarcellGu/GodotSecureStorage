extends RefCounted

const TEST_CONTEXT = preload("res://tests/test_context.gd")
const SECRET_SAMPLE: String = "sample-secret-never-log"


## 对指定后端执行统一存储契约；context 收集结果，suite_name 标识套件，storage 是被测对象，两个 namespace 必须为测试专用值，返回后端是否可用并会清理测试数据。
func run(
		context: TEST_CONTEXT,
		suite_name: String,
		storage: SecureStorage,
		primary_namespace: String,
		secondary_namespace: String
) -> bool:
	context.begin_suite(suite_name)

	context.begin_case("准备隔离命名空间")
	context.expect_ok(storage.clear_namespace(primary_namespace), "主命名空间预清理")
	context.expect_ok(storage.clear_namespace(secondary_namespace), "副命名空间预清理")
	context.end_case()

	context.begin_case("后端可用")
	var available: bool = storage.is_available()
	context.check(available, "后端应可用")
	context.end_case()
	if not available:
		context.end_suite()
		return false

	context.begin_case("普通字符串写入读取")
	context.expect_ok(storage.set_value(primary_namespace, "normal", SECRET_SAMPLE), "普通字符串写入")
	context.expect_value(storage.get_value(primary_namespace, "normal"), SECRET_SAMPLE, "普通字符串读取")
	context.end_case()

	context.begin_case("空字符串与不存在键")
	context.expect_ok(storage.set_value(primary_namespace, "empty", ""), "空字符串写入")
	context.expect_value(storage.get_value(primary_namespace, "empty"), "", "空字符串读取")
	context.expect_missing(storage.get_value(primary_namespace, "missing"), "不存在键读取")
	context.end_case()

	context.begin_case("覆盖已有值")
	context.expect_ok(storage.set_value(primary_namespace, "normal", "覆盖值"), "已有值覆盖")
	context.expect_value(storage.get_value(primary_namespace, "normal"), "覆盖值", "覆盖值读取")
	context.end_case()

	context.begin_case("删除幂等性")
	var removed: SecureStorageResult = storage.remove_value(primary_namespace, "normal")
	context.expect_ok(removed, "存在键删除")
	context.check(removed.is_found(), "存在键删除应标记 found")
	var removed_again: SecureStorageResult = storage.remove_value(primary_namespace, "normal")
	context.expect_ok(removed_again, "不存在键重复删除")
	context.check(not removed_again.is_found(), "重复删除应标记未找到")
	context.end_case()

	context.begin_case("命名空间隔离与清空")
	context.expect_ok(storage.set_value(primary_namespace, "isolated", "namespace-a"), "主命名空间写入")
	context.expect_ok(storage.set_value(secondary_namespace, "isolated", "namespace-b"), "副命名空间写入")
	context.expect_value(storage.get_value(primary_namespace, "isolated"), "namespace-a", "主命名空间读取")
	context.expect_value(storage.get_value(secondary_namespace, "isolated"), "namespace-b", "副命名空间读取")
	context.expect_ok(storage.clear_namespace(primary_namespace), "主命名空间清空")
	context.expect_missing(storage.get_value(primary_namespace, "isolated"), "主命名空间清空后读取")
	context.expect_value(storage.get_value(secondary_namespace, "isolated"), "namespace-b", "副命名空间不受影响")
	context.end_case()

	context.begin_case("参数校验")
	var invalid_namespace: SecureStorageResult = storage.get_value("Invalid", "key")
	context.check(not invalid_namespace.is_ok(), "非法 namespace 应失败")
	context.check(invalid_namespace.get_error() == SecureStorageError.INVALID_ARGUMENT, "非法 namespace 应返回 INVALID_ARGUMENT")
	var empty_key: SecureStorageResult = storage.get_value(primary_namespace, "")
	context.check(not empty_key.is_ok(), "空 key 应失败")
	context.check(empty_key.get_error() == SecureStorageError.INVALID_ARGUMENT, "空 key 应返回 INVALID_ARGUMENT")
	context.end_case()

	context.begin_case("清理隔离命名空间")
	context.expect_ok(storage.clear_namespace(primary_namespace), "主命名空间最终清理")
	context.expect_ok(storage.clear_namespace(secondary_namespace), "副命名空间最终清理")
	context.end_case()

	context.end_suite()
	return true
