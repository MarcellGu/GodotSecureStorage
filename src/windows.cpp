/*
 * domain/key 直接映射为当前用户的一条 Generic Credential，value 使用 UTF-8。
 * 不添加库或项目身份前缀，持久化命名空间完全由宿主提供的 domain 决定。
 */
#include "backend.hpp"

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <wincred.h>

#include <godot_cpp/core/class_db.hpp>

#include <string>

namespace godot {

namespace {

std::wstring prefix(const String &p_domain) {
	CharWideString text = p_domain.wide_string();
	return std::wstring(text.get_data(), static_cast<size_t>(text.length())) + L"/";
}

std::wstring target(const String &p_domain, const String &p_key) {
	CharWideString key = p_key.wide_string();
	return prefix(p_domain) +
			std::wstring(key.get_data(), static_cast<size_t>(key.length()));
}

// 只擦除系统缓冲区中的秘密，所有权仍由调用方管理。
void wipe(PCREDENTIALW p_credential) {
	if (p_credential != nullptr && p_credential->CredentialBlob != nullptr) {
		SecureZeroMemory(p_credential->CredentialBlob, p_credential->CredentialBlobSize);
	}
}

class WindowsBackend final : public NativeBackend {
	GDCLASS(WindowsBackend, NativeBackend)

private:
	static String format_message(DWORD p_status) {
		LPWSTR native = nullptr;
		FormatMessageW(
				FORMAT_MESSAGE_ALLOCATE_BUFFER |
						FORMAT_MESSAGE_FROM_SYSTEM |
						FORMAT_MESSAGE_IGNORE_INSERTS |
						FORMAT_MESSAGE_MAX_WIDTH_MASK,
				nullptr,
				p_status,
				0,
				reinterpret_cast<LPWSTR>(&native),
				0,
				nullptr);
		// 即使系统没有对应说明，也保留可诊断的状态码。
		String message = "(" + String::num_uint64(p_status) + ")";
		if (native != nullptr) {
			message += " " + String::utf16(reinterpret_cast<const char16_t *>(native));
			LocalFree(native);
		}
		return message;
	}

protected:
	static void _bind_methods() {}

	BackendResult _set_value(
			const String &p_domain,
			const String &p_key,
			const String &p_value) override {
		std::wstring name = target(p_domain, p_key);
		CharString value = p_value.utf8();
		CREDENTIALW credential{};
		credential.Type = CRED_TYPE_GENERIC;
		credential.TargetName = name.data();
		credential.CredentialBlobSize = static_cast<DWORD>(value.length());
		credential.CredentialBlob = value.length() == 0
				? nullptr
				: reinterpret_cast<LPBYTE>(value.ptrw());
		credential.Persist = CRED_PERSIST_LOCAL_MACHINE;
		BOOL stored = CredWriteW(&credential, 0);
		// 擦除秘密前先捕获线程错误码。
		DWORD status = stored ? ERROR_SUCCESS : GetLastError();
		if (value.length() > 0) {
			SecureZeroMemory(value.ptrw(), value.length());
		}
		if (status != ERROR_SUCCESS) {
			return BackendResult::failure(
					BackendResult::PLATFORM_ERROR,
					format_message(status));
		}
		return BackendResult::success(p_domain, p_key, p_value);
	}

	BackendResult _get_value(
			const String &p_domain,
			const String &p_key) override {
		std::wstring name = target(p_domain, p_key);
		PCREDENTIALW credential = nullptr;
		if (!CredReadW(name.c_str(), CRED_TYPE_GENERIC, 0, &credential)) {
			DWORD status = GetLastError();
			BackendResult::Code code = status == ERROR_NOT_FOUND
					? BackendResult::NOT_FOUND
					: BackendResult::PLATFORM_ERROR;
			return BackendResult::failure(code, format_message(status));
		}
		// 不信任平台返回的大小、指针或 UTF-8 载荷。
		bool valid =
				credential != nullptr &&
				credential->CredentialBlobSize <= CRED_MAX_CREDENTIAL_BLOB_SIZE &&
				(credential->CredentialBlobSize == 0 || credential->CredentialBlob != nullptr) &&
				is_valid_utf8_value_bytes(
						credential->CredentialBlob, credential->CredentialBlobSize);
		if (!valid) {
			wipe(credential);
			if (credential != nullptr) {
				CredFree(credential);
			}
			return BackendResult::failure(
					BackendResult::PLATFORM_ERROR, "Credential Manager 载荷无效。");
		}
		String value = credential->CredentialBlobSize == 0
				? String()
				: String::utf8(
						reinterpret_cast<const char *>(credential->CredentialBlob),
						credential->CredentialBlobSize);
		wipe(credential);
		CredFree(credential);
		return BackendResult::success(p_domain, p_key, value);
	}

	BackendResult _remove_value(
			const String &p_domain,
			const String &p_key) override {
		std::wstring name = target(p_domain, p_key);
		if (!CredDeleteW(name.c_str(), CRED_TYPE_GENERIC, 0)) {
			DWORD status = GetLastError();
			if (status != ERROR_NOT_FOUND) {
				return BackendResult::failure(
						BackendResult::PLATFORM_ERROR,
						format_message(status));
			}
		}
		return BackendResult::success(p_domain, p_key);
	}

	BackendResult _clear_domain(const String &p_domain) override {
		std::wstring filter = prefix(p_domain) + L"*";
		DWORD count = 0;
		DWORD status = ERROR_SUCCESS;
		PCREDENTIALW *credentials = nullptr;
		if (!CredEnumerateW(filter.c_str(), 0, &count, &credentials)) {
			status = GetLastError();
			if (status == ERROR_NOT_FOUND) {
				return BackendResult::success(p_domain);
			}
			return BackendResult::failure(
					BackendResult::PLATFORM_ERROR,
					format_message(status));
		}
		for (DWORD i = 0; i < count; ++i) {
			PCREDENTIALW item = credentials[i];
			wipe(item);
			if (item == nullptr ||
					item->Type != CRED_TYPE_GENERIC ||
					item->TargetName == nullptr) {
				continue;
			}
			if (!CredDeleteW(item->TargetName, CRED_TYPE_GENERIC, 0)) {
				DWORD current = GetLastError();
				// 并发删除视为成功，只保留第一个实质错误。
				if (current != ERROR_NOT_FOUND && status == ERROR_SUCCESS) {
					status = current;
				}
			}
		}
		// 枚举结果由单块系统缓冲区承载，只释放一次。
		CredFree(credentials);
		if (status != ERROR_SUCCESS) {
			return BackendResult::failure(
					BackendResult::PLATFORM_ERROR,
					format_message(status));
		}
		return BackendResult::success(p_domain);
	}
};

} // namespace

void register_platform_backend() {
	GDREGISTER_CLASS(WindowsBackend);
}

} // namespace godot
