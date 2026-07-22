cmake_minimum_required(VERSION 3.22.1)
project(secure_storage LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

set(PROJECT_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../..")
set(GODOT_CPP_DIR "${PROJECT_ROOT}/.deps/godot-cpp")

if (ANDROID_ABI STREQUAL "arm64-v8a")
    set(GODOT_CPP_ARCH "arm64")
elseif (ANDROID_ABI STREQUAL "x86_64")
    set(GODOT_CPP_ARCH "x86_64")
else ()
    message(FATAL_ERROR "SecureStorage 当前 AAR 目标只启用 arm64-v8a；可按文档扩展 ABI。")
endif ()

if (CMAKE_BUILD_TYPE MATCHES "Debug")
    set(GODOT_CPP_TARGET "template_debug")
else ()
    set(GODOT_CPP_TARGET "template_release")
endif ()

set(GODOT_CPP_LIBRARY "${GODOT_CPP_DIR}/bin/libgodot-cpp.android.${GODOT_CPP_TARGET}.${GODOT_CPP_ARCH}.a")
if (NOT EXISTS "${GODOT_CPP_LIBRARY}")
    message(FATAL_ERROR "缺少预编译 godot-cpp：${GODOT_CPP_LIBRARY}。请先运行 scripts/build_android.sh。")
endif ()

add_library(godot-cpp STATIC IMPORTED GLOBAL)
set_target_properties(godot-cpp PROPERTIES
        IMPORTED_LOCATION "${GODOT_CPP_LIBRARY}"
        INTERFACE_INCLUDE_DIRECTORIES "${GODOT_CPP_DIR}/include;${GODOT_CPP_DIR}/gen/include;${GODOT_CPP_DIR}/gdextension"
)

add_library(secure_storage SHARED
        "${PROJECT_ROOT}/native/secure_storage.cpp"
        "${PROJECT_ROOT}/native/android.cpp"
)

target_include_directories(secure_storage PRIVATE "${PROJECT_ROOT}/native")
target_link_libraries(secure_storage PRIVATE godot-cpp android log)
target_compile_options(secure_storage PRIVATE -fPIC -Wall -Wextra -Wpedantic)
