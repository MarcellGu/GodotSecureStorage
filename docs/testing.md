# 测试

## 唯一测试对象

仓库根目录是一个最小 Godot 项目，项目名为 `TestSecureStorage`。它启动后只通过根目录插件骨架中的
`res://addon/secure_storage.gd` 和 `SecureStorage` 的 `StorageResult` 类型层级 API 访问真实平台后端。

仓库不保留以下第二套测试实现：

- 注入式内存后端；
- C++、Objective-C++ 或 Kotlin 平台内部自测；
- Android instrumentation/反射 ABI 测试；
- iOS 静态库链接探针；
- 独立测试框架或平台专用测试用例。

平台差异只存在于五个 CI shell 脚本如何导出、安装、启动同一个项目以及如何取得其终态日志。两个 Apple PTE 脚本只生成并打开
签名宿主，不包含另一套测试逻辑。

## 黑盒状态机

每个 debug/release 变体都运行两个相互独立的进程：

1. 写入进程通过真实写入、读回、删除和 `NOT_FOUND` 完成显式探针，清理测试 domain，写入普通值、空字符串和隔离 domain，然后打印
   `TEST_SECURE_STORAGE phase=WRITE variant=<DEBUG|RELEASE> result=PASS` 并退出。
2. 读取进程从真实后端取回上一进程的数据，再执行写后读回值、空字符串、`NOT_FOUND`、domain 隔离、删除幂等性与同一 domain 多个
   key 的完整清空，逐步打印实际结果，最后打印
   `TEST_SECURE_STORAGE variant=<DEBUG|RELEASE> result=PASS` 并退出。

两个进程都只使用公开 `SecureStorage` API 访问仓库内固定的非生产测试值。桌面与 iOS harness 通过不含载荷的环境变量显式选择阶段；
Android 使用只含 `READ` 的 `user://` 编排标记。两者都不替代后端存储。每个公开调用立即打印一行：成功完整输出实际
`operation/domain/key/value`，错误完整输出 `operation/code/message`。紧接着使用 release 导出也会执行的普通控制流检查公开
返回对象：成功必须为 `StorageSuccess` 且 `domain/key/value` 与该步期望完全相等；预期失败必须为 `StorageError`、`ErrorType`
完全相等且 `message` 非空。这里不使用可能在 release 中被禁用的 GDScript `assert()`。不得通过 CI 变量或测试设备向该项目注入
真实宿主秘密。输出格式是：

```text
operation=set_value domain=com.marcellgu.testsecurestorage.primary key=primary value=blackbox-value-one
operation=get_value code=2 message=<完整错误消息>
```

最终成功终态是：

```text
TEST_SECURE_STORAGE variant=DEBUG result=PASS
```

release 导出对应把 `DEBUG` 换为 `RELEASE`；脚本必须验证该字段与请求的导出变体一致。失败打印固定
`TEST_SECURE_STORAGE result=FAIL`，并以非零 SceneTree 退出码结束；此前的逐步记录保留实际测试载荷和完整平台诊断。
字段断言失败前还会打印 `ASSERTION_FAILED operation=<方法> ...`；公共驱动显式拒绝该标记，即使未来的测试控制流错误地产生
`PASS` 也会 fail closed。只有当前阶段全部返回值断言通过后才能打印 `PASS`。

Apple 宿主支持两种运行方式：

- 严格模式是本地默认值。Xcode 使用 Personal Team 签名后，宿主在一次手动运行中依次执行写入与读取流程，完整输出每一步结果，
  最后输出唯一 `PASS` 或 `FAIL` 终态。
- 宿主的首个真实 Keychain 探针失败时总是如实输出结构化 `ERROR` 并以失败状态结束。GitHub Actions 中的 CI ad-hoc
  模式由 Apple adapter 根据内建 `GITHUB_ACTIONS` 自动开启；harness 只有在错误为
  `StorageError.PLATFORM_ERROR` 且消息包含 `(-34018)` 时才接受：

```text
TEST_SECURE_STORAGE variant=DEBUG result=ERROR error_type=3 message=<完整平台诊断>
```

macOS 与 iOS 共用该错误格式。CI 同时断言 `error_type=3` 与完整 `message` 中的 `(-34018)`，由此确认当前 ad-hoc 宿主缺少
Apple entitlement。其他错误类型、其他 `OSStatus`、启动失败、崩溃、超时和异常日志继续让 E2E 失败。签名宿主的完整 `PASS`
是 Apple Data Protection Keychain 的实际签收结果。

## 执行

四个构建入口先把 debug/release 平台产物写入 `addon/bin/`：

```sh
./scripts/build_apple.sh
./scripts/build_windows.sh
./scripts/build_linux.sh
./scripts/build_android.sh
```

随后由当前平台调用对应 E2E：

```sh
SECURE_STORAGE_APPLE_ACCESS_GROUP=ABCDE12345.com.example.game ./scripts/test.sh macos
SECURE_STORAGE_APPLE_ACCESS_GROUP=ABCDE12345.com.example.game ./scripts/test.sh ios
./scripts/test.sh windows
./scripts/test.sh linux
./scripts/test.sh android
```

公共测试驱动支持：

- `SECURE_STORAGE_ADDON_DIR`：指定已经汇总并解压的候选插件目录；
- `SECURE_STORAGE_BUILD_ROOT`：指定外部临时工作根；
- `GODOT_BIN`：指定 Godot 4.7.1 editor；
- `SECURE_STORAGE_APPLE_ACCESS_GROUP`：macOS/iOS 测试宿主获 entitlement 授权的完整 Keychain access group；两个 Apple
  Apple adapter 在导出前把它注入临时测试项目，缺失、没有 Team ID 前缀或包含标识符之外字符时 fail closed；
- `SECURE_STORAGE_PTE_OPEN_XCODE=0`：只生成 PTE 工程并打印路径，不自动打开 Xcode；默认值 `1`；
- `SECURE_STORAGE_TEST_ALLOW_EXPECTED_PLATFORM_ERROR=1`：供 CI 外复现 ad-hoc Apple 宿主的预期错误模式；GitHub Actions
  中不设置该自定义变量；
- 平台工具链自身要求的 Android SDK、Java、Xcode、模拟器或设备变量。

`test.sh` 与五个平台 adapter 不得调用任何 `build_*.sh`。公共驱动统一把完整候选插件复制进测试工程，并负责 staging、
变体/阶段循环和终态门禁；adapter 不选择性复制候选子目录，只负责平台导出、安装、启动、日志与进程生命周期。缺少候选二进制、
导出模板或运行设备时必须 fail closed。严格模式要求 `PASS`；Apple CI 模式只额外接受
`error_type=3` 且完整 message 包含 `(-34018)` 的错误结果。 iOS 导出器运行在 macOS，因此候选同时需要 macOS 与 iOS
产物；Android 导出器运行在 Linux，因此候选同时需要 Linux 与 Android 产物。CI 汇总候选天然满足这两个 host/target 交叉导出条件。

本机 Personal Team 签收使用与 CI 分离的两个入口：

```sh
./scripts/test_macos_pte.sh

./scripts/test_ios_pte.sh
```

在交互式终端中，脚本会询问没有通过环境变量提供的完整 Apple Keychain access group。默认 `godot` 命令或仓库 `addon/`
不可用时也会询问对应路径。自动化调用仍可显式设置 `SECURE_STORAGE_APPLE_ACCESS_GROUP`、`GODOT_BIN` 与
`SECURE_STORAGE_ADDON_DIR`；非交互终端缺少必填配置时 fail closed。

两个脚本都先把根目录 Godot 项目与指定候选复制到外部构建目录，再分别导出 debug/release，并打开生成的 `.xcodeproj`。iOS
直接使用 Godot 导出的 Xcode 工程；Godot 的 macOS 导出物只有 `.app`，因此 macOS 脚本额外生成一个临时 Xcode application
target，把原始 `.app` 的可执行文件、资源和 GDExtension framework 装入最终产品，随后交给 Xcode 自动签名。该 target
不实现测试 API，也不替换候选二进制。

在 `Signing & Capabilities` 中确认 `TestSecureStorage` target 使用与 access group 前缀一致的 Personal Team。iOS 选择签名真机，
macOS 选择 `My Mac`，然后按 Run。工程已携带完整 `keychain-access-groups`；未注入 CI 阶段变量时，宿主会在一次运行中完成整套
公开 API 流程并在控制台打印唯一终态。PTE 只接受完整 `PASS`，不接受 `(-34018)`。

## 平台启动方式

- macOS：CI 导出并启动 debug/release `.app`，只使用 Data Protection Keychain；ad-hoc 宿主只可报告精确的 entitlement
  有限结果。本机 PTE 脚本用临时 Xcode target 对同一导出物申请 provisioning profile 并签名运行。
- Windows：导出并启动 debug/release console wrapper，读取 stdout 与进程退出码。
- Linux：在独立 D-Bus session 与临时 Secret Service 中导出并启动 debug/release 应用。
- Android：使用 Gradle build template 导出 APK，安装到目标设备后启动；Godot tag 日志提供唯一终态，PID 全量 Logcat
  保留逐步结果并检查运行时错误，终态后还必须观察到 Activity 自然退出。
- iOS：CI 导出 Xcode 工程，用 Xcode 构建 Simulator 应用，安装并启动后，从同时限定应用进程和 bundle subsystem 的 unified
  log 读取终态。看到终态后由脚本调用 `simctl terminate`；UIKit 不保证 `get_tree().quit()` 能结束宿主进程。本机 PTE
  脚本打开同类工程，由用户选择 Personal Team 与真机。

Android/iOS 的启动命令返回值不是 GDScript 测试结果，因此脚本必须同时使用超时、终态唯一性和 FAIL 标记检查。桌面平台也必须 检查
stdout 终态，不能只相信进程退出码。五个平台都必须保持同一安装/用户数据目录完成写入和读取两次启动，否则不能证明 跨进程持久化。只有
iOS 允许 harness 在终态后结束应用；其余平台必须自行结束 SceneTree 或 Activity。

## 物理设备边界

模拟器 E2E 可以证明候选 addon 被实际打进 `TestSecureStorage` 并经过公开 API 调用，但不能替代：

- Android arm64 物理设备上的硬件 Keystore、权限和真实文件系统签收；
- iOS 签名物理设备上的 Keychain access group、重启和锁屏 accessibility 签收。

需要把这两类结果设为 Release 强制门禁时，必须提供相应自托管 runner 或设备云；托管 runner 不能凭空提供真实硬件语义。

## CI 不可变候选

CI 顺序固定为：

1. `preflight` 验证结构、精确白名单、脚本、版本与 workflow。
2. 四个模块 job 生成五个平台的 debug/release。
3. `assemble_addon` 在全新目录中显式复制六个 addon 骨架文件与已校验二进制，只生成一次候选 ZIP。
4. 五个 `e2e_*` 下载同一候选，并调用 `test.sh <platform>` 通过对应 adapter 启动 `TestSecureStorage`。
5. `ci_complete` 对失败、取消或跳过 fail closed；Apple job 的成功状态可以来自完整 `PASS`，也可以来自同时通过类型与 message
   断言的预期平台错误。Tag Release 原样发布该候选。

`push` 只对 `main` 与 `v*` tag 执行，分支评审由 `pull_request` 执行，避免同仓库 PR 同时产生 push 与 PR 两套完整任务。
如果变更精确限制在 `README.md`、`LICENSE`、`docs/**`，`preflight` 仍验证仓库契约，平台任务必须全部为 `skipped`，
`ci_complete` 才接受该轻量路径；未知路径、混合变更、tag 和手动触发均执行完整流程。

`build.yml` 保留 job 编排与轻量门禁；四个 `build_*` 和五个 `e2e_*` 可见复杂 stage 分别调用独立 Action。E2E stage Action
调用公共 `.github/scripts/extract-candidate.sh` 统一执行候选文件计数、SHA-256、结构验证和解包，并通过
`SECURE_STORAGE_ADDON_DIR` 把完整候选目录交给 `test.sh`。Godot、godot-cpp、SCons、Linux、Android SDK 与模拟器环境分别由
独立 `.github/scripts/setup-*.sh` 准备；Godot editor、
export templates 与 SCons 按 macOS、Windows、Linux 分别使用明确的平台脚本。跨运行缓存的 restore/save 必须
使用 `actions/cache`，因此直接保留在对应的 `build-*` 或 `e2e-*` Action 中；脚本负责下载、安装以及缓存恢复后的固定版本和
SHA-256 校验。

Godot editor/export templates 只缓存固定 SHA-256 的原始归档且恢复后重新校验；SCons 只缓存内容寻址目录，Gradle 只缓存外部
依赖与 Wrapper，Android 模拟器只缓存测试前生成的干净 snapshot。PR 只能恢复缓存；候选、构建输出、测试 home、keyring、
keystore 与运行后设备状态不进入 cache。缓存命中不能替代候选或上游归档的信任校验。

`assemble_addon` 以固定时间归一化 ZIP 时间戳，并固定路径顺序、权限和压缩参数。`preflight` 运行固定版本且校验下载
SHA-256 的 ShellCheck 与 actionlint，同时检查 workflow、复合 Action metadata 与所有约定 shell 脚本。

E2E 可以编译测试宿主，但不得重新编译任何 SecureStorage 后端。测试工作目录中不得出现 `apple.mm`、`linux.cpp`、
`windows.cpp` 或 `AndroidBackend.kt`。
