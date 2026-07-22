#include "secure_storage.hpp"
#include "platforms.hpp"

#include <gdextension_interface.h>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/godot.hpp>

#include <set>
#include <iterator>
#include <string>
#include <unordered_map>

namespace godot {
namespace {

constexpr int64_t MAX_NAMESPACE_LENGTH = 128;
constexpr int64_t MAX_KEY_LENGTH = 512;
constexpr int64_t MAX_VALUE_BYTES = 1024 * 1024;

std::string to_std_string(const String &p_value) {
	const CharString utf8 = p_value.utf8();
	return std::string(utf8.get_data(), static_cast<size_t>(utf8.length()));
}

String make_id(const String &p_namespace, const String &p_key) {
	return p_namespace + String::chr(0x1f) + p_key;
}

class MemoryStorageBackend final : public StorageBackend {
	bool _available = true;
	std::unordered_map<std::string, String> _values;
	std::set<std::string> _corrupt_ids;

public:
	bool is_available() const override { return _available; }

	BackendResult set_value(const String &p_namespace, const String &p_key, const String &p_value) override {
		if (!_available) {
			return BackendResult::failure(SecureStorageError::UNAVAILABLE, "测试后端不可用。");
		}
		const std::string id = to_std_string(make_id(p_namespace, p_key));
		_values[id] = p_value;
		_corrupt_ids.erase(id);
		return BackendResult::success(true);
	}

	BackendResult get_value(const String &p_namespace, const String &p_key) override {
		if (!_available) {
			return BackendResult::failure(SecureStorageError::UNAVAILABLE, "测试后端不可用。");
		}
		const std::string id = to_std_string(make_id(p_namespace, p_key));
		if (_corrupt_ids.count(id) != 0) {
			return BackendResult::failure(SecureStorageError::CORRUPT_DATA, "测试载荷已损坏。");
		}
		const auto value = _values.find(id);
		return value == _values.end() ? BackendResult::success(false) : BackendResult::success(true, value->second);
	}

	BackendResult remove_value(const String &p_namespace, const String &p_key) override {
		if (!_available) {
			return BackendResult::failure(SecureStorageError::UNAVAILABLE, "测试后端不可用。");
		}
		const std::string id = to_std_string(make_id(p_namespace, p_key));
		_corrupt_ids.erase(id);
		return BackendResult::success(_values.erase(id) != 0);
	}

	BackendResult clear_namespace(const String &p_namespace) override {
		if (!_available) {
			return BackendResult::failure(SecureStorageError::UNAVAILABLE, "测试后端不可用。");
		}
		const std::string prefix = to_std_string(p_namespace + String::chr(0x1f));
		for (auto value = _values.begin(); value != _values.end();) {
			value = value->first.rfind(prefix, 0) == 0 ? _values.erase(value) : std::next(value);
		}
		for (auto id = _corrupt_ids.begin(); id != _corrupt_ids.end();) {
			id = id->rfind(prefix, 0) == 0 ? _corrupt_ids.erase(id) : std::next(id);
		}
		return BackendResult::success();
	}

	void set_available(bool p_available) { _available = p_available; }
	void corrupt(const String &p_namespace, const String &p_key) {
		_corrupt_ids.insert(to_std_string(make_id(p_namespace, p_key)));
	}
};

#if !defined(_WIN32) && !defined(__linux__) && !defined(__APPLE__)
class UnavailableStorageBackend final : public StorageBackend {
public:
	bool is_available() const override { return false; }
	BackendResult set_value(const String &, const String &, const String &) override { return unavailable(); }
	BackendResult get_value(const String &, const String &) override { return unavailable(); }
	BackendResult remove_value(const String &, const String &) override { return unavailable(); }
	BackendResult clear_namespace(const String &) override { return unavailable(); }

private:
	static BackendResult unavailable() {
		return BackendResult::failure(SecureStorageError::UNAVAILABLE, "当前平台没有安全存储后端。");
	}
};
#endif

}

void SecureStorageError::_bind_methods() {
	ClassDB::bind_static_method("SecureStorageError", D_METHOD("code_name", "code"), &SecureStorageError::code_name);
	BIND_ENUM_CONSTANT(OK);
	BIND_ENUM_CONSTANT(INVALID_ARGUMENT);
	BIND_ENUM_CONSTANT(UNAVAILABLE);
	BIND_ENUM_CONSTANT(IO_ERROR);
	BIND_ENUM_CONSTANT(CRYPTO_ERROR);
	BIND_ENUM_CONSTANT(CORRUPT_DATA);
	BIND_ENUM_CONSTANT(PERMISSION_DENIED);
	BIND_ENUM_CONSTANT(PLATFORM_ERROR);
	BIND_ENUM_CONSTANT(UNKNOWN);
}

String SecureStorageError::code_name(Code p_code) {
	switch (p_code) {
		case OK: return "OK";
		case INVALID_ARGUMENT: return "INVALID_ARGUMENT";
		case UNAVAILABLE: return "UNAVAILABLE";
		case IO_ERROR: return "IO_ERROR";
		case CRYPTO_ERROR: return "CRYPTO_ERROR";
		case CORRUPT_DATA: return "CORRUPT_DATA";
		case PERMISSION_DENIED: return "PERMISSION_DENIED";
		case PLATFORM_ERROR: return "PLATFORM_ERROR";
		case UNKNOWN: return "UNKNOWN";
	}
	return "UNKNOWN";
}

void SecureStorageResult::_bind_methods() {
	ClassDB::bind_method(D_METHOD("is_ok"), &SecureStorageResult::is_ok);
	ClassDB::bind_method(D_METHOD("is_found"), &SecureStorageResult::is_found);
	ClassDB::bind_method(D_METHOD("get_value"), &SecureStorageResult::get_value);
	ClassDB::bind_method(D_METHOD("get_error"), &SecureStorageResult::get_error);
	ClassDB::bind_method(D_METHOD("get_error_message"), &SecureStorageResult::get_error_message);
}

Ref<SecureStorageResult> SecureStorageResult::ok(bool p_found, const String &p_value) {
	Ref<SecureStorageResult> result;
	result.instantiate();
	result->_ok = true;
	result->_found = p_found;
	result->_value = p_value;
	result->_error = SecureStorageError::OK;
	return result;
}

Ref<SecureStorageResult> SecureStorageResult::err(SecureStorageError::Code p_error, const String &p_message) {
	Ref<SecureStorageResult> result;
	result.instantiate();
	result->_error = p_error;
	result->_error_message = p_message;
	return result;
}

bool SecureStorageResult::is_ok() const { return _ok; }
bool SecureStorageResult::is_found() const { return _ok && _found; }
String SecureStorageResult::get_value() const { return _value; }
SecureStorageError::Code SecureStorageResult::get_error() const { return _error; }
String SecureStorageResult::get_error_message() const { return _error_message; }

BackendResult BackendResult::success(bool p_found, const String &p_value) {
	BackendResult result;
	result.found = p_found;
	result.value = p_value;
	return result;
}

BackendResult BackendResult::failure(SecureStorageError::Code p_error, const String &p_message) {
	BackendResult result;
	result.error = p_error;
	result.message = p_message;
	return result;
}

void SecureStorage::_bind_methods() {
	ClassDB::bind_static_method("SecureStorage", D_METHOD("create_for_testing"), &SecureStorage::create_for_testing);
	ClassDB::bind_method(D_METHOD("is_available"), &SecureStorage::is_available);
	ClassDB::bind_method(D_METHOD("set_value", "namespace", "key", "value"), &SecureStorage::set_value);
	ClassDB::bind_method(D_METHOD("get_value", "namespace", "key"), &SecureStorage::get_value);
	ClassDB::bind_method(D_METHOD("remove_value", "namespace", "key"), &SecureStorage::remove_value);
	ClassDB::bind_method(D_METHOD("clear_namespace", "namespace"), &SecureStorage::clear_namespace);
	ClassDB::bind_method(D_METHOD("set_available_for_testing", "available"), &SecureStorage::set_available_for_testing);
	ClassDB::bind_method(D_METHOD("corrupt_value_for_testing", "namespace", "key"), &SecureStorage::corrupt_value_for_testing);
}

SecureStorage::SecureStorage() : SecureStorage(true) {}

SecureStorage::SecureStorage(bool p_initialize_platform) {
	if (p_initialize_platform) {
		_backend = create_platform_backend();
	}
}

SecureStorage::~SecureStorage() = default;

Ref<SecureStorage> SecureStorage::create_for_testing() {
	Ref<SecureStorage> storage;
	storage.instantiate(false);
	storage->_backend = std::make_unique<MemoryStorageBackend>();
	storage->_testing_backend = true;
	return storage;
}

bool SecureStorage::is_available() const {
	return _backend != nullptr && _backend->is_available();
}

String SecureStorage::_validate_namespace(const String &p_namespace) {
	if (p_namespace.is_empty() || p_namespace.length() > MAX_NAMESPACE_LENGTH) {
		return "namespace 必须为 1 到 128 个字符。";
	}
	for (int64_t index = 0; index < p_namespace.length(); ++index) {
		const char32_t character = p_namespace[index];
		const bool valid = (character >= 'a' && character <= 'z') ||
				(character >= '0' && character <= '9') || character == '.' || character == '-' || character == '_';
		if (!valid) {
			return "namespace 只允许小写 ASCII 字母、数字、点、横线和下划线。";
		}
	}
	return String();
}

String SecureStorage::_validate_key(const String &p_key) {
	if (p_key.is_empty() || p_key.length() > MAX_KEY_LENGTH) {
		return "key 必须为 1 到 512 个字符。";
	}
	for (int64_t index = 0; index < p_key.length(); ++index) {
		if (p_key[index] == 0) {
			return "key 不允许包含空字符。";
		}
	}
	return String();
}

String SecureStorage::_validate_value(const String &p_value) {
	return p_value.utf8().length() > MAX_VALUE_BYTES ? "value 的 UTF-8 编码不得超过 1 MiB。" : String();
}

Ref<SecureStorageResult> SecureStorage::_to_result(const BackendResult &p_result) {
	return p_result.error == SecureStorageError::OK ? SecureStorageResult::ok(p_result.found, p_result.value) :
			SecureStorageResult::err(p_result.error, p_result.message);
}

Ref<SecureStorageResult> SecureStorage::set_value(const String &p_namespace, const String &p_key, const String &p_value) {
	const String namespace_error = _validate_namespace(p_namespace);
	if (!namespace_error.is_empty()) return SecureStorageResult::err(SecureStorageError::INVALID_ARGUMENT, namespace_error);
	const String key_error = _validate_key(p_key);
	if (!key_error.is_empty()) return SecureStorageResult::err(SecureStorageError::INVALID_ARGUMENT, key_error);
	const String value_error = _validate_value(p_value);
	if (!value_error.is_empty()) return SecureStorageResult::err(SecureStorageError::INVALID_ARGUMENT, value_error);
	return _backend == nullptr ? SecureStorageResult::err(SecureStorageError::UNAVAILABLE, "当前构建未提供安全存储后端。") :
			_to_result(_backend->set_value(p_namespace, p_key, p_value));
}

Ref<SecureStorageResult> SecureStorage::get_value(const String &p_namespace, const String &p_key) {
	const String namespace_error = _validate_namespace(p_namespace);
	if (!namespace_error.is_empty()) return SecureStorageResult::err(SecureStorageError::INVALID_ARGUMENT, namespace_error);
	const String key_error = _validate_key(p_key);
	if (!key_error.is_empty()) return SecureStorageResult::err(SecureStorageError::INVALID_ARGUMENT, key_error);
	return _backend == nullptr ? SecureStorageResult::err(SecureStorageError::UNAVAILABLE, "当前构建未提供安全存储后端。") :
			_to_result(_backend->get_value(p_namespace, p_key));
}

Ref<SecureStorageResult> SecureStorage::remove_value(const String &p_namespace, const String &p_key) {
	const String namespace_error = _validate_namespace(p_namespace);
	if (!namespace_error.is_empty()) return SecureStorageResult::err(SecureStorageError::INVALID_ARGUMENT, namespace_error);
	const String key_error = _validate_key(p_key);
	if (!key_error.is_empty()) return SecureStorageResult::err(SecureStorageError::INVALID_ARGUMENT, key_error);
	return _backend == nullptr ? SecureStorageResult::err(SecureStorageError::UNAVAILABLE, "当前构建未提供安全存储后端。") :
			_to_result(_backend->remove_value(p_namespace, p_key));
}

Ref<SecureStorageResult> SecureStorage::clear_namespace(const String &p_namespace) {
	const String namespace_error = _validate_namespace(p_namespace);
	if (!namespace_error.is_empty()) return SecureStorageResult::err(SecureStorageError::INVALID_ARGUMENT, namespace_error);
	return _backend == nullptr ? SecureStorageResult::err(SecureStorageError::UNAVAILABLE, "当前构建未提供安全存储后端。") :
			_to_result(_backend->clear_namespace(p_namespace));
}

void SecureStorage::set_available_for_testing(bool p_available) {
	if (_testing_backend) {
		static_cast<MemoryStorageBackend *>(_backend.get())->set_available(p_available);
	}
}

void SecureStorage::corrupt_value_for_testing(const String &p_namespace, const String &p_key) {
	if (_testing_backend) {
		static_cast<MemoryStorageBackend *>(_backend.get())->corrupt(p_namespace, p_key);
	}
}

#if !defined(_WIN32) && !defined(__linux__) && !defined(__APPLE__)
std::unique_ptr<StorageBackend> create_platform_backend() {
	return std::make_unique<UnavailableStorageBackend>();
}
#endif

}

using namespace godot;

void initialize_secure_storage_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
	GDREGISTER_CLASS(SecureStorageError);
	GDREGISTER_CLASS(SecureStorageResult);
	GDREGISTER_CLASS(SecureStorage);
}

void uninitialize_secure_storage_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
}

extern "C" GDExtensionBool GDE_EXPORT secure_storage_library_init(
		GDExtensionInterfaceGetProcAddress p_get_proc_address,
		GDExtensionClassLibraryPtr p_library,
		GDExtensionInitialization *r_initialization) {
	GDExtensionBinding::InitObject init_object(p_get_proc_address, p_library, r_initialization);
	init_object.register_initializer(initialize_secure_storage_module);
	init_object.register_terminator(uninitialize_secure_storage_module);
	init_object.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);
	return init_object.init();
}
