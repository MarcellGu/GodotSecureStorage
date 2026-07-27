# 公开 API

本文只定义 SecureStorage `1.0.0` 的公开 GDScript API。

## 结果类型

所有存储操作返回 `StorageResult`：

```text
StorageResult
├── StorageSuccess
└── StorageError
```

`StorageResult` 继承 `RefCounted`，自身不包含字段，只作为成功和错误结果的共同基类。

`StorageSuccess` 继承 `StorageResult`，包含：

```text
domain: String
key: String
value: String
```

`StorageError` 继承 `StorageResult`，包含：

```text
type: StorageError.ErrorType
message: String
```

`StorageError.ErrorType` 是错误类型枚举：

- `INVALID_ARGUMENT`：domain、key 或 value 不满足公开约束。
- `NOT_FOUND`：`get_value()` 查询的目标不存在。
- `PLATFORM_ERROR`：平台后端、系统安全存储、权限、I/O、加密或持久化数据失败。
- `UNKNOWN_ERROR`：无法安全归类的异常或后端协议损坏。

错误结果的 `message` 必须为非空字符串。公开契约不暴露内部 ABI 的 `code` 字段；调用方通过
`error.type` 比较 `StorageError.ErrorType`。

## Apple 宿主配置

macOS 与 iOS 宿主必须通过 Godot 项目设置提供完整 Keychain access group：

```ini
[secure_storage]

apple_access_group="ABCDE12345.com.example.game"
```

该值必须与宿主最终签名 entitlement 授权的某一个 access group 完全一致。插件不提供默认组、不拼接作者或项目身份，也不根据
bundle id 猜测宿主的默认组。Apple 后端在实例化时读取一次
`secure_storage/apple_access_group`，随后所有新增、更新、读取、单项删除和 domain 清空都限定到该组。配置缺失或包含 NUL 时返回
`StorageError.ErrorType.PLATFORM_ERROR`，不会退回到匹配宿主全部授权组的 Keychain 查询。

## SecureStorage

```gdscript
var storage: SecureStorage = SecureStorage.new()
var result: SecureStorage.StorageResult = storage.set_value(
		"com.example.game",
		"refresh-token",
		"value"
)

if result is SecureStorage.StorageSuccess:
	var success: SecureStorage.StorageSuccess = result
	# success.value 是平台写入后在同一个受锁操作内重新查询得到的值。
else:
	var error: SecureStorage.StorageError = result
	if error.type == SecureStorage.StorageError.ErrorType.NOT_FOUND:
		print(error.message)
```

公开方法：

```text
set_value(domain: String, key: String, value: String) -> StorageResult
get_value(domain: String, key: String) -> StorageResult
remove_value(domain: String, key: String) -> StorageResult
clear_domain(domain: String) -> StorageResult
```

不存在 `is_available()`。调用方需要探测真实能力时，必须使用独立 domain/key 做一次写入、读取、删除和未找到检查。探针会真实访问
Keychain、Secret Service、Credential Manager、Android Keystore 和对应持久化介质，调用方应自行选择不与业务数据碰撞的
domain/key。

## 操作语义

- `set_value()` 写入后，在同一个受锁操作内重新查询平台存储。只有读回成功时才返回
  `StorageSuccess(domain, key, read_back_value)`；公开包装器还会检查读回值与输入完全相等。
- `get_value()` 返回平台实际查询得到的 `StorageSuccess`；不存在返回 `StorageError`，其 `type` 为
  `StorageError.ErrorType.NOT_FOUND`。空字符串是正常成功值。
- `remove_value()` 发出幂等平台删除请求。已经删除与当时没有可删除匹配都成功，结果为
  `StorageSuccess(domain, key, "")`；返回后不再用第二次查询猜测跨进程最终状态。
- `clear_domain()` 发出幂等平台清理请求。该操作没有单一键值，成功结果为
  `StorageSuccess(domain, "", "")`。

成功结果永远不会直接复制后端尚未确认的写入参数。插件的锁是进程内协调，不是跨进程事务；另一个进程仍可能在操作完成后立即覆盖或
重建同一目标。

## 参数

`domain` 为 1–128 个字符，只允许小写 ASCII 字母、数字、`.`、`-`、`_`。它不得等于 `.` 或 `..`、不得以点结尾，也不得 使用 `con`、
`prn`、`aux`、`nul`、`com1`–`com9`、`lpt1`–`lpt9` 及其带扩展形式。建议使用应用反向域名，以规避不同调用方 之间的存储标识碰撞。

所有平台都把调用方提供的 `domain` 原样传给平台标识或作为插件固定存储根目录下的直接目录名，不添加应用、插件或项目名前缀。
固定的存储根目录只用于组织插件文件，不改变 `domain`。因此调用方必须自行选择全局稳定且不会与同一平台账户下其他调用方碰撞的值。

`key` 为 1–512 个 Unicode 字符，不允许 NUL。`value` 可为空字符串，但不允许 NUL，UTF-8 编码不得超过 2560 字节。该上限对应
Windows Generic Credential 的单条 `CredentialBlob`；每个 `domain/key` 独立占用一条凭据，不是整个 domain 或全部凭据的总量限制。
Linux 的 `domain`、`key` 和凭据标签属于 Secret Service 查询元数据，不按秘密值处理，因此不得在其中放置敏感信息。

## 同步与锁

插件不创建线程。系统安全存储和文件 I/O 的耗时全部计入调用；调用方应从自己的工作线程调用这些同步方法。 尤其是 Linux
libsecret 同步 API 可能无限等待服务或用户提示，不得从 Godot 主线程或其他 UI 线程调用。

- 所有平台后端在每个宿主进程内各使用一把全局锁；全部 domain、key 和操作彼此串行。
- 写入后的读回和值相等检查发生在相应锁释放之前；删除锁只覆盖单次平台删除请求。

## 内部稳定 ABI

公开包装器与原生/Kotlin 后端之间固定使用恰好五个字段的 Dictionary：

```text
code: int
domain: String
key: String
value: String
message: String
```

`code` 只在内部 ABI 使用：`0` 成功、`1` 参数无效、`2` 未找到、`3` 平台错误、`4` 未知错误。成功时
`domain/key/value` 携带后端确认的结果且 `message` 为空；失败时 `domain/key/value` 为空，非空 `message` 会进入公开
`StorageError.message`。后端异常提供非空 `message` 时优先原样返回，调用方可访问平台诊断详情；没有消息时使用分类兜底文本。
错误消息不得包含秘密值。 公开包装器只负责校验并解码这五个字段；`set_value()` 额外检查读回值与输入一致，然后返回
`StorageSuccess` 或携带 `ErrorType` 与消息的 `StorageError`。

## 平台映射

- Windows：`WindowsBackend`，C++，Windows 10 / Windows Server 2016 或更高版本；每个 `domain/key` 直接映射为当前用户
  Credential Manager 中的一条 `CRED_TYPE_GENERIC`。`TargetName` 直接使用 `domain/key`，不加入固定插件命名空间；value 作为
  UTF-8 `CredentialBlob` 交给系统安全存储，不另建密文文件或自管加密密钥。宿主应选择不与自身其他凭据碰撞的 domain。
- Linux：`LinuxBackend`，C++，Secret Service/libsecret；libsecret simple API 形式上要求 `SecretSchema`，后端直接把原样
  `domain` 用作 `schema.name`，只把 `key` 作为字符串查询属性，不引入固定插件 schema 或 domain 前缀。后端直接链接 libsecret
  并调用同步 simple API；删除没有匹配项目时按幂等成功处理。
- Apple：`AppleBackend`，Objective-C++，统一桥接 Security.framework Keychain，并把宿主配置的 access group、 原样 `domain` 和原样
  `key` 分别作为 `kSecAttrAccessGroup`、`kSecAttrService` 与 `kSecAttrAccount`。当前发行流水线打包 macOS 与 iOS；同一桥接所用的
  SecItem、Data Protection Keychain、access group 与 accessibility API 也覆盖 tvOS、 visionOS 和 watchOS。macOS 保持
  `WhenUnlocked`，其他 Apple 设备平台使用 `AfterFirstUnlockThisDeviceOnly`。
- Android：`AndroidBackend`，Kotlin Godot Plugin v2，Android Keystore AES-256-GCM 与 `AtomicFile`。

Android 不加载 C++ 桥或 `.so`；其他四个平台不经过 Android Kotlin 插件。
