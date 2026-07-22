#pragma once

#include <godot_cpp/classes/ref.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/binder_common.hpp>
#include <godot_cpp/variant/string.hpp>

#include <memory>

namespace godot {

class SecureStorageError : public RefCounted {
	GDCLASS(SecureStorageError, RefCounted)

public:
	enum Code {
		OK = 0,
		INVALID_ARGUMENT = 1,
		UNAVAILABLE = 2,
		IO_ERROR = 3,
		CRYPTO_ERROR = 4,
		CORRUPT_DATA = 5,
		PERMISSION_DENIED = 6,
		PLATFORM_ERROR = 7,
		UNKNOWN = 8,
	};

	static String code_name(Code p_code);

protected:
	static void _bind_methods();
};

class SecureStorageResult : public RefCounted {
	GDCLASS(SecureStorageResult, RefCounted)

	bool _ok = false;
	bool _found = false;
	String _value;
	SecureStorageError::Code _error = SecureStorageError::UNKNOWN;
	String _error_message;

public:
	static Ref<SecureStorageResult> ok(bool p_found = false, const String &p_value = String());
	static Ref<SecureStorageResult> err(SecureStorageError::Code p_error, const String &p_message);

	bool is_ok() const;
	bool is_found() const;
	String get_value() const;
	SecureStorageError::Code get_error() const;
	String get_error_message() const;

protected:
	static void _bind_methods();
};

struct BackendResult {
	SecureStorageError::Code error = SecureStorageError::OK;
	bool found = false;
	String value;
	String message;

	static BackendResult success(bool p_found = false, const String &p_value = String());
	static BackendResult failure(SecureStorageError::Code p_error, const String &p_message);
};

class StorageBackend {
public:
	virtual ~StorageBackend() = default;
	virtual bool is_available() const = 0;
	virtual BackendResult set_value(const String &p_namespace, const String &p_key, const String &p_value) = 0;
	virtual BackendResult get_value(const String &p_namespace, const String &p_key) = 0;
	virtual BackendResult remove_value(const String &p_namespace, const String &p_key) = 0;
	virtual BackendResult clear_namespace(const String &p_namespace) = 0;
};

class SecureStorage : public RefCounted {
	GDCLASS(SecureStorage, RefCounted)

	std::unique_ptr<StorageBackend> _backend;
	bool _testing_backend = false;

	static String _validate_namespace(const String &p_namespace);
	static String _validate_key(const String &p_key);
	static String _validate_value(const String &p_value);
	static Ref<SecureStorageResult> _to_result(const BackendResult &p_result);

public:
	SecureStorage();
	explicit SecureStorage(bool p_initialize_platform);
	~SecureStorage() override;

	static Ref<SecureStorage> create_for_testing();
	bool is_available() const;
	Ref<SecureStorageResult> set_value(const String &p_namespace, const String &p_key, const String &p_value);
	Ref<SecureStorageResult> get_value(const String &p_namespace, const String &p_key);
	Ref<SecureStorageResult> remove_value(const String &p_namespace, const String &p_key);
	Ref<SecureStorageResult> clear_namespace(const String &p_namespace);
	void set_available_for_testing(bool p_available);
	void corrupt_value_for_testing(const String &p_namespace, const String &p_key);

protected:
	static void _bind_methods();
};

}

VARIANT_ENUM_CAST(godot::SecureStorageError::Code)
