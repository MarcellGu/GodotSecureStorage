/*
 * 原生公共层：验证参数、协调并发、序列化后端结果并注册 GDExtension。
 */
#include "backend.hpp"

#include <gdextension_interface.h>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/godot.hpp>

#include <mutex>

namespace godot {

namespace {

// 与 GDScript、Kotlin 公开参数边界保持一致。
constexpr int64_t MAX_DOMAIN_LENGTH = 128;
constexpr int64_t MAX_KEY_LENGTH = 512;
// Windows Generic Credential 的单条 CredentialBlob 上限。
constexpr int64_t MAX_VALUE_BYTES = 5 * 512;

std::mutex &backend_mutex() {
	static std::mutex mutex;
	return mutex;
}

// 所有原生存储操作共享一把进程内全局锁。
template <typename Operation>
BackendResult with_backend_lock(Operation &&p_operation) {
	const std::lock_guard<std::mutex> lock(backend_mutex());
	return p_operation();
}

} // namespace

BackendResult BackendResult::success(
		const String &p_domain,
		const String &p_key,
		const String &p_value) {
	BackendResult result;
	result.domain = p_domain;
	result.key = p_key;
	result.value = p_value;
	return result;
}

BackendResult BackendResult::failure(Code p_code, const String &p_message) {
	BackendResult result;
	result.code = p_code;
	result.message = p_message;
	return result;
}

static Dictionary backend_result_to_dictionary(const BackendResult &p_result) {
	Dictionary result;
	result["code"] = static_cast<int64_t>(p_result.code);
	result["domain"] = p_result.domain;
	result["key"] = p_result.key;
	result["value"] = p_result.value;
	result["message"] = p_result.message;
	return result;
}

static BackendResult validate_domain_argument(const String &p_domain) {
	if (p_domain.is_empty() || p_domain.length() > MAX_DOMAIN_LENGTH) {
		return BackendResult::failure(
				BackendResult::INVALID_ARGUMENT,
				"domain 必须为 1 到 128 个字符。");
	}
	if (p_domain == "." || p_domain == "..") {
		return BackendResult::failure(
				BackendResult::INVALID_ARGUMENT,
				"domain 不允许使用当前目录或父目录标记。");
	}
	if (p_domain.ends_with(".")) {
		return BackendResult::failure(
				BackendResult::INVALID_ARGUMENT,
				"domain 不允许以点结尾。");
	}
	for (int64_t index = 0; index < p_domain.length(); ++index) {
		const char32_t character = p_domain[index];
		const bool valid =
				(character >= 'a' && character <= 'z') ||
				(character >= '0' && character <= '9') ||
				character == '.' ||
				character == '-' ||
				character == '_';
		if (!valid) {
			return BackendResult::failure(
					BackendResult::INVALID_ARGUMENT,
					"domain 只允许小写 ASCII 字母、数字、点、横线和下划线。");
		}
	}
	// Windows 保留设备名也适用于 con.txt 等带扩展形式。
	const String stem = p_domain.get_slice(".", 0);
	const bool reserved_name =
			stem == "con" ||
			stem == "prn" ||
			stem == "aux" ||
			stem == "nul";
	const bool reserved_port = stem.length() == 4 &&
			(stem.substr(0, 3) == "com" || stem.substr(0, 3) == "lpt") &&
			stem[3] >= '1' && stem[3] <= '9';
	if (reserved_name || reserved_port) {
		return BackendResult::failure(
				BackendResult::INVALID_ARGUMENT,
				"domain 不允许使用 Windows 保留设备名。");
	}
	return BackendResult::success();
}

static BackendResult validate_key_argument(const String &p_key) {
	if (p_key.is_empty() || p_key.length() > MAX_KEY_LENGTH) {
		return BackendResult::failure(
				BackendResult::INVALID_ARGUMENT,
				"key 必须为 1 到 512 个字符。");
	}
	for (int64_t index = 0; index < p_key.length(); ++index) {
		if (p_key[index] == 0) {
			return BackendResult::failure(
					BackendResult::INVALID_ARGUMENT,
					"key 不允许包含空字符。");
		}
	}
	return BackendResult::success();
}

static BackendResult validate_value_argument(const String &p_value) {
	for (int64_t index = 0; index < p_value.length(); ++index) {
		if (p_value[index] == 0) {
			return BackendResult::failure(
					BackendResult::INVALID_ARGUMENT,
					"value 不允许包含空字符。");
		}
	}
	CharString utf8 = p_value.utf8();
	const bool within_limit = utf8.length() <= MAX_VALUE_BYTES;
	// 缩短 UTF-8 明文副本寿命；volatile 防止编译器删除覆盖写入。
	volatile char *bytes = utf8.length() > 0
			? utf8.ptrw()
			: nullptr;
	for (int64_t index = 0; index < utf8.length(); ++index) {
		bytes[index] = 0;
	}
	if (!within_limit) {
		return BackendResult::failure(
				BackendResult::INVALID_ARGUMENT,
				"value 的 UTF-8 编码不得超过 2560 字节。");
	}
	return BackendResult::success();
}

// 严格验证平台读出的 UTF-8：拒绝 NUL、过长编码、代理项和越界码点。
bool is_valid_utf8_value_bytes(const uint8_t *p_bytes, size_t p_length) {
	if (p_length > 0 && p_bytes == nullptr) {
		return false;
	}
	size_t index = 0;
	while (index < p_length) {
		const uint8_t first = p_bytes[index];
		if (first == 0) {
			return false;
		}
		if (first <= 0x7f) {
			++index;
			continue;
		}
		if (first >= 0xc2 && first <= 0xdf) {
			if (index + 1 >= p_length ||
					(p_bytes[index + 1] & 0xc0) != 0x80) {
				return false;
			}
			index += 2;
			continue;
		}
		if (first >= 0xe0 && first <= 0xef) {
			if (index + 2 >= p_length ||
					(p_bytes[index + 2] & 0xc0) != 0x80) {
				return false;
			}
			const uint8_t second = p_bytes[index + 1];
			const bool valid_second =
					(first == 0xe0 && second >= 0xa0 && second <= 0xbf) ||
					(first >= 0xe1 && first <= 0xec && (second & 0xc0) == 0x80) ||
					(first == 0xed && second >= 0x80 && second <= 0x9f) ||
					(first >= 0xee && first <= 0xef && (second & 0xc0) == 0x80);
			if (!valid_second) {
				return false;
			}
			index += 3;
			continue;
		}
		if (first >= 0xf0 && first <= 0xf4) {
			if (index + 3 >= p_length ||
					(p_bytes[index + 2] & 0xc0) != 0x80 ||
					(p_bytes[index + 3] & 0xc0) != 0x80) {
				return false;
			}
			const uint8_t second = p_bytes[index + 1];
			const bool valid_second =
					(first == 0xf0 && second >= 0x90 && second <= 0xbf) ||
					(first >= 0xf1 && first <= 0xf3 && (second & 0xc0) == 0x80) ||
					(first == 0xf4 && second >= 0x80 && second <= 0x8f);
			if (!valid_second) {
				return false;
			}
			index += 4;
			continue;
		}
		return false;
	}
	return true;
}

void NativeBackend::_bind_methods() {
	ClassDB::bind_method(
			D_METHOD("set_value", "domain", "key", "value"),
			&NativeBackend::set_value);
	ClassDB::bind_method(
			D_METHOD("get_value", "domain", "key"),
			&NativeBackend::get_value);
	ClassDB::bind_method(
			D_METHOD("remove_value", "domain", "key"),
			&NativeBackend::remove_value);
	ClassDB::bind_method(
			D_METHOD("clear_domain", "domain"),
			&NativeBackend::clear_domain);
}

Dictionary NativeBackend::set_value(
		const String &p_domain,
		const String &p_key,
		const String &p_value) {
	BackendResult result = validate_domain_argument(p_domain);
	if (result.code == BackendResult::OK) {
		result = validate_key_argument(p_key);
	}
	if (result.code == BackendResult::OK) {
		result = validate_value_argument(p_value);
	}
	if (result.code == BackendResult::OK) {
		result = with_backend_lock(
				[this, &p_domain, &p_key, &p_value]() {
					const BackendResult stored =
							_set_value(p_domain, p_key, p_value);
					if (stored.code != BackendResult::OK) {
						return stored;
					}
					// 写入和读回必须处于同一全局临界区。
					return _get_value(p_domain, p_key);
				});
	}
	return backend_result_to_dictionary(result);
}

Dictionary NativeBackend::get_value(
		const String &p_domain,
		const String &p_key) {
	BackendResult result = validate_domain_argument(p_domain);
	if (result.code == BackendResult::OK) {
		result = validate_key_argument(p_key);
	}
	if (result.code == BackendResult::OK) {
		result = with_backend_lock(
				[this, &p_domain, &p_key]() {
					return _get_value(p_domain, p_key);
				});
	}
	return backend_result_to_dictionary(result);
}

Dictionary NativeBackend::remove_value(
		const String &p_domain,
		const String &p_key) {
	BackendResult result = validate_domain_argument(p_domain);
	if (result.code == BackendResult::OK) {
		result = validate_key_argument(p_key);
	}
	if (result.code == BackendResult::OK) {
		result = with_backend_lock(
				[this, &p_domain, &p_key]() {
					return _remove_value(p_domain, p_key);
				});
	}
	return backend_result_to_dictionary(result);
}

Dictionary NativeBackend::clear_domain(const String &p_domain) {
	BackendResult result = validate_domain_argument(p_domain);
	if (result.code == BackendResult::OK) {
		result = with_backend_lock(
				[this, &p_domain]() {
					return _clear_domain(p_domain);
				});
	}
	return backend_result_to_dictionary(result);
}

} // namespace godot

using namespace godot;

void initialize_secure_storage_module(ModuleInitializationLevel p_level) {
	if (p_level == MODULE_INITIALIZATION_LEVEL_SCENE) {
		GDREGISTER_ABSTRACT_CLASS(NativeBackend);
		register_platform_backend();
	}
}

void uninitialize_secure_storage_module(ModuleInitializationLevel p_level) {
	// 当前资源由 RefCounted、RAII 和函数内 static 管理。
	(void)p_level;
}

// Godot 加载动态库时查找的固定入口。
extern "C" GDExtensionBool GDE_EXPORT secure_storage_library_init(
		GDExtensionInterfaceGetProcAddress p_get_proc_address,
		GDExtensionClassLibraryPtr p_library,
		GDExtensionInitialization *r_initialization) {
	GDExtensionBinding::InitObject init_object(
			p_get_proc_address,
			p_library,
			r_initialization);
	init_object.register_initializer(initialize_secure_storage_module);
	init_object.register_terminator(uninitialize_secure_storage_module);
	init_object.set_minimum_library_initialization_level(
			MODULE_INITIALIZATION_LEVEL_SCENE);
	return init_object.init();
}
