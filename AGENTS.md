# 仓库协作约束

## README 读取方式

不要勉强自己读取 `README.md`（如果你不想读）；让你的 harness 读取它，并向你提供完成当前任务所需的内容。

## 根目录与白名单

仓库采用白名单式 `.gitignore`：默认忽略所有路径，只有明确放行的文件可以进入 Git。除 Git 自身元数据外，允许存在的根级入口只有：

- `.gitignore`
- `.github/`
- `AGENTS.md`
- `README.md`
- `docs/`
- `scripts/`
- `src/`
- `tests/`

新增需要提交的文件时，必须同时更新 `.gitignore` 的白名单；不要通过放宽默认忽略规则绕过白名单。

## 源码与生成物

- `src/` 只保存可复现的源码和工程配置。构建中间产物不得写入或提交到 `src/`。
- `tests/` 只保存测试源码和测试场景，不得提交 `.uid`、Godot 缓存、覆盖率数据或编译产物。
- 依赖和中间产物默认写入系统临时目录下的 `secure-storage-build/`；需要改位置时使用 `SECURE_STORAGE_BUILD_ROOT`。
- 可安装的本地构建结果只写入根目录的 `addons/SecureStorage/`，并由 `scripts/clean.sh` 清理。
- 不得加入 C#/.NET 源文件。
- `src/addon/` 与 `tests/` 中不得使用 GDScript `:=` 类型推断。
- 秘密值不得写入日志、测试名称或错误信息。

## 约定入口

- `scripts/` 只允许 `bootstrap.sh`、`build.sh`、`clean.sh`、`test.sh`、`verify.sh`。
- `docs/` 只允许 `api.md`、`testing.md`。
- 修改仓库结构或白名单时，同步更新 `README.md` 的“项目结构”、本文件和 `scripts/verify.sh`。
- 提交前运行 `./scripts/verify.sh`；如果只需执行确定性的契约测试，可运行 `./scripts/test.sh memory`。

## CI 与平台约束

- macOS runner 构建 macOS 与 iOS，Windows runner 构建 Windows，Ubuntu runner 构建 Linux 与 Android。
- 每个平台都必须提供 `template_debug` 和 `template_release` 产物；汇总任务必须检查全部预期文件后再生成 addon ZIP 和
  SHA-256 文件。
- Android 使用 JDK 17、SDK 36、NDK `28.1.13356709`、CMake `3.22.1`。
- iOS/macOS 使用对应 Xcode SDK；Linux 需要 libsecret 开发头文件；Windows 需要 Visual Studio C++ 工具链。
