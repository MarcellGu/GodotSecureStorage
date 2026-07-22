# SecureStorage

SecureStorage 是面向 Godot 4.7.1 的无 C# 依赖跨平台安全存储 GDExtension。

## 项目结构

以下列出仓库内每个受版本控制文件的实际作用。仓库协作约束集中写在 `AGENTS.md`，不在此重复。

```text
SecureStorage/
├── .github/
│   └── workflows/
│       └── build.yml
├── docs/
│   ├── api.md
│   └── testing.md
├── scripts/
│   ├── bootstrap.sh
│   ├── build.sh
│   ├── clean.sh
│   ├── test.sh
│   └── verify.sh
├── src/
│   ├── addon/
│   │   ├── .gdignore
│   │   ├── export_plugin.gd
│   │   ├── icon.svg
│   │   ├── plugin.cfg
│   │   ├── plugin.gd
│   │   ├── secure_storage.gdextension
│   │   └── storage_service.gd
│   ├── android/
│   │   ├── plugin/
│   │   │   ├── src/main/java/com/marcellgu/securestorage/
│   │   │   │   └── SecureStoragePlugin.kt
│   │   │   ├── src/main/AndroidManifest.xml
│   │   │   ├── CMakeLists.txt
│   │   │   └── build.gradle.kts
│   │   ├── build.gradle.kts
│   │   ├── gradle.properties
│   │   ├── gradlew
│   │   └── settings.gradle.kts
│   ├── native/
│   │   ├── android.cpp
│   │   ├── ios.cpp
│   │   ├── linux.cpp
│   │   ├── macos.cpp
│   │   ├── platforms.hpp
│   │   ├── secure_storage.cpp
│   │   ├── secure_storage.hpp
│   │   └── windows.cpp
│   ├── SConstruct
│   └── project.godot
├── tests/
│   ├── memory_backend_test.gd
│   ├── platform_backend_test.gd
│   ├── storage_contract_test.gd
│   ├── test_context.gd
│   ├── test_runner.gd
│   └── test_runner.tscn
├── .gitignore
├── AGENTS.md
└── README.md
```

### 根目录与自动化

- `.gitignore`：默认屏蔽所有路径，再逐项放行仓库认可的源码、配置、文档和测试文件，避免意外提交生成物。
- `AGENTS.md`：向代码代理和自动化 harness 提供仓库白名单、生成物边界、验证入口及平台约束。
- `README.md`：说明项目用途、逐文件用途、构建方法、构建后布局和安全模型。
- `.github/workflows/build.yml`：在 macOS、Windows、Ubuntu runner 上构建五个平台的 debug/release 产物，在三个桌面 runner 上验证
  Keychain、DPAPI、Secret Service 真实后端，汇总验证后打包 ZIP 并生成 SHA-256；推送与 `plugin.cfg` 版本一致的
  `v<major>.<minor>.<patch>` tag 时自动发布 GitHub Release。

### 文档

- `docs/api.md`：说明公开类、方法、参数边界、结果语义和稳定错误码，供接入方编写调用代码。
- `docs/testing.md`：说明内存/真实后端测试命令、覆盖目标、平台测试范围和秘密泄漏哨兵。

### 构建与验证脚本

- `scripts/bootstrap.sh`：校验 Godot 4.7.1 与 SCons 4.10.1，获取固定提交的 godot-cpp，并导出匹配版本的 GDExtension API 描述。
- `scripts/build.sh`：把源码暂存到外部工作目录，调用对应平台工具链，并把可安装文件合并到 `addons/SecureStorage/`。
- `scripts/clean.sh`：删除根目录生成的 addon 与外部工作目录，保留可复用的依赖、对象和签名缓存；传入 `--all` 时删除整个外部构建根目录。
- `scripts/test.sh`：先构建当前桌面平台的 debug 扩展，再通过 Godot headless 运行内存后端或真实平台后端测试，并检查日志是否泄密或报错。
- `scripts/verify.sh`：检查根路径白名单、固定脚本/文档集合、源码污染、GDScript 写法和 .NET 文件，再运行内存后端测试。

### Godot addon 文件

- `src/addon/.gdignore`：阻止 Godot 编辑器把 addon 源目录作为普通项目内容导入；构建复制 addon 时不会携带此文件。
- `src/addon/export_plugin.gd`：在 Android 导出时选择 debug/release AAR，在 iOS 导出时补充 Security 与 CoreFoundation
  链接参数。
- `src/addon/icon.svg`：给 Godot 编辑器中的 `SecureStorage` 类型提供锁形图标。
- `src/addon/plugin.cfg`：向 Godot 注册插件名称、版本、说明和入口脚本。
- `src/addon/plugin.gd`：在插件启用/停用时注册或注销导出插件。
- `src/addon/secure_storage.gdextension`：把平台、构建类型和架构映射到对应原生库，并声明 iOS 依赖与 Android AAR 模式。
- `src/addon/storage_service.gd`：给游戏逻辑提供严格类型的统一 GDScript 包装，把调用转发给原生 `SecureStorage`。

### 公共原生实现与平台后端

- `src/native/secure_storage.hpp`：规定错误码、操作结果、后端协议和暴露给 Godot 的存储对象接口。
- `src/native/secure_storage.cpp`：完成参数校验、结果转换、内存测试后端、Godot 方法绑定和 GDExtension 初始化。
- `src/native/platforms.hpp`：声明平台后端创建入口，并复用 Apple Keychain 查询、结果映射及敏感字节清理逻辑。
- `src/native/windows.cpp`：通过当前用户 DPAPI 加解密数据，并以原子替换文件实现 Windows 的读写、删除和命名空间清理。
- `src/native/macos.cpp`：选择 macOS Keychain 的本机可用 accessibility 策略并创建 Apple 后端。
- `src/native/ios.cpp`：选择 iOS `AfterFirstUnlockThisDeviceOnly` accessibility 策略并创建 Apple 后端。
- `src/native/linux.cpp`：运行时加载 libsecret/Secret Service，完成 Linux 密钥存取并把服务或动态库故障映射为统一错误。
- `src/native/android.cpp`：通过 Godot 单例调用 Kotlin 插件，把 Android 操作结果转换为统一原生后端结果。

### Android Plugin v2 工程

- `src/android/build.gradle.kts`：固定 Android Gradle Plugin 与 Kotlin 插件版本，供子模块统一使用。
- `src/android/settings.gradle.kts`：配置插件仓库、依赖仓库和 `plugin` 子模块。
- `src/android/gradle.properties`：限定 Gradle JVM 内存、编码、AndroidX、SDK 下载策略和 Kotlin 风格。
- `src/android/gradlew`：用仓库约定的 Gradle Wrapper 启动 Android 构建。
- `src/android/plugin/build.gradle.kts`：配置 SDK/NDK、arm64 ABI、JDK/Kotlin 17、Godot 依赖和 CMake，并把 GDExtension 配置装入
  AAR。
- `src/android/plugin/CMakeLists.txt`：把公共原生实现与 Android 桥接编译为 `libsecure_storage.so`，并链接预构建 godot-cpp。
- `src/android/plugin/src/main/AndroidManifest.xml`：通过 Godot Plugin v2 元数据声明 Android 插件初始化类。
- `src/android/plugin/src/main/java/com/marcellgu/securestorage/SecureStoragePlugin.kt`：用 Android Keystore AES-256-GCM
  与 `AtomicFile` 实现存取、删除、清空和错误状态传递，并向 Godot 暴露调用方法。

### 构建入口与测试项目

- `src/SConstruct`：选择目标平台源码与系统库，复制 addon 公共文件，并把 C++ 编译结果放进平台对应的 `bin/` 路径。
- `src/project.godot`：组装构建工作区内的最小 Godot 测试项目，启用插件并把测试场景设为启动场景。
- `tests/test_context.gd`：累计 suite、case、断言与失败数量，输出不含秘密值的结构化测试结果。
- `tests/test_runner.gd`：默认调度内存后端契约，在收到 `--real` 时追加真实平台测试，并用退出码报告结果。
- `tests/test_runner.tscn`：让 Godot 启动后实例化测试调度脚本。
- `tests/storage_contract_test.gd`：复用同一组读写、空值、不存在、覆盖、幂等删除、隔离、清空和参数校验契约。
- `tests/memory_backend_test.gd`：在确定性内存后端上执行统一契约，并补测参数边界、错误名称、损坏数据与后端不可用状态。
- `tests/platform_backend_test.gd`：在当前系统安全存储上执行统一契约，并把数据限制在专用测试命名空间内。

## 构建

构建需要 Godot 4.7.1、SCons 4.10.1 和 Git。依赖与中间产物默认放在系统临时目录的 `secure-storage-build/`，可通过
`SECURE_STORAGE_BUILD_ROOT` 改变位置；仓库内的 `src/` 只读参与构建。

```sh
./scripts/build.sh macos template_debug arm64
./scripts/build.sh ios template_release arm64
./scripts/build.sh linux template_debug x86_64
./scripts/build.sh windows template_release x86_64
./scripts/build.sh android template_debug arm64
```

Android 额外需要 JDK 17、SDK 36、NDK `28.1.13356709` 和 CMake `3.22.1`；iOS/macOS 需要对应 Xcode SDK；Linux 需要
libsecret 开发头文件；Windows 需要 Visual Studio C++ 工具链。

`build.sh` 每次只构建一个平台/目标，并把结果合并到根目录的 `addons/SecureStorage/`。要得到完整插件，需要依次合并五个平台的
debug 与 release 构建；CI 会自动完成这一步。构建完成后运行 `./scripts/clean.sh` 清理 addon 和工作目录；如需同时清理依赖与对象缓存，运行
`./scripts/clean.sh --all`。

macOS framework 会生成 `Resources/Info.plist`；插件版本必须以 `major.minor.patch` 三段数字开头，可追加以 `-` 或 `.` 开头的后缀，
framework 版本字段只与其三段数字核心同步。产物保留不含开发者身份的 ad-hoc 签名，确保 Apple Silicon 上的 Godot 编辑器能够直接加载。
最终应用导出时会使用应用自己的签名身份覆盖该签名；构建会拒绝缺少关键 bundle 元数据、完全未签名或意外带有开发者身份的 framework。

## 构建后结构

本地构建会出现两个生成区域：仓库根目录只保留可安装 addon，依赖、对象文件、测试工程和各工具链中间产物留在外部构建根目录。

```text
SecureStorage/
└── addons/
    └── SecureStorage/
        ├── bin/
        │   ├── android/
        │   │   ├── debug/SecureStorage-debug.aar
        │   │   └── release/SecureStorage-release.aar
        │   ├── ios/
        │   │   ├── libgodot-cpp.ios.template_debug.xcframework/
        │   │   ├── libgodot-cpp.ios.template_release.xcframework/
        │   │   ├── libsecure_storage.ios.template_debug.xcframework/
        │   │   └── libsecure_storage.ios.template_release.xcframework/
        │   ├── linux/
        │   │   ├── libsecure_storage.linux.template_debug.x86_64.so
        │   │   └── libsecure_storage.linux.template_release.x86_64.so
        │   ├── macos/
        │   │   ├── libsecure_storage.macos.template_debug.framework/
        │   │   └── libsecure_storage.macos.template_release.framework/
        │   └── windows/
        │       ├── secure_storage.windows.template_debug.x86_64.dll
        │       └── secure_storage.windows.template_release.x86_64.dll
        ├── export_plugin.gd
        ├── icon.svg
        ├── plugin.cfg
        ├── plugin.gd
        ├── secure_storage.gdextension
        └── storage_service.gd
```

外部构建根目录默认位于 `${TMPDIR:-/tmp}/secure-storage-build/`：

```text
secure-storage-build/
├── deps/
│   ├── godot-cpp/
│   └── extension_api_4.7.1.json
├── gradle-home/
├── obj/
│   └── <platform>-<target>-<arch>/
├── scons-cache/
├── sconsign/
└── work/
    └── <platform>-<target>-<arch>/
        ├── .deps/
        ├── addon/
        ├── android/
        ├── native/
        ├── tests/
        ├── addons/SecureStorage/
        ├── project.godot
        └── SConstruct
```

CI 为 Apple、Windows、Linux 分别维护依赖缓存与对象缓存。稳定的 `deps/` 缓存按 runner 镜像和固定工具链输入失效；`obj/`、
`scons-cache/` 与 `sconsign/` 缓存额外包含原生源码内容 hash。其中 `scons-cache/` 由 SCons 按构建输入的内容签名管理，跨 runner 恢复时不依赖对象文件的时间戳或签名库状态。源码变化时先按 restore key 恢复上一版缓存，只编译变化的输入。`work/` 每次重新组装，避免复用测试工程和打包暂存文件；`obj/` 内部继续按平台、目标和架构隔离。
runner 镜像或任一固定构建输入变化时会使用新缓存，避免复用 ABI 不兼容的原生对象。

完整 CI 包会在上述 addon 中再加入 `docs/api.md` 与 `docs/testing.md`，随后生成：

```text
dist/
├── SecureStorage-<版本或commit前12位>.zip
└── SecureStorage-<版本或commit前12位>.zip.sha256
```

普通 push、pull request 和手动运行使用 commit 前 12 位作为包版本。正式发布前更新 `src/addon/plugin.cfg` 中的 `version`，提交后推送
同版本 tag（例如 `v1.0.0`）；CI 会重新构建并验证全部平台，使用 `1.0.0` 作为包版本，然后创建带自动生成说明的 GitHub Release。
tag 版本与插件版本不一致时，打包任务会失败且不会发布。

安装时把 ZIP 中的 `addons/SecureStorage/` 合并到 Godot 工程根目录，并在项目设置中启用插件。Android 导出需要 Gradle
build，iOS 导出需要有效签名。

## 安全模型

- Windows 使用当前用户 DPAPI；密文以原子替换方式保存。
- macOS/iOS 使用 Security.framework Keychain；iOS accessibility 为 `AfterFirstUnlockThisDeviceOnly`。
- Android 使用不可导出的 Android Keystore AES-256 密钥与 AES-GCM，并用 `AtomicFile` 持久化。
- Linux 运行时使用 Secret Service/libsecret；服务不可用时返回 `UNAVAILABLE`。

插件只识别自己的新格式，不读取、迁移或删除旧版安全存储数据。它防止普通明文落盘，但不防御已控制进程、能读取进程内存或已解锁当前用户会话的攻击者。

## 图标来源

插件锁形图标来自 [Nieobie/game-icon-pack](https://github.com/Nieobie/game-icon-pack)，原项目以 CC0 1.0 Universal 发布。
