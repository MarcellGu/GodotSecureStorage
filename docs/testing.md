# 测试

测试统一放在 `tests/`，不允许把 `.uid`、Godot 缓存、覆盖率数据或编译产物提交到该目录。测试项目和 addon 会在系统临时构建目录中组装。

## 执行

```sh
./scripts/test.sh memory
./scripts/test.sh real
./scripts/verify.sh
```

`memory` 运行确定性的内存后端契约，覆盖普通值、空值、不存在、覆盖、删除幂等性、命名空间隔离、全部参数边界、损坏载荷、后端不可用和统一错误映射。
`real` 在此基础上运行当前桌面系统安全存储，且只操作 `com.marcellgu.securestorage.integration_test` 与
`com.marcellgu.securestorage.integration_other` 两个测试命名空间。测试入口还会检查输出中存在带当前系统名称的真实后端 suite，防止
`--real` 参数未生效时把内存测试误判为平台测试。真实套件会在契约完成后销毁并重新创建平台后端，覆盖动态库和系统服务的生命周期安全性。

CI 在 macOS、Windows、Linux runner 上都执行 `real`。Windows 直接验证当前 runner 用户的 DPAPI 加密、落盘、解密与清理；Linux
先单独构建 debug 测试项目并保存阶段缓存，再在独立 D-Bus session 中用随机密码解锁仅存在于临时 runner 的 GNOME Keyring。通过
`secret-tool` 完成写入/读取探针后，测试复用预编译项目，并只对 Godot 与 Secret Service 的真实契约设置 10 分钟上限。探针或真实
后端不可用都会让 job 失败，不会回退到内存后端；编译与测试分步输出也能区分冷编译耗时和平台调用超时。Apple、Windows、Linux runner
分别恢复和保存独立缓存，任一平台的缓存命中或失败不会影响其他平台。稳定的 `deps/` 与带原生源码内容 hash 的 `obj/`、`sconsign/` 分开存储；
源码变化时对象缓存通过 restore key 继承上一版，只重编变化文件并保存新快照，而不会复制整份依赖缓存。`work/` 测试工程仍会在每次构建时重新
组装，避免缓存运行期状态。

`verify.sh` 还会检查顶层仅有五个白名单目录、脚本恰好五个、文档恰好两个、源码与测试中没有生成物、没有 C#/.NET 文件。测试脚本会在全新的临时
Godot 项目中写入确定性的 GDExtension 登记表，再直接通过 Godot headless 完成解析和测试，不依赖或生成编辑器导入缓存。

## 100% 路径覆盖目标

“100%”按每一条可达控制流路径至少被执行一次理解，而不只按源码行数统计。公共校验和内存后端由所有桌面 job 执行；系统后端必须在相应平台单独执行：

- macOS：真实 Keychain 契约和拒绝/不可用状态。
- iOS：签名真机上的 Keychain 契约、锁屏与重启场景。
- Windows：DPAPI 成功、文件 I/O 失败、损坏密文和权限失败。
- Linux：Secret Service 可用、无会话、动态库缺失和服务错误。
- Android：真机/模拟器上的 Keystore、认证失败、格式损坏、I/O 与权限错误。

只有所有平台的 debug/release job 都报告覆盖率 100%，且没有因平台不可用而跳过的路径，CI
才能宣称达到该目标。当前脚本会对漏测或失败返回非零退出码；平台故障注入与覆盖率采集应由对应 CI runner
配置，不能用内存后端结果冒充系统后端覆盖率。

真实后端测试运行前后都会清理专用 namespace。日志不得打印传入值；测试使用 `sample-secret-never-log` 作为泄漏哨兵，脚本一旦在输出中发现它就失败。
