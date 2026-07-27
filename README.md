# SecureStorage

SecureStorage 是面向 Godot 4.7.1 的跨平台同步安全存储插件。游戏代码只使用 GDScript `SecureStorage`；后端分别使用：

- Windows：C++ 与 Credential Manager
- Linux：C++ 与 Secret Service/libsecret
- macOS、iOS：Objective-C++ 与 Keychain
- Android：Kotlin、Keystore 与 `AtomicFile`

项目不包含 C#/.NET。Android 是纯 Kotlin AAR，不使用 C++、JNI、NDK 或 CMake。当前发布基线为 `1.0.0`，唯一公开契约是
[`docs/api.md`](docs/api.md) 中的 `StorageResult` 类型层级 API。

## 安装

发行 ZIP 使用 Godot 标准路径 `addons/SecureStorage/`。安装新版本前应完整删除项目中的旧目录，再解压新版本；不要把两个版本合并。
启用插件后：

- Android 需要安装 Gradle build template，并在导出预设中使用 Gradle Build。
- iOS 由导出插件加入 Security、CoreFoundation 与 Foundation 链接参数。
- Windows、Linux、macOS 由 `.gdextension` 根据平台和 debug/release 选择对应原生库。

Apple 宿主还必须在 `project.godot` 中提供自身已获签名 entitlement 授权的完整 Keychain access group：

```ini
[secure_storage]

apple_access_group="ABCDE12345.com.example.game"
```

该值属于宿主持久化身份，插件不提供默认值，也不会根据 bundle id 或插件身份猜测。macOS/iOS 缺少配置时，公开操作返回
`StorageError.PLATFORM_ERROR`；配置存在但未被宿主 entitlement 授权时，Security.framework 返回完整平台诊断。

仓库根目录的 `addon/` 是插件骨架和本地构建输出位置，不是最终 ZIP 的顶层路径。

## 项目结构

```text
SecureStorage/
├── addon/
│   ├── export_plugin.gd
│   ├── icon.svg
│   ├── plugin.cfg
│   ├── plugin.gd
│   ├── secure_storage.gd
│   ├── secure_storage.gdextension
│   └── bin/                         # 构建生成，Git 忽略
├── android/
│   ├── plugin/
│   │   ├── src/main/java/com/marcellgu/securestorage/AndroidBackend.kt
│   │   ├── src/main/AndroidManifest.xml
│   │   └── build.gradle.kts
│   ├── gradle/wrapper/
│   │   ├── gradle-wrapper.jar
│   │   └── gradle-wrapper.properties
│   ├── build.gradle.kts
│   ├── gradle.properties
│   ├── gradlew
│   ├── gradlew.bat
│   └── settings.gradle.kts
├── src/
│   ├── SConstruct
│   ├── apple.mm
│   ├── backend.hpp
│   ├── extension.cpp
│   ├── linux.cpp
│   └── windows.cpp
├── export_presets.cfg
├── main.gd
├── main.tscn
├── project.godot
├── scripts/
│   ├── build_android.sh
│   ├── build_apple.sh
│   ├── build_linux.sh
│   ├── build_windows.sh
│   ├── android_adapter.sh
│   ├── ios_adapter.sh
│   ├── test_ios_pte.sh
│   ├── linux_adapter.sh
│   ├── macos_adapter.sh
│   ├── test_macos_pte.sh
│   ├── test.sh
│   └── windows_adapter.sh
├── docs/
│   ├── api.md
│   └── testing.md
└── .github/
    ├── actions/
    │   ├── build-android/action.yml
    │   ├── build-apple/action.yml
    │   ├── build-linux/action.yml
    │   ├── build-windows/action.yml
    │   ├── e2e-android/action.yml
    │   ├── e2e-ios/action.yml
    │   ├── e2e-linux/action.yml
    │   ├── e2e-macos/action.yml
    │   └── e2e-windows/action.yml
    ├── scripts/
    │   ├── extract-candidate.sh
    │   ├── invalidate-cache.sh
    │   ├── setup-android-emulator.sh
    │   ├── setup-android-sdk.sh
    │   ├── setup-ci.sh
    │   ├── setup-godot-cpp.sh
    │   ├── setup-godot-linux.sh
    │   ├── setup-godot-macos.sh
    │   ├── setup-godot-windows.sh
    │   ├── setup-godot-templates-linux.sh
    │   ├── setup-godot-templates-macos.sh
    │   ├── setup-godot-templates-windows.sh
    │   ├── setup-ios-simulator.sh
    │   ├── setup-linux-build.sh
    │   ├── setup-linux-e2e.sh
    │   ├── setup-scons-linux.sh
    │   ├── setup-scons-macos.sh
    │   └── setup-scons-windows.sh
    └── workflows/build.yml
```

边界只有三条：

1. `src/` 与 `android/` 是平台实现源码。
2. `addon/` 只跟踪六个插件结构文件；所有二进制由构建脚本注入 `addon/bin/`，且永不进入 Git。
3. 根目录 Godot 项目是唯一测试实现。没有 `test/`、内存后端、平台内部测试、Android instrumentation 或另一套测试 harness。

## 构建

依赖和中间产物默认位于 `${TMPDIR:-/tmp}/secure-storage-build/`，可用 `SECURE_STORAGE_BUILD_ROOT` 覆盖。四个入口均默认构建
debug/release：

```sh
./scripts/build_apple.sh
./scripts/build_windows.sh
./scripts/build_linux.sh
./scripts/build_android.sh
```

`build_apple.sh` 同时生成 macOS universal 与 iOS device/simulator XCFramework。通用原生依赖为 Godot 4.7.1、SCons 4.10.1
和固定提交的 godot-cpp。Android 需要 JDK 17、SDK 36、Build Tools `36.0.0`；Linux 构建和运行时需要 libsecret 0.19.0
或更高版本；Windows 需要 Visual Studio C++ 工具链，产物运行基线为 Windows 10 / Windows Server 2016 或更高版本。

公开方法是同步调用。Linux 的 libsecret 同步 API 可能无限等待服务或用户提示，游戏代码必须从工作线程调用，不能阻塞 Godot
主线程或其他 UI 线程。

输出为：

```text
addon/bin/
├── android/{debug,release}/SecureStorage-*.aar
├── ios/*.xcframework/
├── linux/*.so
├── macos/*.framework/
└── windows/*.dll
```

Android 构建使用仓库跟踪的 Gradle 官方 Wrapper。构建脚本不生成或修改测试项目，也不会把依赖、对象文件或 Gradle build
目录写入源码树。

## E2E

先构建对应平台，再运行：

```sh
SECURE_STORAGE_APPLE_ACCESS_GROUP=ABCDE12345.com.example.game ./scripts/test.sh macos
SECURE_STORAGE_APPLE_ACCESS_GROUP=ABCDE12345.com.example.game ./scripts/test.sh ios
./scripts/test.sh windows
./scripts/test.sh linux
./scripts/test.sh android
```

公共 `test.sh` 把根目录 Godot 宿主和 `${SECURE_STORAGE_ADDON_DIR:-addon}` 的完整候选插件递归复制到外部临时工程；E2E stage
会先调用公共解包脚本验证并解包候选，再通过 `SECURE_STORAGE_ADDON_DIR` 传递该候选目录。公共驱动统一执行候选结构校验、
完整 staging、debug/release 与 WRITE/READ 循环和终态判定；五个平台 adapter 不选择性复制候选子目录，只处理对应平台的
导出、安装、启动、日志与进程生命周期。驱动分别导出并启动 debug/release
`TestSecureStorage`。每个变体启动两次：第一次只通过公开 GDScript API 写入真实后端并退出，第二次在新进程中读取相同数据，
再执行覆盖、空值、domain 隔离、删除与清空。每次公开调用都会输出实际结果，并以 release 也会执行的控制流断言成功结果的
`domain/key/value` 或错误结果的 `ErrorType` 与非空 `message`；任何不匹配立即输出 `ASSERTION_FAILED` 和 `FAIL` 并退出。
终态同时报告运行时的 `DEBUG`/`RELEASE` feature。这使 CI 日志能直接展示
跨进程持久化以及实际运行的导出变体，而不只是证明单进程内缓存或调用了某个导出命令。

桌面平台从 stdout 读取终态，Android 使用 PID 限定的 Logcat，iOS 使用进程与 subsystem 限定的 Simulator unified log。每个
公开 API 调用都会把固定的非生产测试值及实际 `domain/key/value` 或 `type/message` 完整写入 CI 日志。iOS 在看到终态后由脚本
终止宿主应用，因为 UIKit 不允许普通应用自行结束进程。完整执行方式和设备边界见 [`docs/testing.md`](docs/testing.md)。

本机 Personal Team 签收使用独立入口，不改变 CI 的 ad-hoc 行为：

```sh
./scripts/test_macos_pte.sh
./scripts/test_ios_pte.sh
```

脚本会在终端询问环境中缺失的完整 Apple Keychain access group；也可以继续用
`SECURE_STORAGE_APPLE_ACCESS_GROUP=ABCDE12345.com.example.game` 预先提供。默认 `godot` 命令或仓库 `addon/` 不可用时，
脚本会继续询问对应路径；非交互终端缺少这些配置时直接失败。

两个入口都生成已经装入当前候选的 debug/release Xcode 项目并打开 Xcode。iOS 使用 Godot 原生导出的 Xcode 工程；macOS
先导出 `.app`，再生成只负责把该导出物组装为 Xcode target、请求 Personal Team provisioning profile 并签名运行的临时宿主。
在 Xcode 中确认与 access group 前缀一致的 Team，iOS 选择真机、macOS 选择 My Mac 后运行，控制台必须输出唯一 `PASS` 终态。
PTE 工程全部位于外部构建目录，不进入候选包，也不由 CI 调用。

GitHub 托管 runner 使用 ad-hoc Apple 宿主。CI 只额外接受首个真实探针返回
`StorageError.PLATFORM_ERROR` 且完整诊断包含 `(-34018)` 的统一错误结果：
`result=ERROR error_type=3 message=<完整平台诊断>`。其他 Apple 故障仍然使 E2E 失败。本机 Personal Team 宿主的完整 `PASS`
用于签收 Data Protection Keychain 实际能力。macOS 接受预期错误时还要求进程按宿主约定返回状态 `1`，崩溃信号或其他非零状态
仍然失败。

## CI 与发布

CI 只允许以下数据流：

```text
preflight
    -> build_apple | build_windows | build_linux | build_android
    -> assemble_addon
    -> e2e_macos | e2e_ios | e2e_windows | e2e_linux | e2e_android
    -> ci_complete
    -> tag release
```

`push` 只对 `main` 与 `v*` tag 运行完整流程，分支评审由 `pull_request` 覆盖，避免同仓库 PR 的同一提交重复执行。只有
`README.md`、`LICENSE`、`docs/**` 变化时，`preflight` 验证仓库契约后由 `ci_complete` 确认所有平台任务均按计划跳过；
其他路径、无法分类的变更、tag 与手动运行都 fail closed 到完整流程。

汇总任务在全新目录中精确复制六个已跟踪插件文件和五个平台产物，以固定时间戳、排序路径和固定压缩参数只生成一次确定性候选
ZIP。五个平台
E2E 下载并运行同一个候选，不调用 build 脚本；Apple job 可报告完整 `PASS`，也可报告同时通过错误类型与 message
断言的预期平台错误；其余门禁保持完整 `PASS`。Release 只原样提升已经通过全部门禁的 ZIP 与校验文件。

`build.yml` 保留任务编排与轻量门禁；四个 `build_*` 和五个 `e2e_*` 可见复杂 stage 在 checkout 后调用对应的独立 Action。
这些 stage Action 直接组合固定的 `actions/cache`、`actions/setup-java`、emulator runner、Artifact 传递、约定 build 脚本、
公共 `test.sh`、对应平台 adapter 以及公共 `.github/scripts/extract-candidate.sh`。Godot、godot-cpp、SCons、Linux、JDK/Android SDK、iOS Simulator 与
Android API 24 Emulator 的下载、安装、环境准备和恢复后校验分别由独立 `.github/scripts/setup-*.sh` 实现；Godot editor、
export templates 与 SCons 按 macOS、Windows、Linux 使用不同脚本。跨运行缓存只能由 GitHub
`actions/cache` 完成，因此缓存 restore/save 及固定 key 直接保留在对应的 `build-*` 或 `e2e-*` Action 中。缓存 key 不使用
人工 schema epoch；恢复后的内容校验失败时删除对应远端条目，后续仍以同一身份 key 重建。

固定常量直接写在实际使用位置，不通过自定义变量或常量层间接提供；运行时数据与 GitHub、runner 和 shell 内建变量不受此限制，
`SCONSFLAGS`、`GH_TOKEN`、`GH_REPO` 是明确例外。依赖下载 URL 与 SHA-256 不接受配置输入，也不动态拼接。Godot editor 与
export templates 缓存经过固定 SHA-256 的原始归档，恢复后仍重新校验；原生构建只缓存 SCons 内容寻址目录，Android 只缓存外部
Gradle 依赖/Wrapper 和测试前生成的干净 AVD snapshot。

`preflight` 运行固定版本且校验下载 SHA-256 的 ShellCheck 和 actionlint，覆盖 workflow、复合 Action metadata 与所有约定
shell 脚本。所有外部 Action 均固定到完整 commit SHA。

`.gitignore` 采用 deny-all 白名单。即使本地 `addon/bin/` 有旧产物，汇总任务也不会递归复制整个 `addon/`，从而避免隐藏文件或
陈旧二进制混入发行包。

## 许可证

SecureStorage 使用 [Apache License 2.0](LICENSE)。锁形图标来自
[Nieobie/game-icon-pack](https://github.com/Nieobie/game-icon-pack)，以 CC0 1.0 Universal 发布。
