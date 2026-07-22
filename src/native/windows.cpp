#include "platforms.hpp"

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <bcrypt.h>
#include <dpapi.h>

#include <godot_cpp/classes/dir_access.hpp>
#include <godot_cpp/classes/os.hpp>

#include <algorithm>
#include <array>
#include <cstdint>
#include <cstring>
#include <memory>
#include <vector>

namespace godot {
namespace {

constexpr std::array<uint8_t, 5> HEADER = { 'S', 'S', 'D', 'P', 1 };

std::wstring to_wide(const String &p_value) {
	const Char16String utf16 = p_value.utf16();
	return std::wstring(reinterpret_cast<const wchar_t *>(utf16.get_data()), static_cast<size_t>(utf16.length()));
}

std::vector<uint8_t> to_bytes(const String &p_value) {
	const CharString utf8 = p_value.utf8();
	return std::vector<uint8_t>(
			reinterpret_cast<const uint8_t *>(utf8.get_data()),
			reinterpret_cast<const uint8_t *>(utf8.get_data()) + utf8.length());
}

String sha256_name(const String &p_key) {
	std::vector<uint8_t> input = to_bytes(p_key);
	std::array<uint8_t, 32> digest{};
	BCRYPT_ALG_HANDLE algorithm = nullptr;
	if (!BCRYPT_SUCCESS(BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM, nullptr, 0))) {
		SecureZeroMemory(input.data(), input.size());
		return String();
	}
	const NTSTATUS status = BCryptHash(
			algorithm,
			nullptr,
			0,
			input.data(),
			static_cast<ULONG>(input.size()),
			digest.data(),
			static_cast<ULONG>(digest.size()));
	BCryptCloseAlgorithmProvider(algorithm, 0);
	SecureZeroMemory(input.data(), input.size());
	if (!BCRYPT_SUCCESS(status)) {
		return String();
	}
	static constexpr char HEX[] = "0123456789abcdef";
	char encoded[65] = {};
	for (size_t index = 0; index < digest.size(); ++index) {
		encoded[index * 2] = HEX[digest[index] >> 4];
		encoded[index * 2 + 1] = HEX[digest[index] & 0x0f];
	}
	SecureZeroMemory(digest.data(), digest.size());
	return String::utf8(encoded, 64);
}

String storage_directory(const String &p_namespace) {
	return OS::get_singleton()->get_user_data_dir().path_join("secure_storage").path_join(p_namespace);
}

String storage_path(const String &p_namespace, const String &p_key) {
	const String name = sha256_name(p_key);
	return name.is_empty() ? String() : storage_directory(p_namespace).path_join(name + String(".bin"));
}

std::vector<uint8_t> entropy(const String &p_namespace, const String &p_key) {
	std::vector<uint8_t> result = to_bytes(p_namespace);
	result.push_back(0);
	std::vector<uint8_t> key = to_bytes(p_key);
	result.insert(result.end(), key.begin(), key.end());
	SecureZeroMemory(key.data(), key.size());
	return result;
}

BackendResult windows_error(SecureStorageError::Code p_code, const String &p_operation, DWORD p_error) {
	return BackendResult::failure(p_code, p_operation + String("失败，Windows 错误码：") + String::num_int64(p_error) + String("。"));
}

BackendResult write_atomic(const String &p_path, const std::vector<uint8_t> &p_data) {
	const String temp_path = p_path + String(".tmp");
	const std::wstring temp = to_wide(temp_path);
	const std::wstring target = to_wide(p_path);
	HANDLE file = CreateFileW(temp.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
	if (file == INVALID_HANDLE_VALUE) {
		return windows_error(SecureStorageError::IO_ERROR, "创建临时文件", GetLastError());
	}
	DWORD written = 0;
	const bool wrote = WriteFile(file, p_data.data(), static_cast<DWORD>(p_data.size()), &written, nullptr) != FALSE &&
			written == p_data.size();
	const bool flushed = wrote && FlushFileBuffers(file) != FALSE;
	const DWORD write_error = wrote && flushed ? ERROR_SUCCESS : GetLastError();
	CloseHandle(file);
	if (!wrote || !flushed) {
		DeleteFileW(temp.c_str());
		return windows_error(SecureStorageError::IO_ERROR, "写入临时文件", write_error);
	}
	if (MoveFileExW(temp.c_str(), target.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH) == FALSE) {
		const DWORD move_error = GetLastError();
		DeleteFileW(temp.c_str());
		return windows_error(SecureStorageError::IO_ERROR, "原子替换文件", move_error);
	}
	return BackendResult::success(true);
}

BackendResult read_file(const String &p_path, std::vector<uint8_t> &r_data) {
	const std::wstring path = to_wide(p_path);
	HANDLE file = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
	if (file == INVALID_HANDLE_VALUE) {
		const DWORD error = GetLastError();
		if (error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND) {
			return BackendResult::success(false);
		}
		return windows_error(SecureStorageError::IO_ERROR, "打开存储文件", error);
	}
	LARGE_INTEGER size{};
	if (GetFileSizeEx(file, &size) == FALSE || size.QuadPart < 0 || size.QuadPart > 2 * 1024 * 1024) {
		const DWORD error = GetLastError();
		CloseHandle(file);
		return windows_error(SecureStorageError::CORRUPT_DATA, "检查存储文件", error);
	}
	r_data.resize(static_cast<size_t>(size.QuadPart));
	DWORD read = 0;
	const bool succeeded = ReadFile(file, r_data.data(), static_cast<DWORD>(r_data.size()), &read, nullptr) != FALSE &&
			read == r_data.size();
	const DWORD error = succeeded ? ERROR_SUCCESS : GetLastError();
	CloseHandle(file);
	if (!succeeded) {
		return windows_error(SecureStorageError::IO_ERROR, "读取存储文件", error);
	}
	return BackendResult::success(true);
}

class WindowsStorageBackend final : public StorageBackend {
public:
	bool is_available() const override { return true; }

	BackendResult set_value(const String &p_namespace, const String &p_key, const String &p_value) override {
		const String directory = storage_directory(p_namespace);
		if (DirAccess::make_dir_recursive_absolute(directory) != OK) {
			return BackendResult::failure(SecureStorageError::IO_ERROR, "无法创建安全存储目录。");
		}
		const String path = storage_path(p_namespace, p_key);
		if (path.is_empty()) {
			return BackendResult::failure(SecureStorageError::CRYPTO_ERROR, "无法计算键文件名。");
		}
		std::vector<uint8_t> plain = to_bytes(p_value);
		plain.insert(plain.begin(), 1);
		std::vector<uint8_t> extra = entropy(p_namespace, p_key);
		DATA_BLOB input{ static_cast<DWORD>(plain.size()), plain.data() };
		DATA_BLOB entropy_blob{ static_cast<DWORD>(extra.size()), extra.data() };
		DATA_BLOB protected_blob{};
		const BOOL protected_ok = CryptProtectData(
				&input, L"SecureStorage", &entropy_blob, nullptr, nullptr, CRYPTPROTECT_UI_FORBIDDEN, &protected_blob);
		SecureZeroMemory(plain.data(), plain.size());
		SecureZeroMemory(extra.data(), extra.size());
		if (protected_ok == FALSE) {
			return windows_error(SecureStorageError::CRYPTO_ERROR, "DPAPI 加密", GetLastError());
		}
		std::vector<uint8_t> payload(HEADER.begin(), HEADER.end());
		payload.insert(payload.end(), protected_blob.pbData, protected_blob.pbData + protected_blob.cbData);
		LocalFree(protected_blob.pbData);
		const BackendResult result = write_atomic(path, payload);
		SecureZeroMemory(payload.data(), payload.size());
		return result;
	}

	BackendResult get_value(const String &p_namespace, const String &p_key) override {
		const String path = storage_path(p_namespace, p_key);
		if (path.is_empty()) {
			return BackendResult::failure(SecureStorageError::CRYPTO_ERROR, "无法计算键文件名。");
		}
		std::vector<uint8_t> payload;
		const BackendResult loaded = read_file(path, payload);
		if (loaded.error != SecureStorageError::OK || !loaded.found) {
			return loaded;
		}
		if (payload.size() <= HEADER.size() || !std::equal(HEADER.begin(), HEADER.end(), payload.begin())) {
			return BackendResult::failure(SecureStorageError::CORRUPT_DATA, "存储文件头无效。");
		}
		std::vector<uint8_t> extra = entropy(p_namespace, p_key);
		DATA_BLOB input{
				static_cast<DWORD>(payload.size() - HEADER.size()),
				payload.data() + HEADER.size()
		};
		DATA_BLOB entropy_blob{ static_cast<DWORD>(extra.size()), extra.data() };
		DATA_BLOB plain{};
		const BOOL unprotected = CryptUnprotectData(
				&input, nullptr, &entropy_blob, nullptr, nullptr, CRYPTPROTECT_UI_FORBIDDEN, &plain);
		SecureZeroMemory(extra.data(), extra.size());
		SecureZeroMemory(payload.data(), payload.size());
		if (unprotected == FALSE) {
			return windows_error(SecureStorageError::CORRUPT_DATA, "DPAPI 解密", GetLastError());
		}
		if (plain.cbData == 0 || plain.pbData[0] != 1) {
			SecureZeroMemory(plain.pbData, plain.cbData);
			LocalFree(plain.pbData);
			return BackendResult::failure(SecureStorageError::CORRUPT_DATA, "DPAPI 明文格式无效。");
		}
		const String value = String::utf8(reinterpret_cast<const char *>(plain.pbData + 1), plain.cbData - 1);
		const CharString roundtrip = value.utf8();
		const bool valid_utf8 = roundtrip.length() == plain.cbData - 1 &&
				(plain.cbData == 1 || std::memcmp(roundtrip.get_data(), plain.pbData + 1, plain.cbData - 1) == 0);
		SecureZeroMemory(plain.pbData, plain.cbData);
		LocalFree(plain.pbData);
		if (!valid_utf8) {
			return BackendResult::failure(SecureStorageError::CORRUPT_DATA, "解密结果不是有效 UTF-8 字符串。");
		}
		return BackendResult::success(true, value);
	}

	BackendResult remove_value(const String &p_namespace, const String &p_key) override {
		const String path = storage_path(p_namespace, p_key);
		if (path.is_empty()) {
			return BackendResult::failure(SecureStorageError::CRYPTO_ERROR, "无法计算键文件名。");
		}
		if (DeleteFileW(to_wide(path).c_str()) != FALSE) {
			return BackendResult::success(true);
		}
		const DWORD error = GetLastError();
		if (error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND) {
			return BackendResult::success(false);
		}
		return windows_error(SecureStorageError::IO_ERROR, "删除存储文件", error);
	}

	BackendResult clear_namespace(const String &p_namespace) override {
		const String directory = storage_directory(p_namespace);
		Ref<DirAccess> access = DirAccess::open(directory);
		if (access.is_null()) {
			return BackendResult::success();
		}
		access->list_dir_begin();
		for (String name = access->get_next(); !name.is_empty(); name = access->get_next()) {
			if (!access->current_is_dir() && access->remove(name) != OK) {
				access->list_dir_end();
				return BackendResult::failure(SecureStorageError::IO_ERROR, "无法清空安全存储目录。");
			}
		}
		access->list_dir_end();
		access.unref();
		DirAccess::remove_absolute(directory);
		return BackendResult::success();
	}
};

} // namespace

std::unique_ptr<StorageBackend> create_platform_backend() {
	return std::make_unique<WindowsStorageBackend>();
}

} // namespace godot
