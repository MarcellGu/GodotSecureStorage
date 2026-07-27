/*
 * domain 直接作为 SecretSchema 名，key 是唯一查询属性。
 * 不添加库或项目身份前缀；libsecret 同步调用可能阻塞，不应在 UI 线程执行。
 */
#include "backend.hpp"

#include <gio/gio.h>
#include <godot_cpp/core/class_db.hpp>
#include <libsecret/secret.h>

#include <cstring>

namespace godot {

namespace {

constexpr size_t MAX_VALUE_BYTES = 5 * 512;

SecretSchema domain_schema(const char *p_domain) {
	SecretSchema schema{};
	// schema 借用 p_domain，调用方必须保持其缓冲区存活。
	schema.name = p_domain;
	schema.flags = SECRET_SCHEMA_NONE;
	schema.attributes[0] = { "key", SECRET_SCHEMA_ATTRIBUTE_STRING };
	return schema;
}

class LinuxBackend final : public NativeBackend {
	GDCLASS(LinuxBackend, NativeBackend)

private:
	static String format_message(const GError *p_error) {
		return "(" + String::num_int64(p_error->code) + ") " +
				String::utf8(p_error->message);
	}

protected:
	static void _bind_methods() {}

	BackendResult _set_value(
			const String &p_domain,
			const String &p_key,
			const String &p_value) override {
		CharString domain = p_domain.utf8();
		CharString key = p_key.utf8();
		CharString value = p_value.utf8();
		// 可见标签不得包含秘密值。
		CharString label = (p_domain + String(" / ") + p_key).utf8();
		SecretSchema item_schema = domain_schema(domain.get_data());
		GError *error = nullptr;
		secret_password_store_sync(
				&item_schema,
				SECRET_COLLECTION_DEFAULT,
				label.get_data(),
				value.get_data(),
				nullptr,
				&error,
				"key",
				key.get_data(),
				nullptr);
		if (error != nullptr) {
			String message = format_message(error);
			g_error_free(error);
			return BackendResult::failure(BackendResult::PLATFORM_ERROR, message);
		}
		return BackendResult::success(p_domain, p_key, p_value);
	}

	BackendResult _get_value(
			const String &p_domain,
			const String &p_key) override {
		CharString domain = p_domain.utf8();
		CharString key = p_key.utf8();
		SecretSchema item_schema = domain_schema(domain.get_data());
		GError *error = nullptr;
		gchar *password = secret_password_lookup_sync(
				&item_schema,
				nullptr,
				&error,
				"key",
				key.get_data(),
				nullptr);
		if (error != nullptr) {
			String message = format_message(error);
			g_error_free(error);
			return BackendResult::failure(BackendResult::PLATFORM_ERROR, message);
		}
		if (password == nullptr) {
			return BackendResult::failure(
					BackendResult::NOT_FOUND,
					"Secret Service 中不存在目标项目。");
		}
		size_t length = std::strlen(password);
		// 复核持久化载荷，避免将损坏数据交给 Godot。
		if (length > MAX_VALUE_BYTES ||
				!is_valid_utf8_value_bytes(
						reinterpret_cast<const uint8_t *>(password), length)) {
			secret_password_free(password);
			return BackendResult::failure(
					BackendResult::PLATFORM_ERROR,
					"Secret Service 返回了无效 UTF-8 载荷。");
		}
		String value = length == 0
				? String()
				: String::utf8(password, static_cast<int64_t>(length));
		secret_password_free(password);
		return BackendResult::success(p_domain, p_key, value);
	}

	BackendResult _remove_value(
			const String &p_domain,
			const String &p_key) override {
		CharString domain = p_domain.utf8();
		CharString key = p_key.utf8();
		SecretSchema item_schema = domain_schema(domain.get_data());
		GError *error = nullptr;
		secret_password_clear_sync(
				&item_schema,
				nullptr,
				&error,
				"key",
				key.get_data(),
				nullptr);
		if (error != nullptr) {
			String message = format_message(error);
			g_error_free(error);
			return BackendResult::failure(BackendResult::PLATFORM_ERROR, message);
		}
		return BackendResult::success(p_domain, p_key);
	}

	BackendResult _clear_domain(const String &p_domain) override {
		CharString domain = p_domain.utf8();
		SecretSchema item_schema = domain_schema(domain.get_data());
		GError *error = nullptr;
		secret_password_clear_sync(
				&item_schema,
				nullptr,
				&error,
				nullptr);
		if (error != nullptr) {
			String message = format_message(error);
			g_error_free(error);
			return BackendResult::failure(BackendResult::PLATFORM_ERROR, message);
		}
		return BackendResult::success(p_domain);
	}
};

} // namespace

void register_platform_backend() {
	GDREGISTER_CLASS(LinuxBackend);
}

} // namespace godot
