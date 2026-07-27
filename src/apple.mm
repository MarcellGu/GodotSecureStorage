/*
 * domain、key、value 分别映射为 Generic Password 的 service、account 和 data。
 * 所有查询都由宿主提供的 Keychain access group 隔离。
 */
#include "backend.hpp"

#import <Foundation/Foundation.h>
#include <Security/Security.h>
#include <TargetConditionals.h>

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/classes/project_settings.hpp>

namespace godot {
namespace {

class AppleBackend final : public NativeBackend {
	GDCLASS(AppleBackend, NativeBackend)

private:
	static String format_message(OSStatus p_status) {
		CFStringRef native_message = SecCopyErrorMessageString(p_status, nullptr);
		NSString *description = (__bridge NSString *)native_message;
		// 即使系统没有对应说明，也保留可诊断的状态码。
		String message = "(" + String::num_int64(p_status) + ")";
		if (description != nil) {
			message += " " + String::utf8(description.UTF8String);
		}
		if (native_message != nullptr) {
			CFRelease(native_message);
		}
		return message;
	}

	// 必须由宿主显式配置，不能硬编码或从 bundle id 猜测。
	String access_group;

	BackendResult validate_access_group() const {
		if (access_group.is_empty()) {
			return BackendResult::failure(
					BackendResult::PLATFORM_ERROR,
					"Apple Keychain access group 未配置。");
		}
		for (int64_t index = 0; index < access_group.length(); ++index) {
			if (access_group[index] == 0) {
				return BackendResult::failure(
						BackendResult::PLATFORM_ERROR,
						"Apple Keychain access group 配置无效。");
			}
		}
		return BackendResult::success();
	}

public:
	AppleBackend() {
		ProjectSettings *settings = ProjectSettings::get_singleton();
		if (settings == nullptr) {
			return;
		}
		Variant configured = settings->get_setting(
				"secure_storage/apple_access_group",
				String());
		if (configured.get_type() == Variant::STRING) {
			access_group = static_cast<String>(configured);
		}
	}

protected:
	static void _bind_methods() {}

	BackendResult _set_value(
			const String &p_domain,
			const String &p_key,
			const String &p_value) override {
		BackendResult configuration = validate_access_group();
			if (configuration.code != BackendResult::OK) {
				return configuration;
			}
			@autoreleasepool {
				CharString group = access_group.utf8();
				CharString domain = p_domain.utf8();
				CharString key = p_key.utf8();
				CharString value = p_value.utf8();
				NSDictionary *query = @{
					(id)kSecClass: (id)kSecClassGenericPassword,
					// 统一使用 Data Protection Keychain。
					(id)kSecUseDataProtectionKeychain: @YES,
					(id)kSecAttrAccessGroup: [NSString stringWithUTF8String:group.get_data()],
					(id)kSecAttrService: [NSString stringWithUTF8String:domain.get_data()],
					(id)kSecAttrAccount: [NSString stringWithUTF8String:key.get_data()]
				};
				NSData *data = [NSData dataWithBytes:value.get_data() length:value.length()];
				OSStatus status = SecItemUpdate((CFDictionaryRef)query,
						(CFDictionaryRef)@{
							(id)kSecValueData: data
						});
				if (status == errSecItemNotFound) {
					// macOS 解锁时可用；iOS 使用仅本机、首次解锁后策略。
#if TARGET_OS_OSX
					id accessibility = (id)kSecAttrAccessibleWhenUnlocked;
#else
					id accessibility = (id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
#endif
					NSMutableDictionary *item =
							[NSMutableDictionary dictionaryWithDictionary:query];
				item[(id)kSecValueData] = data;
				item[(id)kSecAttrAccessible] = accessibility;
				status = SecItemAdd((CFDictionaryRef)item, nullptr);
			}
			if (status != errSecSuccess) {
				return BackendResult::failure(
						BackendResult::PLATFORM_ERROR,
						format_message(status));
			}
			return BackendResult::success(p_domain, p_key, p_value);
			}
		}

		BackendResult _get_value(
				const String &p_domain,
			const String &p_key) override {
		BackendResult configuration = validate_access_group();
		if (configuration.code != BackendResult::OK) {
			return configuration;
		}
		@autoreleasepool {
				CharString group = access_group.utf8();
				CharString domain = p_domain.utf8();
				CharString key = p_key.utf8();
				NSDictionary *query = @{
					(id)kSecClass: (id)kSecClassGenericPassword,
				(id)kSecUseDataProtectionKeychain: @YES,
				(id)kSecAttrAccessGroup: [NSString stringWithUTF8String:group.get_data()],
				(id)kSecAttrService: [NSString stringWithUTF8String:domain.get_data()],
				(id)kSecAttrAccount: [NSString stringWithUTF8String:key.get_data()],
					(id)kSecReturnData: @YES,
					(id)kSecMatchLimit: (id)kSecMatchLimitOne
				};
				// Copy 规则要求释放任何非空输出，包括异常失败路径。
				CFTypeRef raw = nullptr;
				OSStatus status = SecItemCopyMatching((CFDictionaryRef)query, &raw);
				if (status != errSecSuccess) {
					if (raw != nullptr) {
					CFRelease(raw);
				}
				BackendResult::Code code =
						status == errSecItemNotFound
						? BackendResult::NOT_FOUND
							: BackendResult::PLATFORM_ERROR;
					return BackendResult::failure(code, format_message(status));
				}
				if (raw == nullptr || CFGetTypeID(raw) != CFDataGetTypeID()) {
					if (raw != nullptr) {
					CFRelease(raw);
				}
				return BackendResult::failure(
						BackendResult::PLATFORM_ERROR,
						format_message(errSecDecode));
			}
				CFDataRef data = (CFDataRef)raw;
				CFIndex length = CFDataGetLength(data);
				const uint8_t *bytes = CFDataGetBytePtr(data);
				// 拒绝损坏的持久化载荷。
				if (length < 0 || !is_valid_utf8_value_bytes(bytes, (size_t)length)) {
					CFRelease(raw);
				return BackendResult::failure(
							BackendResult::PLATFORM_ERROR,
							format_message(errSecDecode));
				}
				String value = length == 0
						? String()
						: String::utf8((const char *)bytes, length);
				CFRelease(raw);
				return BackendResult::success(p_domain, p_key, value);
			}
		}

		BackendResult _remove_value(
				const String &p_domain,
			const String &p_key) override {
		BackendResult configuration = validate_access_group();
		if (configuration.code != BackendResult::OK) {
			return configuration;
		}
		@autoreleasepool {
				CharString group = access_group.utf8();
				CharString domain = p_domain.utf8();
				CharString key = p_key.utf8();
				NSDictionary *query = @{
					(id)kSecClass: (id)kSecClassGenericPassword,
				(id)kSecUseDataProtectionKeychain: @YES,
				(id)kSecAttrAccessGroup: [NSString stringWithUTF8String:group.get_data()],
				(id)kSecAttrService: [NSString stringWithUTF8String:domain.get_data()],
				(id)kSecAttrAccount: [NSString stringWithUTF8String:key.get_data()]
			};
			OSStatus status = SecItemDelete((CFDictionaryRef)query);
			if (status != errSecSuccess && status != errSecItemNotFound) {
				return BackendResult::failure(
						BackendResult::PLATFORM_ERROR,
						format_message(status));
			}
			return BackendResult::success(p_domain, p_key);
			}
		}

		BackendResult _clear_domain(const String &p_domain) override {
			BackendResult configuration = validate_access_group();
		if (configuration.code != BackendResult::OK) {
			return configuration;
		}
			@autoreleasepool {
				CharString group = access_group.utf8();
				CharString domain = p_domain.utf8();
				// 省略 account，但仍限定 Data Protection Keychain、宿主组和 service。
				NSDictionary *query = @{
					(id)kSecClass: (id)kSecClassGenericPassword,
				(id)kSecUseDataProtectionKeychain: @YES,
				(id)kSecAttrAccessGroup: [NSString stringWithUTF8String:group.get_data()],
				(id)kSecAttrService: [NSString stringWithUTF8String:domain.get_data()]
			};
			OSStatus status = SecItemDelete((CFDictionaryRef)query);
			if (status != errSecSuccess && status != errSecItemNotFound) {
				return BackendResult::failure(
						BackendResult::PLATFORM_ERROR,
						format_message(status));
			}
			return BackendResult::success(p_domain);
		}
	}
};

} // namespace

void register_platform_backend() {
	GDREGISTER_CLASS(AppleBackend);
}

} // namespace godot
