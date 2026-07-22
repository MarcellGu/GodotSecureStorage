#include "platforms.hpp"

namespace godot {

std::unique_ptr<StorageBackend> create_platform_backend() {
	return secure_storage_apple::create_backend(kSecAttrAccessibleWhenUnlocked);
}

}
