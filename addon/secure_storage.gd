@icon("./icon.svg")
class_name SecureStorage
extends RefCounted

## 跨平台安全存储入口。
##
## 所有操作均为同步调用，并统一返回 [StorageResult]。
## 原生与 Android 后端使用内部 Dictionary ABI；调用方只会看到
## [StorageSuccess] 或 [StorageError]。


## 成功与错误结果的空基类，用于统一公开方法的返回类型。
class StorageResult extends RefCounted:
	pass


## 已由平台后端确认的成功结果。
class StorageSuccess extends StorageResult:
	## 本次操作所属的存储隔离域。
	var domain: String
	## 本次操作对应的键；[method clear_domain] 成功时为空。
	var key: String
	## 平台实际读回的值；删除或清空成功时为空。
	var value: String

	## 只允许 SecureStorage 根据后端确认结果创建成功对象。
	func _init(
			p_domain: String,
			p_key: String,
			p_value: String
	) -> void:
		domain = p_domain
		key = p_key
		value = p_value


## 携带错误类型与安全诊断消息的失败结果。
class StorageError extends StorageResult:
	## 公开错误类别。数值与内部 ABI 的 code=1..4 保持稳定对应。
	enum ErrorType {
	# 调用参数不满足公开约束。
		INVALID_ARGUMENT = 1,
	# 查询目标不存在。
		NOT_FOUND = 2,
	# 系统安全存储或平台能力失败。
		PLATFORM_ERROR = 3,
	# 后端结果损坏或无法安全归类。
		UNKNOWN_ERROR = 4,
	}

	## 可供调用方分支判断的错误类别。
	var type: ErrorType = ErrorType.UNKNOWN_ERROR
	## 不包含秘密值的非空诊断消息。
	var message: String

	## 创建一个公开错误结果。
	func _init(p_type: ErrorType, p_message: String) -> void:
		type = p_type
		message = p_message


# Android 后端由 Godot Android Plugin v2 注册为 Engine singleton。
const ANDROID_BACKEND: StringName = &"AndroidBackend"

# 桌面与 Apple 平台后端由 GDExtension 注册到 ClassDB。
const NATIVE_BACKENDS: Dictionary = {
	"Windows": &"WindowsBackend",
	"Linux": &"LinuxBackend",
	"macOS": &"AppleBackend",
	"iOS": &"AppleBackend",
}
const MAX_DOMAIN_LENGTH: int = 128
const MAX_KEY_LENGTH: int = 512
const MAX_VALUE_BYTES: int = 5 * 512

# 构造时解析一次当前平台后端；null 表示当前平台没有可用实现。
var _backend: Object = null


func _init() -> void:
	_backend = _create_platform_backend()


## 同步写入 [param value]，并在同一个受锁操作内从平台存储读回。
##
## 成功时返回 [StorageSuccess]，其中 value 是平台读回值而非输入参数的直接副本。
## 参数无效、后端不可用或读回值不一致时返回 [StorageError]。
func set_value(domain: String, key: String, value: String) -> StorageResult:
	if (
			not _is_valid_domain(domain)
			or not _is_valid_key(key)
			or not _is_valid_value(value)
	):
		return StorageError.new(
				StorageError.ErrorType.INVALID_ARGUMENT,
				"domain、key 或 value 参数无效。"
		)
	if not _backend_has_method(&"set_value"):
		return StorageError.new(
				StorageError.ErrorType.PLATFORM_ERROR,
				"当前平台存储后端不可用。"
		)
	var result: StorageResult = _decode_result(
			_backend.call("set_value", domain, key, value)
	)
	if result is StorageSuccess and result.value != value:
		return StorageError.new(
				StorageError.ErrorType.PLATFORM_ERROR,
				"平台写入后的读回值与输入不一致。"
		)
	return result


## 同步读取 [param domain] 下的 [param key]。
##
## 目标不存在时返回 type 为 [constant StorageError.ErrorType.NOT_FOUND]
## 的 [StorageError]；空字符串是合法的成功值。
func get_value(domain: String, key: String) -> StorageResult:
	if not _is_valid_domain(domain) or not _is_valid_key(key):
		return StorageError.new(
				StorageError.ErrorType.INVALID_ARGUMENT,
				"domain 或 key 参数无效。"
		)
	if not _backend_has_method(&"get_value"):
		return StorageError.new(
				StorageError.ErrorType.PLATFORM_ERROR,
				"当前平台存储后端不可用。"
		)
	return _decode_result(_backend.call("get_value", domain, key))


## 同步发出幂等平台删除请求。
##
## 删除原本不存在的目标也是成功；成功结果的 value 为空字符串。
func remove_value(domain: String, key: String) -> StorageResult:
	if not _is_valid_domain(domain) or not _is_valid_key(key):
		return StorageError.new(
				StorageError.ErrorType.INVALID_ARGUMENT,
				"domain 或 key 参数无效。"
		)
	if not _backend_has_method(&"remove_value"):
		return StorageError.new(
				StorageError.ErrorType.PLATFORM_ERROR,
				"当前平台存储后端不可用。"
		)
	return _decode_result(_backend.call("remove_value", domain, key))


## 同步清空整个 [param domain]。
##
## 该操作没有单一键值，成功结果的 key 和 value 均为空字符串。
func clear_domain(domain: String) -> StorageResult:
	if not _is_valid_domain(domain):
		return StorageError.new(
				StorageError.ErrorType.INVALID_ARGUMENT,
				"domain 参数无效。"
		)
	if not _backend_has_method(&"clear_domain"):
		return StorageError.new(
				StorageError.ErrorType.PLATFORM_ERROR,
				"当前平台存储后端不可用。"
		)
	return _decode_result(_backend.call("clear_domain", domain))


# Android 使用 Engine singleton；其他平台实例化对应的原生 RefCounted 后端。
func _create_platform_backend() -> Object:
	if OS.get_name() == "Android":
		if Engine.has_singleton(ANDROID_BACKEND):
			return Engine.get_singleton(ANDROID_BACKEND)
		return null

	var backend_name: StringName = NATIVE_BACKENDS.get(
			OS.get_name(),
			StringName()
	)
	if backend_name.is_empty() or not ClassDB.can_instantiate(backend_name):
		return null
	return ClassDB.instantiate(backend_name) as Object


# Android 的 JNISingleton 通过 has_java_method() 暴露 Kotlin 方法。
func _backend_has_method(method: StringName) -> bool:
	if _backend == null:
		return false
	if OS.get_name() == "Android":
		return _backend.has_java_method(method)
	return _backend.has_method(method)


# 解码后端固定 ABI：
# code:int、domain:String、key:String、value:String、message:String。
# 成功必须为 code=0 且 message 为空；错误必须清空 domain/key/value，
# 使用 code=1..4 并提供非空 message。任何协议偏差都降级为 UNKNOWN_ERROR。
func _decode_result(raw_result: Variant) -> StorageResult:
	var invalid_result: StorageError = StorageError.new(
			StorageError.ErrorType.UNKNOWN_ERROR,
			"平台存储后端返回了无效结果。"
	)
	if not raw_result is Dictionary:
		return invalid_result
	var result: Dictionary = raw_result
	if result.size() != 5:
		return invalid_result
	for field: String in ["code", "domain", "key", "value", "message"]:
		if not result.has(field):
			return invalid_result
	if (
			not result["code"] is int
			or not result["domain"] is String
			or not result["key"] is String
			or not result["value"] is String
			or not result["message"] is String
	):
		return invalid_result

	var backend_result: int = result["code"]
	var result_domain: String = result["domain"]
	var result_key: String = result["key"]
	var result_value: String = result["value"]
	var message: String = result["message"]
	if backend_result == 0:
		if not message.is_empty():
			return invalid_result
		return StorageSuccess.new(
				result_domain,
				result_key,
				result_value
		)

	if (
			not result_domain.is_empty()
			or not result_key.is_empty()
			or not result_value.is_empty()
	):
		return invalid_result
	if (
			backend_result < StorageError.ErrorType.INVALID_ARGUMENT
			or backend_result > StorageError.ErrorType.UNKNOWN_ERROR
			or message.is_empty()
	):
		return invalid_result
	return StorageError.new(backend_result, message)


# domain 会进入平台服务名或目录标识，因此使用所有平台一致的安全字符集，
# 并统一拒绝 Windows 设备保留名。
static func _is_valid_domain(domain: String) -> bool:
	if domain.is_empty() or domain.length() > MAX_DOMAIN_LENGTH:
		return false
	if domain == "." or domain == ".." or domain.ends_with("."):
		return false
	for character: String in domain:
		var code: int = character.unicode_at(0)
		var valid: bool = (
				(code >= 97 and code <= 122)
				or (code >= 48 and code <= 57)
				or character == "."
				or character == "-"
				or character == "_"
		)
		if not valid:
			return false

	var stem: String = domain.get_slice(".", 0)
	var reserved_name: bool = stem in ["con", "prn", "aux", "nul"]
	var reserved_port: bool = (
			stem.length() == 4
			and stem.substr(0, 3) in ["com", "lpt"]
			and stem[3] >= "1"
			and stem[3] <= "9"
	)
	return not reserved_name and not reserved_port


# key 不能为空、不能包含 NUL，并限制 Unicode 字符数量。
static func _is_valid_key(key: String) -> bool:
	return (
			not key.is_empty()
			and key.length() <= MAX_KEY_LENGTH
			and not _contains_nul(key)
	)


# value 允许为空，但不能包含 NUL，且 UTF-8 编码不得超过 2560 字节。
static func _is_valid_value(value: String) -> bool:
	if _contains_nul(value):
		return false
	var utf8: PackedByteArray = value.to_utf8_buffer()
	var within_limit: bool = utf8.size() <= MAX_VALUE_BYTES
	utf8.fill(0)
	return within_limit


# 显式扫描 Unicode 字符，避免把 NUL 传入 C API 或平台存储接口。
static func _contains_nul(value: String) -> bool:
	for index: int in value.length():
		if value.unicode_at(index) == 0:
			return true
	return false
