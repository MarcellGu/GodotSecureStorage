#include "platforms.hpp"

#include <dlfcn.h>
#include <libsecret/secret.h>

#include <memory>

namespace godot {
namespace {

SecretSchema storage_schema(const CharString &p_namespace) {
	return {
		p_namespace.get_data(),
		SECRET_SCHEMA_NONE,
		{
			{ "key", SECRET_SCHEMA_ATTRIBUTE_STRING },
			{ nullptr, static_cast<SecretSchemaAttributeType>(0) },
		}
	};
}

class LinuxStorageBackend final : public StorageBackend {
	using StoreFunction = gboolean (*)(const SecretSchema *, const gchar *, const gchar *, const gchar *, GCancellable *, GError **, ...);
	using LookupFunction = gchar *(*)(const SecretSchema *, GCancellable *, GError **, ...);
	using ClearFunction = gboolean (*)(const SecretSchema *, GCancellable *, GError **, ...);
	using PasswordFreeFunction = void (*)(gchar *);
	using ServiceGetFunction = SecretService *(*)(SecretServiceFlags, GCancellable *, GError **);
	using ErrorFreeFunction = void (*)(GError *);
	using ObjectUnrefFunction = void (*)(gpointer);

	StoreFunction _store = nullptr;
	LookupFunction _lookup = nullptr;
	ClearFunction _clear = nullptr;
	PasswordFreeFunction _password_free = nullptr;
	ErrorFreeFunction _error_free = nullptr;
	ObjectUnrefFunction _object_unref = nullptr;
	bool _available = false;

	void _release_error(GError *p_error) const {
		if (p_error != nullptr && _error_free != nullptr) {
			_error_free(p_error);
		}
	}

public:
	LinuxStorageBackend() {
		// libsecret registers process-global GObject types that cannot safely be
		// unregistered and registered again. Keep these handles for the process
		// lifetime so repeated SecureStorage instances reuse the same library.
		static void *const secret_handle = dlopen("libsecret-1.so.0", RTLD_NOW | RTLD_LOCAL);
		static void *const glib_handle = dlopen("libglib-2.0.so.0", RTLD_NOW | RTLD_LOCAL);
		static void *const gobject_handle = dlopen("libgobject-2.0.so.0", RTLD_NOW | RTLD_LOCAL);
		if (secret_handle == nullptr || glib_handle == nullptr || gobject_handle == nullptr) {
			return;
		}
		_store = reinterpret_cast<StoreFunction>(dlsym(secret_handle, "secret_password_store_sync"));
		_lookup = reinterpret_cast<LookupFunction>(dlsym(secret_handle, "secret_password_lookup_sync"));
		_clear = reinterpret_cast<ClearFunction>(dlsym(secret_handle, "secret_password_clear_sync"));
		_password_free = reinterpret_cast<PasswordFreeFunction>(dlsym(secret_handle, "secret_password_free"));
		const auto service_get = reinterpret_cast<ServiceGetFunction>(dlsym(secret_handle, "secret_service_get_sync"));
		_error_free = reinterpret_cast<ErrorFreeFunction>(dlsym(glib_handle, "g_error_free"));
		_object_unref = reinterpret_cast<ObjectUnrefFunction>(dlsym(gobject_handle, "g_object_unref"));
		if (_store == nullptr || _lookup == nullptr || _clear == nullptr || _password_free == nullptr ||
				service_get == nullptr || _error_free == nullptr || _object_unref == nullptr) {
			return;
		}
		GError *error = nullptr;
		SecretService *service = service_get(SECRET_SERVICE_NONE, nullptr, &error);
		_available = service != nullptr;
		if (service != nullptr) {
			_object_unref(service);
		}
		_release_error(error);
	}

	bool is_available() const override { return _available; }

	BackendResult set_value(const String &p_namespace, const String &p_key, const String &p_value) override {
		if (!_available) {
			return BackendResult::failure(SecureStorageError::UNAVAILABLE, "Secret Service 不可用。");
		}
		const CharString namespace_utf8 = p_namespace.utf8();
		const CharString key_utf8 = p_key.utf8();
		const CharString value_utf8 = p_value.utf8();
		const SecretSchema schema = storage_schema(namespace_utf8);
		GError *error = nullptr;
		const gboolean stored = _store(
				&schema,
				SECRET_COLLECTION_DEFAULT,
				"SecureStorage 项目数据",
				value_utf8.get_data(),
				nullptr,
				&error,
				"key", key_utf8.get_data(),
				nullptr);
		_release_error(error);
		if (!stored) {
			return BackendResult::failure(SecureStorageError::PLATFORM_ERROR, "Secret Service 写入失败。");
		}
		return BackendResult::success(true);
	}

	BackendResult get_value(const String &p_namespace, const String &p_key) override {
		if (!_available) {
			return BackendResult::failure(SecureStorageError::UNAVAILABLE, "Secret Service 不可用。");
		}
		const CharString namespace_utf8 = p_namespace.utf8();
		const CharString key_utf8 = p_key.utf8();
		const SecretSchema schema = storage_schema(namespace_utf8);
		GError *error = nullptr;
		gchar *password = _lookup(
				&schema,
				nullptr,
				&error,
				"key", key_utf8.get_data(),
				nullptr);
		if (error != nullptr) {
			_release_error(error);
			return BackendResult::failure(SecureStorageError::PLATFORM_ERROR, "Secret Service 读取失败。");
		}
		if (password == nullptr) {
			return BackendResult::success(false);
		}
		const String value = String::utf8(password);
		_password_free(password);
		return BackendResult::success(true, value);
	}

	BackendResult remove_value(const String &p_namespace, const String &p_key) override {
		if (!_available) {
			return BackendResult::failure(SecureStorageError::UNAVAILABLE, "Secret Service 不可用。");
		}
		const BackendResult existing = get_value(p_namespace, p_key);
		if (existing.error != SecureStorageError::OK || !existing.found) {
			return existing;
		}
		const CharString namespace_utf8 = p_namespace.utf8();
		const CharString key_utf8 = p_key.utf8();
		const SecretSchema schema = storage_schema(namespace_utf8);
		GError *error = nullptr;
		const gboolean cleared = _clear(
				&schema,
				nullptr,
				&error,
				"key", key_utf8.get_data(),
				nullptr);
		_release_error(error);
		if (!cleared) {
			return BackendResult::failure(SecureStorageError::PLATFORM_ERROR, "Secret Service 删除失败。");
		}
		return BackendResult::success(true);
	}

	BackendResult clear_namespace(const String &p_namespace) override {
		if (!_available) {
			return BackendResult::failure(SecureStorageError::UNAVAILABLE, "Secret Service 不可用。");
		}
		const CharString namespace_utf8 = p_namespace.utf8();
		const SecretSchema schema = storage_schema(namespace_utf8);
		GError *error = nullptr;
		_clear(
				&schema,
				nullptr,
				&error,
				nullptr);
		if (error != nullptr) {
			_release_error(error);
			return BackendResult::failure(SecureStorageError::PLATFORM_ERROR, "Secret Service 清空命名空间失败。");
		}
		return BackendResult::success();
	}
};

} // namespace

std::unique_ptr<StorageBackend> create_platform_backend() {
	return std::make_unique<LinuxStorageBackend>();
}

} // namespace godot
