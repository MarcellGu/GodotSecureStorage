# 公开 API

## SecureStorage

`SecureStorage` 是原生 `RefCounted` 入口。

```text
is_available() -> bool
set_value(storage_namespace: String, key: String, value: String) -> SecureStorageResult
get_value(storage_namespace: String, key: String) -> SecureStorageResult
remove_value(storage_namespace: String, key: String) -> SecureStorageResult
clear_namespace(storage_namespace: String) -> SecureStorageResult
```

`storage_namespace` 长度为 1–128 个字符，只允许小写 ASCII 字母、数字、`.`、`-`、`_`。建议使用应用反向域名。`key` 长度为 1–512 个 Godot
字符，不允许 NUL。`value` 的 UTF-8 编码上限为 1 MiB，可为空。

`remove_value()` 删除存在键时成功且 `is_found() == true`；重复删除成功且 `is_found() == false`。`clear_namespace()`
只删除本插件全新格式在该命名空间下的数据。

`create_for_testing()`、`set_available_for_testing()` 和 `corrupt_value_for_testing()` 是契约测试入口，不应在生产游戏逻辑中使用。

## SecureStorageError

枚举成员为：

| 值                   | 含义                              |
|---------------------|---------------------------------|
| `OK`                | 成功                              |
| `INVALID_ARGUMENT`  | 参数未通过统一校验                       |
| `UNAVAILABLE`       | 系统安全存储或包装未提供                    |
| `IO_ERROR`          | 原子文件或持久化 I/O 失败                 |
| `CRYPTO_ERROR`      | 平台加密操作失败                        |
| `CORRUPT_DATA`      | 版本、认证、UTF-8 或载荷结构无效             |
| `PERMISSION_DENIED` | 权限、Keychain 交互或 entitlement 被拒绝 |
| `PLATFORM_ERROR`    | 其他已知平台失败                        |
| `UNKNOWN`           | 无法进一步分类                         |

`SecureStorageError.code_name(code)` 返回稳定枚举名称，适合诊断；不要把秘密值拼入日志。

## SecureStorageResult

```text
is_ok() -> bool
is_found() -> bool
get_value() -> String
get_error() -> SecureStorageError.Code
get_error_message() -> String
```

错误结果的 `get_value()` 没有业务意义。调用方应先检查 `is_ok()`，再检查 `is_found()`。

## StorageService

构建结果中的 `addons/SecureStorage/storage_service.gd` 提供同名、严格类型的 GDScript 包装，方法签名与
`SecureStorage` 一致。对应源码位于 `src/addon/storage_service.gd`。游戏可只依赖此类，平台差异不会泄露到业务代码。
