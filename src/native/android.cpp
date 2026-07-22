#include "platforms.hpp"

#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/object.hpp>
#include <godot_cpp/variant/variant.hpp>

#include <memory>

namespace godot {
namespace {

class AndroidStorageBackend final : public StorageBackend {
	Object *_plugin = nullptr;

	BackendResult _last_result(bool p_found = false, const String &p_value = String()) const {
		if (_plugin == nullptr) {
			return BackendResult::failure(SecureStorageError::UNAVAILABLE, "Android 安全存储插件未装载。");
		}
		const Variant code_value = _plugin->call("get_last_error_code");
		const int64_t code = code_value.get_type() == Variant::INT ? static_cast<int64_t>(code_value) : SecureStorageError::UNKNOWN;
		if (code == SecureStorageError::OK) {
			return BackendResult::success(p_found, p_value);
		}
		const Variant message_value = _plugin->call("get_last_error_message");
		const String message = message_value.get_type() == Variant::STRING ? static_cast<String>(message_value) : "Android 安全存储操作失败。";
		if (code < SecureStorageError::INVALID_ARGUMENT || code > SecureStorageError::UNKNOWN) {
			return BackendResult::failure(SecureStorageError::UNKNOWN, message);
		}
		return BackendResult::failure(static_cast<SecureStorageError::Code>(code), message);
	}

public:
	AndroidStorageBackend() {
		Engine *engine = Engine::get_singleton();
		if (engine != nullptr && engine->has_singleton("SecureStorageAndroid")) {
			_plugin = engine->get_singleton("SecureStorageAndroid");
		}
	}

	bool is_available() const override {
		if (_plugin == nullptr) {
			return false;
		}
		const Variant available = _plugin->call("is_available");
		return available.get_type() == Variant::BOOL && static_cast<bool>(available);
	}

	BackendResult set_value(const String &p_namespace, const String &p_key, const String &p_value) override {
		if (_plugin == nullptr) {
			return _last_result();
		}
		_plugin->call("set_value", p_namespace, p_key, p_value);
		return _last_result(true);
	}

	BackendResult get_value(const String &p_namespace, const String &p_key) override {
		if (_plugin == nullptr) {
			return _last_result();
		}
		const Variant value = _plugin->call("get_value", p_namespace, p_key);
		const BackendResult operation = _last_result();
		if (operation.error != SecureStorageError::OK) {
			return operation;
		}
		if (value.get_type() == Variant::NIL) {
			return BackendResult::success(false);
		}
		if (value.get_type() != Variant::STRING) {
			return BackendResult::failure(SecureStorageError::PLATFORM_ERROR, "Android 插件返回了无效类型。");
		}
		return BackendResult::success(true, static_cast<String>(value));
	}

	BackendResult remove_value(const String &p_namespace, const String &p_key) override {
		if (_plugin == nullptr) {
			return _last_result();
		}
		const Variant found = _plugin->call("remove_value", p_namespace, p_key);
		const bool was_found = found.get_type() == Variant::BOOL && static_cast<bool>(found);
		return _last_result(was_found);
	}

	BackendResult clear_namespace(const String &p_namespace) override {
		if (_plugin == nullptr) {
			return _last_result();
		}
		_plugin->call("clear_namespace", p_namespace);
		return _last_result();
	}
};

} // namespace

std::unique_ptr<StorageBackend> create_platform_backend() {
	return std::make_unique<AndroidStorageBackend>();
}

} // namespace godot
