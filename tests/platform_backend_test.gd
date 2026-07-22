extends RefCounted

const TEST_CONTEXT = preload("res://tests/test_context.gd")
const STORAGE_CONTRACT_TEST = preload("res://tests/storage_contract_test.gd")
const PRIMARY_NAMESPACE: String = "com.marcellgu.securestorage.integration_test"
const SECONDARY_NAMESPACE: String = "com.marcellgu.securestorage.integration_other"


## 对当前系统安全存储执行统一契约；context 收集结构化结果，无返回值，仅操作两个专用 namespace 并在契约结束时清理。
func run(context: TEST_CONTEXT) -> void:
	var storage: SecureStorage = SecureStorage.new()
	var contract: STORAGE_CONTRACT_TEST = STORAGE_CONTRACT_TEST.new()
	contract.run(
		context,
		"真实平台后端统一契约 [%s]" % OS.get_name(),
		storage,
		PRIMARY_NAMESPACE,
		SECONDARY_NAMESPACE
	)

	storage = null
	context.begin_suite("真实平台后端生命周期 [%s]" % OS.get_name())
	context.begin_case("销毁后重新创建")
	var reopened_storage: SecureStorage = SecureStorage.new()
	context.check(reopened_storage.is_available(), "重新创建的真实平台后端应可用")
	context.end_case()
	context.end_suite()
