# 仓库协作约束

## 沟通与审查

- 使用中文与用户沟通。
- 每次修改都从公开契约、数据流和可复现性出发，并进行对抗式审查。
- 不要勉强自己读取 `README.md`；可以让 harness 提取当前任务需要的内容。
- 对用户要求的局部修改，只实施达成目标所必需的最小变更。不得擅自增加防回归检查、额外 preflight 契约、禁止性条款、抽象层或配置变量；如果认为额外修改确有必要，必须先说明具体原因和拟修改内容，并取得用户确认后再实施。

## 根目录与白名单

仓库采用 deny-all `.gitignore`。除 Git 元数据外，允许的根级入口只有：

- `.gitignore`
- `.github/`
- `AGENTS.md`
- `LICENSE`
- `README.md`
- `export_presets.cfg`
- `main.gd`
- `main.tscn`
- `project.godot`
- `addon/`
- `android/`
- `docs/`
- `scripts/`
- `src/`

新增需要提交的文件时必须精确更新 `.gitignore` 白名单，禁止使用递归放行绕过白名单。

`.github/` 只允许 `workflows/build.yml`、`actions/` 下列目录各自的 `action.yml`，以及下文列出的
`.github/scripts/*.sh`：

- 复杂 stage Action：`build-apple`、`build-windows`、`build-linux`、`build-android`、
  `e2e-macos`、`e2e-ios`、`e2e-windows`、`e2e-linux`、`e2e-android`。

`build.yml` 负责任务编排、runner、依赖关系、权限及轻量门禁；四个 `build_*` 与五个 `e2e_*` job 在 checkout 后必须调用
对应的复杂 stage Action。复杂 stage Action 只能组合 `actions/cache`、`actions/setup-java`、emulator runner、Artifact
传递、对应的 `.github/scripts/setup-*.sh`、`.github/scripts/invalidate-cache.sh`、约定 build 脚本、公共 `test.sh` 及对应
平台 adapter，不得复制脚本中的
安装、构建或测试实现。候选解包统一调用 `.github/scripts/extract-candidate.sh`。依赖下载 URL 与 SHA-256 必须直接硬编码在实际执行安装的脚本中，缓存 key 必须直接硬编码在
实际使用缓存的复杂 stage Action 中；禁止常量层、版本输入与动态拼接。

## 源码、插件骨架与生成物

- 当前唯一发布基线为 `1.0.0`，只支持当前 `SecureStorage` GDScript `StorageResult` 类型层级 API；不提供旧
  API、旧包装器或持久化身份的兼容层。
- 本项目是供第三方宿主集成的库，严禁在任何平台实现、构建脚本或默认配置中硬编码作者或本项目的身份作为宿主存储命名空间、目标前缀或持久化键前缀；尤其禁止
  `constexpr wchar_t TARGET_PREFIX[] = L"com.marcellgu.securestorage/";` 及任何等价写法。
- Apple 后端必须从 `secure_storage/apple_access_group` 读取宿主显式提供且由签名 entitlement 授权的完整 Keychain access
  group，并在所有 SecItem 查询中限定该组；不得猜测默认组或在配置缺失时通配宿主全部授权组。
- `src/` 只保存原生源码和 SCons 配置。公共契约与入口为 `backend.hpp`、`extension.cpp`；平台实现为
  `apple.mm`、`linux.cpp`、`windows.cpp`。
- `android/` 是纯 Kotlin AAR 工程，不得加入 NDK、CMake、JNI 或 Android GDExtension。
- `android/` 必须跟踪 Gradle 8.14.3 官方 Wrapper 的 Unix/Windows 启动脚本、Wrapper JAR 与 properties；发行包与 Wrapper JAR
  校验值必须由 CI 预检固定验证。
- `addon/` 只跟踪六个插件结构文件。`addon/bin/` 是构建输出，必须被 Git 忽略；禁止提交 framework、xcframework、DLL、SO 或 AAR。
- 汇总发行包时必须从六个已跟踪结构文件开始，在全新目录中显式加入各平台产物；禁止递归复制整个本地 `addon/`
  ，避免把被忽略的陈旧文件带入发行包。候选 ZIP 必须使用固定时间戳、排序路径与固定压缩参数。
- 仓库根目录是唯一测试项目，项目名固定为 `TestSecureStorage`。它只能通过公开 `SecureStorage` API 做黑盒 E2E，启动后打印固定
  PASS/FAIL 标记并结束测试；不得恢复 `test/` 或其他测试项目目录。
- 不得恢复内存后端测试、平台内部测试、Android instrumentation 测试或另一套测试 harness。
- 依赖、中间产物、临时测试项目和导出应用默认写入 `${TMPDIR:-/tmp}/secure-storage-build/`；可通过
  `SECURE_STORAGE_BUILD_ROOT` 覆盖。
- `addon/` 与根目录 `main.gd` 中不得使用 GDScript `:=` 类型推断。`TestSecureStorage` 必须使用仓库内固定的非生产测试值，并在每一步
  CI 输出中按 `operation=<方法> domain=<domain> key=<key> value=<value>` 或
  `operation=<方法> code=<错误码> message=<消息>` 完整打印公开结果。每个调用必须以 release 也会执行的普通控制流断言公开返回
  类型和全部字段：成功精确匹配 `domain/key/value`，预期错误精确匹配 `ErrorType` 且 `message` 非空；不得只打印结果或依赖可能被
  release 禁用的 GDScript `assert()`。不得向测试项目注入真实宿主秘密。
- 不得加入 C#/.NET 源文件。

## 约定脚本

`scripts/` 必须且只能包含：

- `build_apple.sh`
- `build_windows.sh`
- `build_linux.sh`
- `build_android.sh`
- `test.sh`
- `ios_adapter.sh`
- `test_ios_pte.sh`
- `macos_adapter.sh`
- `test_macos_pte.sh`
- `windows_adapter.sh`
- `linux_adapter.sh`
- `android_adapter.sh`

`.github/scripts/` 必须且只能包含：

- `extract-candidate.sh`
- `invalidate-cache.sh`
- `setup-android-emulator.sh`
- `setup-android-sdk.sh`
- `setup-ci.sh`
- `setup-godot-cpp.sh`
- `setup-godot-linux.sh`
- `setup-godot-macos.sh`
- `setup-godot-windows.sh`
- `setup-godot-templates-linux.sh`
- `setup-godot-templates-macos.sh`
- `setup-godot-templates-windows.sh`
- `setup-ios-simulator.sh`
- `setup-linux-build.sh`
- `setup-linux-e2e.sh`
- `setup-scons-linux.sh`
- `setup-scons-macos.sh`
- `setup-scons-windows.sh`

`.github/scripts/extract-candidate.sh` 是五个 E2E stage 共用的候选校验与解包实现，并通过 `SECURE_STORAGE_ADDON_DIR`
传递已验证候选目录。`test.sh` 必须把该目录完整复制到外部测试工程，adapter 不得选择性复制候选子目录。所有 `setup-*.sh`
只处理其命名依赖的安装、下载、恢复后校验或运行环境准备；存在平台差异的 Godot editor、export templates 与 SCons 必须使用明确的
`-macos`、`-windows`、`-linux` 脚本，不得在脚本内部按 OS 分支。跨运行缓存的恢复与保存由调用脚本的复杂 stage Action 负责。

四个 build 脚本默认同时构建 debug/release；`build_apple.sh` 同时生成 macOS 与 iOS。`test.sh` 统一负责候选结构校验、
外部测试工程 staging、Godot 版本校验、debug/release 与 WRITE/READ 循环及终态判定；五个平台 `*_adapter.sh` 只负责对应平台
的候选产物安装、导出、启动、日志收集、进程终止和平台诊断。公共驱动及 adapter 只能消费已经构建或由
`SECURE_STORAGE_ADDON_DIR` 指定的候选插件，不得调用任何 build 脚本。`test_ios_pte.sh` 与 `test_macos_pte.sh` 只供本机
Personal Team 人工签收：缺少必填环境配置时从交互式终端读取，导出同一根目录宿主，打开临时 Xcode 工程并由用户选择签名；
非交互终端缺少必填配置时必须失败，CI 不得调用这两个入口。

`docs/` 只允许 `api.md`、`testing.md`。修改仓库结构、白名单或脚本入口时，必须同步更新 `README.md`、本文件和 CI 预检。

## CI 与平台约束

- CI 阶段固定为 `preflight` → 四个模块 `build_*` → `assemble_addon` → 五个平台 `e2e_*` →
  `ci_complete` → tag `release`。
- `push` 完整流程只覆盖 `main` 与 `v*` tag；分支评审由 `pull_request` 覆盖。仅 `README.md`、`LICENSE`、`docs/**`
  变化时只运行 `preflight` 与 `ci_complete`，其他路径、无法分类的变更、tag 与手动运行必须进入完整流程。
- 每个平台必须提供 debug/release。五个 E2E 必须下载同一个候选 ZIP，并调用 `test.sh <platform>` 通过对应 adapter 启动
  `TestSecureStorage`；禁止重编译 addon 后端。
- GitHub 托管 runner 的 Apple E2E 使用 ad-hoc 宿主。宿主统一输出 `result=ERROR error_type=3 message=<完整平台诊断>`； CI
  只有在公开探针返回 `StorageError.PLATFORM_ERROR` 且完整 message 包含 `(-34018)` 时才接受该结果。其他失败必须 fail
  closed；macOS 该路径还必须以测试宿主约定的状态 `1` 退出，禁止把崩溃信号当作预期错误。本机 Xcode Personal Team 宿主的完整
  PASS 是 Data Protection Keychain 的签收边界。
- 完整流程中的 `ci_complete` 对失败、取消和跳过全部 fail closed；轻量文档路径只允许在 `preflight` 成功且所有平台任务均为
  `skipped` 时成功。Release 只能原样提升已经通过全部 E2E 的候选 ZIP。
- Godot editor 与 export templates 只缓存固定 SHA-256 的原始归档，恢复后必须重新校验。SCons 只缓存内容寻址目录，
  Gradle 只缓存外部 user home 的依赖与 Wrapper，Android AVD
  只缓存运行测试前生成的干净 snapshot。候选/模块 Artifact、构建输出、测试 home、
  keyring、keystore 与运行后设备状态不得进入 cache。缓存 key 不得包含人工 schema epoch；缓存内容恢复后校验失败时必须删除
  对应远端缓存，并继续使用同一身份 key。任何缓存命中都不得成为信任边界。
- Preflight 必须以固定版本和固定归档 SHA-256 运行 ShellCheck 与 actionlint；ShellCheck 覆盖所有约定脚本，外部 Action
  必须固定完整 commit SHA。
- CI 固定常量必须以字面量写在实际使用位置，禁止通过自定义变量或常量层间接提供；运行时数据以及 GitHub、runner、shell
  和 PowerShell 内建变量不受此限制。`SCONSFLAGS`、`GH_TOKEN`、`GH_REPO` 是明确例外。
- CI 任务标识与显示名固定为：`preflight` / `Preflight`、`build_apple` / `Build Apple`、`build_windows` /
  `Build Windows`、`build_linux` / `Build Linux`、`build_android` / `Build Android`、`assemble_addon` /
  `Assemble addon`、`e2e_macos` / `E2E macOS`、`e2e_ios` / `E2E iOS Simulator`、`e2e_windows` /
  `E2E Windows`、`e2e_linux` / `E2E Linux`、`e2e_android` / `E2E Android`、`ci_complete` / `CI complete`、
  `release` / `Publish release`。
- macOS runner 构建 Apple 模块，Windows runner 构建 Windows，Ubuntu runner 构建 Linux 与 Android。
- Android 使用 JDK 17、SDK 36、Build Tools `36.0.0`。E2E 在 API 24 x86_64 模拟器启动一次测试项目；arm64
  物理设备仍是最终真实存储签收边界。
- iOS/macOS 使用对应 Xcode SDK；Linux 构建和运行时需要 libsecret 0.19.0 或更高版本；Windows 需要 Visual Studio C++ 工具链。
- iOS 应用不能依赖自行终止进程来报告成功：CI 测试项目打印终态后，`ios_adapter.sh` 负责停止模拟器应用。
