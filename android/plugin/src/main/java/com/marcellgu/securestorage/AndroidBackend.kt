package com.marcellgu.securestorage

import android.security.keystore.*
import android.util.AtomicFile
import org.godotengine.godot.Dictionary
import org.godotengine.godot.Godot
import org.godotengine.godot.plugin.*
import java.io.*
import java.nio.ByteBuffer
import java.nio.CharBuffer
import java.nio.charset.*
import java.security.*
import java.util.concurrent.locks.ReentrantLock
import javax.crypto.*
import javax.crypto.spec.GCMParameterSpec
import kotlin.concurrent.withLock

/**
 * Godot Android Plugin v2 的同步安全存储后端。
 *
 * 所有存储操作共享一把进程内全局锁；文件使用 AtomicFile，密钥留在
 * AndroidKeyStore，跨边界结果固定为五字段 Dictionary。
 */
class AndroidBackend(godot: Godot) : GodotPlugin(godot) {
    private data class BackendResult(val code: Int, val domain: String, val key: String, val value: String, val message: String)

    companion object {
        private val PROCESS_LOCK = ReentrantLock(true)
        private val MAGIC = byteArrayOf(0x53, 0x53, 0x41, 0x47)
        private val RESERVED_NAMES = setOf("con", "prn", "aux", "nul")
        private const val PLUGIN_NAME = "AndroidBackend"
        private const val STORAGE_DIRECTORY_NAME = "secure_storage"
        private const val VERSION: Byte = 1
        private const val IV_LENGTH = 12
        private const val TAG_BITS = 128
        private const val TAG_LENGTH = TAG_BITS / 8
        private const val MAX_DOMAIN_LENGTH = 128
        private const val MAX_KEY_LENGTH = 512
        private const val MAX_VALUE_BYTES = 5 * 512
        private const val MIN_PAYLOAD_BYTES = 4 + 2 + IV_LENGTH + TAG_LENGTH
        private const val MAX_PAYLOAD_BYTES = MAX_VALUE_BYTES + 4 + 2 + IV_LENGTH + TAG_LENGTH
        private const val OK = 0
        private const val INVALID_ARGUMENT = 1
        private const val NOT_FOUND = 2
        private const val PLATFORM_ERROR = 3
        private const val UNKNOWN_ERROR = 4
    }

    override fun getPluginName(): String = PLUGIN_NAME

    @UsedByGodot fun set_value(domain: String, key: String, value: String): Dictionary =
        _run_dictionary_operation {
            _validate_domain(domain)
            _validate_key(key)
            _validated_value_bytes(value).useWiped { plain ->
                PROCESS_LOCK.withLock {
                    val directory = _ensure_domain_directory(domain)
                    _encrypt(domain, key, plain).useWiped { payload ->
                        _write_atomic(AtomicFile(_value_file(directory, key)), payload)
                        _read_value_locked(domain, key)
                    }
                }
            }
        }

    @UsedByGodot fun get_value(domain: String, key: String): Dictionary =
        _run_dictionary_operation {
            _validate_domain(domain)
            _validate_key(key)
            PROCESS_LOCK.withLock { _read_value_locked(domain, key) }
        }

    @UsedByGodot fun remove_value(domain: String, key: String): Dictionary =
        _run_dictionary_operation {
            _validate_domain(domain)
            _validate_key(key)
            PROCESS_LOCK.withLock {
                val file = _value_file(_domain_directory(domain), key)
                val target = AtomicFile(file)
                if (_recover_and_check_presence(target, file)) _delete_atomic(target, file)
                _success(domain, key, "")
            }
        }

    @UsedByGodot fun clear_domain(domain: String): Dictionary =
        _run_dictionary_operation {
            _validate_domain(domain)
            PROCESS_LOCK.withLock {
                val directory = _domain_directory(domain)
                if (directory.exists()) {
                    if (!directory.isDirectory) throw IOException()
                    _delete_domain_files(directory)
                    if (!directory.delete() && directory.exists()) throw IOException()
                }
                _load_key_store().apply {
                    if (containsAlias(domain)) deleteEntry(domain)
                }
                _success(domain, "", "")
            }
        }

    /** 调用者必须持有 PROCESS_LOCK。 */
    private fun _read_value_locked(domain: String, key: String): BackendResult {
        val file = _value_file(_domain_directory(domain), key)
        val payload = _read_atomic(AtomicFile(file), file, MAX_PAYLOAD_BYTES) ?: return _failure(NOT_FOUND, "Android 安全存储中不存在目标项目。")
        return payload.useWiped { _success(domain, key, _decrypt(domain, key, it)) }
    }

    private fun _encrypt(domain: String, key: String, plain: ByteArray): ByteArray {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, _get_or_create_key(domain))
        val iv = cipher.iv ?: throw GeneralSecurityException()
        return iv.useWiped { safeIv ->
            if (safeIv.size != IV_LENGTH) throw GeneralSecurityException()
            cipher.updateAAD(_associated_data(domain, key))
            cipher.doFinal(plain).useWiped { encrypted ->
                ByteBuffer.allocate(MAGIC.size + 2 + safeIv.size + encrypted.size)
                    .put(MAGIC).put(VERSION).put(safeIv.size.toByte()).put(safeIv).put(encrypted).array()
            }
        }
    }

    private fun _decrypt(domain: String, key: String, payload: ByteArray): String {
        if (payload.size < MIN_PAYLOAD_BYTES || !_has_magic(payload)) throw CorruptPayloadException()
        val buffer = ByteBuffer.wrap(payload)
        buffer.position(MAGIC.size)
        if (buffer.get() != VERSION) throw CorruptPayloadException()
        val ivLength = buffer.get().toInt() and 0xff
        if (ivLength != IV_LENGTH || buffer.remaining() < ivLength + TAG_LENGTH) throw CorruptPayloadException()
        return ByteArray(ivLength).also { buffer.get(it) }.useWiped { iv ->
            ByteArray(buffer.remaining()).also { buffer.get(it) }.useWiped { encrypted ->
                val keyHandle = _get_existing_key(domain) ?: throw CorruptPayloadException()
                val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                cipher.init(Cipher.DECRYPT_MODE, keyHandle, GCMParameterSpec(TAG_BITS, iv))
                cipher.updateAAD(_associated_data(domain, key))
                cipher.doFinal(encrypted).useWiped { _decode_utf8(it) }
            }
        }
    }

    private fun _validate_domain(domain: String) {
        if (domain.isEmpty() || domain.length > MAX_DOMAIN_LENGTH) _invalid()
        if (domain == "." || domain == ".." || domain.endsWith('.')) _invalid()
        if (domain.any { it !in 'a'..'z' && it !in '0'..'9' && it != '.' && it != '-' && it != '_' }) _invalid()
        val baseName = domain.substringBefore('.')
        val reservedPort = baseName.length == 4 && (baseName.startsWith("com") || baseName.startsWith("lpt")) && baseName[3] in '1'..'9'
        if (baseName in RESERVED_NAMES || reservedPort) _invalid()
    }

    private fun _validate_key(key: String) {
        if (key.isEmpty() || key.codePointCount(0, key.length) > MAX_KEY_LENGTH || '\u0000' in key) _invalid()
        _encode_utf8(key, Int.MAX_VALUE)
    }

    private fun _validated_value_bytes(value: String): ByteArray {
        if ('\u0000' in value || value.length > MAX_VALUE_BYTES) _invalid()
        return _encode_utf8(value, MAX_VALUE_BYTES)
    }

    private fun _encode_utf8(value: String, maximum: Int): ByteArray =
        try {
            val encoded = StandardCharsets.UTF_8.newEncoder()
                .onMalformedInput(CodingErrorAction.REPORT).onUnmappableCharacter(CodingErrorAction.REPORT).encode(CharBuffer.wrap(value))
            if (encoded.remaining() > maximum) _invalid()
            ByteArray(encoded.remaining()).also { encoded.get(it) }
        } catch (_: CharacterCodingException) {
            _invalid()
        }

    private fun _decode_utf8(value: ByteArray): String =
        try {
            StandardCharsets.UTF_8.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT).onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(value)).toString()
        } catch (_: CharacterCodingException) {
            throw CorruptPayloadException()
        }

    private fun _storage_root(create: Boolean): File {
        val root = activity?.noBackupFilesDir ?: throw UnavailableStorageException()
        if (!root.isDirectory) throw UnavailableStorageException()
        val storage = File(root, STORAGE_DIRECTORY_NAME)
        if (storage.exists()) {
            if (!storage.isDirectory) throw UnavailableStorageException()
        } else if (create && !storage.mkdirs() && !storage.isDirectory) {
            throw UnavailableStorageException()
        }
        return storage
    }

    private fun _domain_directory(domain: String): File = File(_storage_root(false), domain)

    private fun _ensure_domain_directory(domain: String): File {
        val directory = File(_storage_root(true), domain)
        if (directory.exists()) {
            if (!directory.isDirectory) throw IOException()
        } else if (!directory.mkdirs() && !directory.isDirectory) {
            throw IOException()
        }
        return directory
    }

    private fun _value_file(directory: File, key: String): File = File(directory, "${_sha256(key)}.bin")

    private fun _write_atomic(target: AtomicFile, payload: ByteArray) {
        val stream = target.startWrite()
        try {
            stream.write(payload)
            stream.fd.sync()
            target.finishWrite(stream)
        } catch (exception: Exception) {
            try {
                target.failWrite(stream)
            } catch (cleanupException: Exception) {
                exception.addSuppressed(cleanupException)
            }
            throw exception
        }
    }

    private fun _read_atomic(target: AtomicFile, file: File, maximum: Int): ByteArray? {
        val input = _open_atomic_or_null(target, file) ?: return null
        var allocated: ByteArray? = null
        return try {
            input.use { stream ->
                val size = stream.channel.size()
                if (size < 0 || size > maximum.toLong()) throw CorruptPayloadException()
                val payload = ByteArray(size.toInt())
                allocated = payload
                try {
                    DataInputStream(stream).readFully(payload)
                } catch (_: EOFException) {
                    throw CorruptPayloadException()
                }
                if (stream.read() != -1) throw CorruptPayloadException()
                payload
            }
        } catch (exception: Exception) {
            allocated?.fill(0)
            throw exception
        }
    }

    private fun _open_atomic_or_null(target: AtomicFile, file: File): FileInputStream? =
        try {
            target.openRead()
        } catch (exception: FileNotFoundException) {
            if (_has_atomic_entry(file)) throw exception
            null
        }

    private fun _has_atomic_entry(file: File): Boolean {
        val directory = file.parentFile ?: throw IOException()
        if (!directory.exists()) return false
        if (!directory.isDirectory) throw IOException()
        val names = directory.list()?.toSet() ?: throw IOException()
        return listOf(file.name, "${file.name}.new", "${file.name}.bak").any(names::contains)
    }

    private fun _recover_and_check_presence(target: AtomicFile, file: File): Boolean =
        _open_atomic_or_null(target, file)?.use { true } ?: false

    private fun _delete_atomic(target: AtomicFile, file: File) {
        target.delete()
        if (_recover_and_check_presence(target, file)) throw IOException()
    }

    private fun _delete_domain_files(directory: File) {
        val names = directory.listFiles()?.mapTo(linkedSetOf()) { file ->
            if (file.isDirectory) throw IOException()
            _atomic_base_name(file.name) ?: throw IOException()
        } ?: throw IOException()
        names.forEach { name ->
            File(directory, name).let { _delete_atomic(AtomicFile(it), it) }
        }
        if (directory.list()?.isNotEmpty() != false) throw IOException()
    }

    private fun _atomic_base_name(fileName: String): String? {
        val baseName = when {
            fileName.endsWith(".new") -> fileName.removeSuffix(".new")
            fileName.endsWith(".bak") -> fileName.removeSuffix(".bak")
            else -> fileName
        }
        if (!baseName.endsWith(".bin")) return null
        val digest = baseName.removeSuffix(".bin")
        return baseName.takeIf { digest.length == 64 && digest.all { character -> character in '0'..'9' || character in 'a'..'f' } }
    }

    private fun _has_magic(payload: ByteArray): Boolean = payload.size >= MAGIC.size && MAGIC.indices.all { payload[it] == MAGIC[it] }

    private fun _load_key_store(): KeyStore = try { KeyStore.getInstance("AndroidKeyStore").apply { load(null) } } catch (_: IOException) { throw UnavailableStorageException() }

    private fun _get_existing_key(domain: String): SecretKey? = _load_key_store().getKey(domain, null)?.let { it as? SecretKey ?: throw GeneralSecurityException() }

    private fun _get_or_create_key(domain: String): SecretKey = _get_existing_key(domain) ?: _generate_key(domain)

    private fun _generate_key(domain: String): SecretKey {
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(
            KeyGenParameterSpec.Builder(domain, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setKeySize(256).setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).setRandomizedEncryptionRequired(true).build(),
        )
        return generator.generateKey()
    }

    private fun _associated_data(domain: String, key: String): ByteArray = "$domain\u001f$key".toByteArray(StandardCharsets.UTF_8)

    private fun _sha256(value: String): String = MessageDigest.getInstance("SHA-256").digest(value.toByteArray(StandardCharsets.UTF_8)).joinToString("") { "%02x".format(it) }

    private inline fun _run_dictionary_operation(operation: () -> BackendResult): Dictionary = try { operation().toDictionary() } catch (exception: Exception) { _failure_for(exception).toDictionary() }

    private fun _failure_for(exception: Exception): BackendResult {
        val message = exception.message?.takeIf { it.isNotBlank() }
        return when (exception) {
            is InvalidArgumentStorageException -> _failure(INVALID_ARGUMENT, message ?: "Android 安全存储参数无效。")
            is UnavailableStorageException,
            is CorruptPayloadException,
            is SecurityException,
            is ProviderException,
            is IOException,
            is GeneralSecurityException -> _failure(PLATFORM_ERROR, message ?: "Android 安全存储平台操作失败。")
            else -> _failure(UNKNOWN_ERROR, message ?: "Android 安全存储发生未知错误。")
        }
    }

    private fun _success(domain: String, key: String, value: String): BackendResult =
        BackendResult(OK, domain, key, value, "")

    private fun _failure(code: Int, message: String): BackendResult =
        BackendResult(code, "", "", "", message)

    private fun BackendResult.toDictionary(): Dictionary = Dictionary().apply {
        put("code", code)
        put("domain", domain)
        put("key", key)
        put("value", value)
        put("message", message)
    }

    private inline fun <T> ByteArray.useWiped(operation: (ByteArray) -> T): T = try { operation(this) } finally { fill(0) }

    private fun _invalid(): Nothing = throw InvalidArgumentStorageException()

    private class InvalidArgumentStorageException : Exception()
    private class UnavailableStorageException : Exception()
    private class CorruptPayloadException : Exception()
}
