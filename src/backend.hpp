#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string.hpp>

#include <cstddef>
#include <cstdint>

namespace godot {

/*
 * 所有原生后端共用的唯一结果类型。
 *
 * code/domain/key/value/message 与内部 Dictionary ABI 一一对应。成功结果携带
 * domain/key/value 且 message 为空；错误结果清空业务字段并携带非空 message。
 */
struct BackendResult {
	enum Code {
		OK = 0,
		INVALID_ARGUMENT = 1,
		NOT_FOUND = 2,
		PLATFORM_ERROR = 3,
		UNKNOWN_ERROR = 4,
	};

	Code code = OK;
	String domain;
	String key;
	String value;
	String message;

	static BackendResult success(
			const String &p_domain = String(),
			const String &p_key = String(),
			const String &p_value = String()
	);
	static BackendResult failure(Code p_code, const String &p_message);
};

/*
 * NativeBackend 统一绑定脚本方法、验证输入并序列化 BackendResult；各平台只实现
 * 四个同步存储钩子。
 */
class NativeBackend : public RefCounted {
	GDCLASS(NativeBackend, RefCounted)

protected:
	static void _bind_methods();

	virtual BackendResult _set_value(
			const String &p_domain,
			const String &p_key,
			const String &p_value) = 0;
	virtual BackendResult _get_value(
			const String &p_domain,
			const String &p_key) = 0;
	virtual BackendResult _remove_value(
			const String &p_domain,
			const String &p_key) = 0;
	virtual BackendResult _clear_domain(
			const String &p_domain) = 0;

public:
	Dictionary set_value(const String &p_domain, const String &p_key, const String &p_value);
	Dictionary get_value(const String &p_domain, const String &p_key);
	Dictionary remove_value(const String &p_domain, const String &p_key);
	Dictionary clear_domain(const String &p_domain);
};

bool is_valid_utf8_value_bytes(const uint8_t *p_bytes, size_t p_length);
void register_platform_backend();

} // namespace godot
