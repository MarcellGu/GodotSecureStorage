#pragma once

#include "secure_storage.hpp"

#if defined(__APPLE__)

#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <TargetConditionals.h>

#include <cstdint>
#include <cstring>
#include <vector>

#endif

namespace godot {

std::unique_ptr<StorageBackend> create_platform_backend();

#if defined(__APPLE__)

namespace secure_storage_apple {

template <typename T>
class ScopedCF final {
	T _value = nullptr;

public:
	explicit ScopedCF(T p_value = nullptr) : _value(p_value) {}
	~ScopedCF() {
		if (_value != nullptr) CFRelease(_value);
	}
	ScopedCF(const ScopedCF &) = delete;
	ScopedCF &operator=(const ScopedCF &) = delete;
	ScopedCF(ScopedCF &&p_other) noexcept : _value(p_other._value) { p_other._value = nullptr; }
	T get() const { return _value; }
};

inline void clear_bytes(std::vector<uint8_t> &p_bytes) {
	volatile uint8_t *cursor = p_bytes.data();
	for (size_t index = 0; index < p_bytes.size(); ++index) cursor[index] = 0;
}

inline ScopedCF<CFStringRef> to_cf_string(const String &p_value) {
	const CharString utf8 = p_value.utf8();
	return ScopedCF<CFStringRef>(CFStringCreateWithBytes(
			kCFAllocatorDefault,
			reinterpret_cast<const UInt8 *>(utf8.get_data()),
			utf8.length(),
			kCFStringEncodingUTF8,
			false));
}

inline ScopedCF<CFMutableDictionaryRef> base_query(const String &p_namespace, const String *p_key) {
	ScopedCF<CFMutableDictionaryRef> query(CFDictionaryCreateMutable(
			kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks));
	ScopedCF<CFStringRef> service = to_cf_string(p_namespace);
	CFDictionarySetValue(query.get(), kSecClass, kSecClassGenericPassword);
	CFDictionarySetValue(query.get(), kSecAttrService, service.get());
	if (p_key != nullptr) {
		ScopedCF<CFStringRef> account = to_cf_string(*p_key);
		CFDictionarySetValue(query.get(), kSecAttrAccount, account.get());
	}
	return query;
}

inline BackendResult status_failure(OSStatus p_status, const String &p_operation) {
	SecureStorageError::Code code = SecureStorageError::PLATFORM_ERROR;
	switch (p_status) {
		case errSecParam: code = SecureStorageError::INVALID_ARGUMENT; break;
		case errSecAuthFailed:
		case errSecInteractionNotAllowed:
		case errSecUserCanceled:
		case errSecMissingEntitlement: code = SecureStorageError::PERMISSION_DENIED; break;
		case errSecDecode: code = SecureStorageError::CORRUPT_DATA; break;
		case errSecNotAvailable: code = SecureStorageError::UNAVAILABLE; break;
		case errSecAllocate: code = SecureStorageError::IO_ERROR; break;
		default: break;
	}
	return BackendResult::failure(code, p_operation + String("失败，Keychain 状态码：") + String::num_int64(p_status) + String("。"));
}

class AppleStorageBackend final : public StorageBackend {
	CFTypeRef _accessibility;

public:
	explicit AppleStorageBackend(CFTypeRef p_accessibility) : _accessibility(p_accessibility) {}
	bool is_available() const override { return true; }

	BackendResult set_value(const String &p_namespace, const String &p_key, const String &p_value) override {
		const CharString encoded = p_value.utf8();
		std::vector<uint8_t> bytes(
				reinterpret_cast<const uint8_t *>(encoded.get_data()),
				reinterpret_cast<const uint8_t *>(encoded.get_data()) + encoded.length());
		ScopedCF<CFDataRef> data(CFDataCreate(kCFAllocatorDefault, bytes.data(), static_cast<CFIndex>(bytes.size())));
		ScopedCF<CFMutableDictionaryRef> query = base_query(p_namespace, &p_key);
		ScopedCF<CFMutableDictionaryRef> attributes(CFDictionaryCreateMutable(
				kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks));
		CFDictionarySetValue(attributes.get(), kSecValueData, data.get());
		OSStatus status = SecItemUpdate(query.get(), attributes.get());
		if (status == errSecItemNotFound) {
			CFDictionarySetValue(query.get(), kSecValueData, data.get());
			CFDictionarySetValue(query.get(), kSecAttrAccessible, _accessibility);
			status = SecItemAdd(query.get(), nullptr);
		}
		clear_bytes(bytes);
		return status == errSecSuccess ? BackendResult::success(true) : status_failure(status, "写入");
	}

	BackendResult get_value(const String &p_namespace, const String &p_key) override {
		ScopedCF<CFMutableDictionaryRef> query = base_query(p_namespace, &p_key);
		CFDictionarySetValue(query.get(), kSecReturnData, kCFBooleanTrue);
		CFDictionarySetValue(query.get(), kSecMatchLimit, kSecMatchLimitOne);
		CFTypeRef raw_result = nullptr;
		const OSStatus status = SecItemCopyMatching(query.get(), &raw_result);
		ScopedCF<CFTypeRef> result(raw_result);
		if (status == errSecItemNotFound) return BackendResult::success(false);
		if (status != errSecSuccess) return status_failure(status, "读取");
		if (raw_result == nullptr || CFGetTypeID(raw_result) != CFDataGetTypeID()) {
			return BackendResult::failure(SecureStorageError::CORRUPT_DATA, "Keychain 返回了非数据载荷。");
		}
		const auto data = static_cast<CFDataRef>(raw_result);
		const CFIndex length = CFDataGetLength(data);
		std::vector<uint8_t> bytes(static_cast<size_t>(length));
		if (length > 0) CFDataGetBytes(data, CFRangeMake(0, length), bytes.data());
		const String value = String::utf8(reinterpret_cast<const char *>(bytes.data()), length);
		const CharString roundtrip = value.utf8();
		const bool valid_utf8 = roundtrip.length() == length &&
				(length == 0 || std::memcmp(roundtrip.get_data(), bytes.data(), static_cast<size_t>(length)) == 0);
		clear_bytes(bytes);
		return valid_utf8 ? BackendResult::success(true, value) :
				BackendResult::failure(SecureStorageError::CORRUPT_DATA, "Keychain 载荷不是有效 UTF-8 字符串。");
	}

	BackendResult remove_value(const String &p_namespace, const String &p_key) override {
		ScopedCF<CFMutableDictionaryRef> query = base_query(p_namespace, &p_key);
		const OSStatus status = SecItemDelete(query.get());
		if (status == errSecItemNotFound) return BackendResult::success(false);
		return status == errSecSuccess ? BackendResult::success(true) : status_failure(status, "删除");
	}

	BackendResult clear_namespace(const String &p_namespace) override {
		ScopedCF<CFMutableDictionaryRef> query = base_query(p_namespace, nullptr);
#if TARGET_OS_OSX
		CFDictionarySetValue(query.get(), kSecMatchLimit, kSecMatchLimitAll);
#endif
		const OSStatus status = SecItemDelete(query.get());
		return status == errSecSuccess || status == errSecItemNotFound ? BackendResult::success() :
				status_failure(status, "清空命名空间");
	}
};

inline std::unique_ptr<StorageBackend> create_backend(CFTypeRef p_accessibility) {
	return std::make_unique<AppleStorageBackend>(p_accessibility);
}

}
#endif

}
