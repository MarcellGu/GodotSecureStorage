class_name StorageService
extends RefCounted

var _storage: SecureStorage


## 创建统一存储服务；无参数，实例只持有原生 RefCounted，不执行读写，原生扩展未加载时脚本无法实例化。
func _init() -> void:
	_storage = SecureStorage.new()


## 返回当前平台安全后端是否可用；无参数和副作用，false 表示调用方不应尝试明文回退。
func is_available() -> bool:
	return _storage.is_available()


## 写入字符串；namespace 与 key 必须通过原生校验，value 可为空，返回统一结果且失败时不会写入明文替代存储。
func set_value(namespace: String, key: String, value: String) -> SecureStorageResult:
	return _storage.set_value(namespace, key, value)


## 读取字符串；namespace 与 key 必须合法，返回结果的 is_found() 可区分不存在和空字符串，无额外副作用。
func get_value(namespace: String, key: String) -> SecureStorageResult:
	return _storage.get_value(namespace, key)


## 删除键；namespace 与 key 必须合法，不存在的键返回成功且 is_found() 为 false，不创建替代数据。
func remove_value(namespace: String, key: String) -> SecureStorageResult:
	return _storage.remove_value(namespace, key)


## 清空命名空间；namespace 必须合法，返回统一结果，会不可逆删除该命名空间内由本插件创建的数据。
func clear_namespace(namespace: String) -> SecureStorageResult:
	return _storage.clear_namespace(namespace)
