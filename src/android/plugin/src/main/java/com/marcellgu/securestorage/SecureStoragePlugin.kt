package com.marcellgu.securestorage

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import org.godotengine.godot.Godot
import org.godotengine.godot.plugin.GodotPlugin
import org.godotengine.godot.plugin.UsedByGodot
import java.io.File
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.nio.charset.StandardCharsets
import java.security.KeyStore
import java.security.MessageDigest
import java.security.SecureRandom
import javax.crypto.AEADBadTagException
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

class SecureStoragePlugin(godot: Godot) : GodotPlugin(godot) {
    private data class ErrorState(val code: Int, val message: String)

    private val _last_error = ThreadLocal.withInitial { ErrorState(OK, "") }

    companion object {
        private const val PLUGIN_NAME = "SecureStorageAndroid"
        private val MAGIC = byteArrayOf(0x53, 0x53, 0x41, 0x47)
        private const val VERSION: Byte = 1
        private const val IV_LENGTH = 12
        private const val TAG_BITS = 128

        private const val OK = 0
        private const val IO_ERROR = 3
        private const val CRYPTO_ERROR = 4
        private const val CORRUPT_DATA = 5
        private const val PERMISSION_DENIED = 6
        private const val PLATFORM_ERROR = 7
        private const val UNKNOWN = 8

        init {
            System.loadLibrary("secure_storage")
        }
    }

    override fun getPluginName(): String = PLUGIN_NAME

    override fun getPluginGDExtensionLibrariesPaths(): Set<String> =
        setOf("res://addons/SecureStorage/secure_storage.gdextension")

    @UsedByGodot
    fun is_available(): Boolean = try {
        if (activity == null) {
            false
        } else {
            KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
            true
        }
    } catch (_: Exception) {
        false
    }

    @UsedByGodot
    fun get_last_error_code(): Int = _last_error.get()?.code ?: UNKNOWN

    @UsedByGodot
    fun get_last_error_message(): String = _last_error.get()?.message ?: "Android 安全存储状态不可用。"

    @UsedByGodot
    fun set_value(namespace: String, key: String, value: String): Boolean = _run_operation(false) {
        val plain = value.toByteArray(StandardCharsets.UTF_8)
        try {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            val iv = ByteArray(IV_LENGTH).also { SecureRandom().nextBytes(it) }
            cipher.init(Cipher.ENCRYPT_MODE, _get_or_create_key(namespace), GCMParameterSpec(TAG_BITS, iv))
            cipher.updateAAD(_associated_data(namespace, key))
            val encrypted = cipher.doFinal(plain)
            val payload = ByteBuffer.allocate(MAGIC.size + 2 + iv.size + encrypted.size)
                .put(MAGIC)
                .put(VERSION)
                .put(iv.size.toByte())
                .put(iv)
                .put(encrypted)
                .array()
            val target = AtomicFile(_value_file(namespace, key))
            val stream = target.startWrite()
            try {
                stream.write(payload)
                stream.fd.sync()
                target.finishWrite(stream)
            } catch (exception: Exception) {
                target.failWrite(stream)
                throw exception
            } finally {
                payload.fill(0)
                encrypted.fill(0)
                iv.fill(0)
            }
            true
        } finally {
            plain.fill(0)
        }
    }

    @UsedByGodot
    fun get_value(namespace: String, key: String): String? {
        _reset_error()
        val file = _value_file(namespace, key)
        if (!file.exists()) {
            return null
        }
        return try {
            val payload = AtomicFile(file).openRead().use { input -> input.readBytes() }
            try {
                if (payload.size < MAGIC.size + 2 + IV_LENGTH + 16 || !payload.copyOfRange(0, MAGIC.size).contentEquals(MAGIC)) {
                    throw CorruptPayloadException()
                }
                val buffer = ByteBuffer.wrap(payload)
                buffer.position(MAGIC.size)
                if (buffer.get() != VERSION) {
                    throw CorruptPayloadException()
                }
                val ivLength = buffer.get().toInt() and 0xff
                if (ivLength != IV_LENGTH || buffer.remaining() <= ivLength) {
                    throw CorruptPayloadException()
                }
                val iv = ByteArray(ivLength).also { buffer.get(it) }
                val encrypted = ByteArray(buffer.remaining()).also { buffer.get(it) }
                val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                cipher.init(Cipher.DECRYPT_MODE, _get_or_create_key(namespace), GCMParameterSpec(TAG_BITS, iv))
                cipher.updateAAD(_associated_data(namespace, key))
                val plain = cipher.doFinal(encrypted)
                try {
                    StandardCharsets.UTF_8.newDecoder()
                        .onMalformedInput(CodingErrorAction.REPORT)
                        .onUnmappableCharacter(CodingErrorAction.REPORT)
                        .decode(ByteBuffer.wrap(plain))
                        .toString()
                } finally {
                    plain.fill(0)
                    encrypted.fill(0)
                    iv.fill(0)
                }
            } finally {
                payload.fill(0)
            }
        } catch (_: AEADBadTagException) {
            _set_error(CORRUPT_DATA, "Android 密文认证失败。")
            null
        } catch (_: CorruptPayloadException) {
            _set_error(CORRUPT_DATA, "Android 密文格式无效。")
            null
        } catch (_: IOException) {
            _set_error(IO_ERROR, "Android 安全存储读取失败。")
            null
        } catch (_: SecurityException) {
            _set_error(PERMISSION_DENIED, "Android Keystore 拒绝访问。")
            null
        } catch (_: Exception) {
            _set_error(CRYPTO_ERROR, "Android 安全存储解密失败。")
            null
        }
    }

    @UsedByGodot
    fun remove_value(namespace: String, key: String): Boolean = _run_operation(false) {
        val file = _value_file(namespace, key)
        val existed = file.exists()
        if (existed && !file.delete()) {
            throw IOException()
        }
        existed
    }

    @UsedByGodot
    fun clear_namespace(namespace: String): Boolean = _run_operation(false) {
        val directory = _namespace_directory(namespace)
        if (directory.exists() && !directory.deleteRecursively()) {
            throw IOException()
        }
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val alias = namespace
        if (keyStore.containsAlias(alias)) {
            keyStore.deleteEntry(alias)
        }
        true
    }

    private fun _get_or_create_key(namespace: String): SecretKey {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val alias = namespace
        (keyStore.getKey(alias, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(
            KeyGenParameterSpec.Builder(
                alias,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
            )
                .setKeySize(256)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setRandomizedEncryptionRequired(true)
                .build()
        )
        return generator.generateKey()
    }

    private fun _value_file(namespace: String, key: String): File =
        File(_namespace_directory(namespace), "${_sha256(key)}.bin").also { it.parentFile?.mkdirs() }

    private fun _namespace_directory(namespace: String): File {
        val current_activity = activity ?: throw IllegalStateException("Godot Activity 不可用。")
        return File(current_activity.noBackupFilesDir, "secure_storage/$namespace")
    }

    private fun _associated_data(namespace: String, key: String): ByteArray =
        "$namespace\u001f$key".toByteArray(StandardCharsets.UTF_8)

    private fun _sha256(value: String): String = MessageDigest.getInstance("SHA-256")
        .digest(value.toByteArray(StandardCharsets.UTF_8))
        .joinToString("") { byte -> "%02x".format(byte) }

    private fun _reset_error() {
        _last_error.set(ErrorState(OK, ""))
    }

    private fun _set_error(code: Int, message: String) {
        _last_error.set(ErrorState(code, message))
    }

    private inline fun _run_operation(default_value: Boolean, operation: () -> Boolean): Boolean {
        _reset_error()
        return try {
            operation()
        } catch (_: IOException) {
            _set_error(IO_ERROR, "Android 安全存储 I/O 失败。")
            default_value
        } catch (_: SecurityException) {
            _set_error(PERMISSION_DENIED, "Android Keystore 拒绝访问。")
            default_value
        } catch (_: java.security.GeneralSecurityException) {
            _set_error(CRYPTO_ERROR, "Android 加密操作失败。")
            default_value
        } catch (_: Exception) {
            _set_error(PLATFORM_ERROR, "Android 安全存储平台操作失败。")
            default_value
        }
    }

    private class CorruptPayloadException : Exception()
}
