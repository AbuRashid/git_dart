package org.unimsg.host

import android.app.Activity
import android.app.KeyguardManager
import android.content.Context
import android.content.Intent
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import android.util.Log
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.*
import java.security.spec.*
import java.util.concurrent.Executors
import javax.crypto.*
import javax.crypto.spec.*

// Reusable native capabilities. No vault record, Git or application policy here.
class SecureHost(private val activity: Activity, channel: MethodChannel) : MethodChannel.MethodCallHandler {
    private val worker = Executors.newSingleThreadExecutor()
    private val keys = mutableMapOf<String, Pair<PrivateKey, ByteArray>>()
    private var auth: MethodChannel.Result? = null
    private val alias = activity.packageName + ".custody.v1"
    init { channel.setMethodCallHandler(this) }
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method == "authenticate") {
            if (auth != null) { result.error("busy", "Authentication is already open", null); return }
            val manager = activity.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
            val intent = manager.createConfirmDeviceCredentialIntent("Unlock private storage", "Confirm your device lock")
            if (intent == null) { result.error("device_lock", "Set a device PIN, pattern or password first", null); return }
            auth = result
            activity.startActivityForResult(intent, 7401)
            return
        }
        worker.execute {
            var stage = "native-operation"
            try {
                val a = (call.arguments as? List<*>) ?: emptyList<Any>()
                val value: Any? = when (call.method) {
                    "random" -> ByteArray((a[0] as Number).toInt().also { require(it in 1..65536) }).also { SecureRandom().nextBytes(it) }
                    "create-session-key" -> {
                        val pair = KeyPairGenerator.getInstance("XDH").generateKeyPair()
                        val pub = pair.public.encoded.takeLast(32).toByteArray()
                        val id = identifier(pub); keys[id] = Pair(pair.private, pub)
                        listOf(id, pub)
                    }
                    "create-key" -> {
                        val pair = KeyPairGenerator.getInstance("XDH").generateKeyPair()
                        val pub = pair.public.encoded.takeLast(32).toByteArray()
                        val id = identifier(pub)
                        val encoded = pair.private.encoded
                        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                        cipher.init(Cipher.ENCRYPT_MODE, custody())
                        cipher.updateAAD(alias.toByteArray(Charsets.UTF_8))
                        val protected = try { cipher.iv + cipher.doFinal(encoded) } finally { encoded.fill(0) }
                        keys[id] = Pair(pair.private, pub)
                        listOf(id, pub, protected)
                    }
                    "load-key" -> {
                        stage = "key-metadata"
                        val id = a[0] as String; val pub = a[1] as ByteArray; val protected = a[2] as ByteArray
                        require(pub.size == 32 && identifier(pub) == id && protected.size in 29..4096)
                        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                        stage = "key-unwrapping-init"
                        cipher.init(Cipher.DECRYPT_MODE, custody(), GCMParameterSpec(128, protected.copyOfRange(0, 12)))
                        cipher.updateAAD(alias.toByteArray(Charsets.UTF_8))
                        stage = "key-unwrapping"
                        val encoded = cipher.doFinal(protected.copyOfRange(12, protected.size))
                        stage = "key-import"
                        val key = try { KeyFactory.getInstance("XDH").generatePrivate(PKCS8EncodedKeySpec(encoded)) } finally { encoded.fill(0) }
                        stage = "key-public-verification"
                        // Verify the stored public key belongs to this private key.
                        val base = ByteArray(32); base[0] = 9
                        require(MessageDigest.isEqual(agree(key, base), pub))
                        keys[id] = Pair(key, pub)
                        id
                    }
                    "lock" -> { keys.clear(); null }
                    "crypto" -> primitive(a)
                    "read" -> {
                        val file = file(a[0] as String)
                        if (!file.baseFile.exists() && !File(file.baseFile.path + ".bak").exists()) null else {
                            file.openRead().use { input ->
                                val bytes = input.readNBytes(16 * 1024 * 1024 + 1)
                                require(bytes.size <= 16 * 1024 * 1024); bytes
                            }
                        }
                    }
                    "write" -> {
                        val file = file(a[0] as String); val bytes = a[1] as ByteArray
                        require(bytes.size <= 16 * 1024 * 1024)
                        if (a[2] == true) require(!file.baseFile.exists() && !File(file.baseFile.path + ".bak").exists())
                        val stream = file.startWrite()
                        try { stream.write(bytes); file.finishWrite(stream) } catch (e: Exception) { file.failWrite(stream); throw e }
                        null
                    }
                    else -> throw IllegalArgumentException()
                }
                activity.runOnUiThread { result.success(value) }
            } catch (error: Exception) {
                val category = when(error) {
                    is android.security.keystore.UserNotAuthenticatedException -> "authentication"
                    is AEADBadTagException -> "authentication-tag"
                    is InvalidKeySpecException -> "key-specification"
                    is InvalidKeyException -> "invalid-key"
                    is IllegalArgumentException -> "invalid-value"
                    else -> "native-failure"
                }
                // Static categories only: no exception message, bytes or key identifiers.
                Log.w("UniMSGSecureHost", "$stage/$category")
                activity.runOnUiThread { result.error("secure_host", "Secure operation failed", "$stage/$category") }
            }
        }
    }
    fun activityResult(request: Int, code: Int): Boolean {
        if (request != 7401) return false
        val pending = auth; auth = null
        if (code == Activity.RESULT_OK) pending?.success(true) else pending?.error("cancelled", "Unlock cancelled", null)
        return true
    }
    private fun file(name: String): AtomicFile {
        require(Regex("[a-zA-Z0-9_-]+\\.umsg").matches(name))
        return AtomicFile(File(activity.filesDir, name))
    }
    private fun custody(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(alias, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setKeySize(256).setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setUserAuthenticationRequired(true)
            .setUserAuthenticationParameters(60, KeyProperties.AUTH_DEVICE_CREDENTIAL or KeyProperties.AUTH_BIOMETRIC_STRONG).build())
        return generator.generateKey()
    }
    private fun identifier(public: ByteArray) = "#sha256:" + MessageDigest.getInstance("SHA-256").digest(public).joinToString("") { "%02x".format(it.toInt() and 255) }
    private fun agree(key: PrivateKey, peer: ByteArray): ByteArray {
        require(peer.size == 32)
        val prefix = byteArrayOf(0x30,0x2a,0x30,0x05,0x06,0x03,0x2b,0x65,0x6e,0x03,0x21,0x00)
        val public = KeyFactory.getInstance("XDH").generatePublic(X509EncodedKeySpec(prefix + peer))
        val agreement = KeyAgreement.getInstance("XDH")
        agreement.init(key); agreement.doPhase(public, true)
        return agreement.generateSecret().also { require(it.any { b -> b != 0.toByte() }) }
    }
    private fun primitive(a: List<*>): Any {
        fun b(i: Int) = a[i] as ByteArray
        return when (a[0]) {
            "random-bytes" -> ByteArray((a[1] as Number).toInt().also { require(it in 1..65536) }).also { SecureRandom().nextBytes(it) }
            "x25519-ephemeral" -> {
                val pair = KeyPairGenerator.getInstance("XDH").generateKeyPair()
                listOf(pair.public.encoded.takeLast(32).toByteArray(), agree(pair.private, b(1)))
            }
            "x25519-agree" -> { val key = keys[a[1]] ?: error("locked"); listOf(key.second, agree(key.first,b(2))) }
            "hkdf-sha256" -> {
                val length = (a[4] as Number).toInt(); require(length in 1..8160)
                fun hmac(key: ByteArray, data: ByteArray): ByteArray {
                    val m = Mac.getInstance("HmacSHA256"); m.init(SecretKeySpec(if(key.isEmpty()) ByteArray(32) else key,"HmacSHA256")); return m.doFinal(data)
                }
                val prk = hmac(b(2),b(1)); var previous = ByteArray(0); val out = ByteArray(length); var offset = 0; var counter = 1
                try { while(offset < length) { previous = hmac(prk, previous + b(3) + byteArrayOf(counter.toByte())); val n = minOf(32,length-offset); previous.copyInto(out,offset,0,n); offset += n; counter++ }; out }
                finally { prk.fill(0); previous.fill(0) }
            }
            "aes256gcm-seal", "aes256gcm-open" -> {
                require(b(1).size == 32 && b(2).size == 12)
                val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                cipher.init(if(a[0] == "aes256gcm-seal") Cipher.ENCRYPT_MODE else Cipher.DECRYPT_MODE, SecretKeySpec(b(1),"AES"), GCMParameterSpec(128,b(2)))
                cipher.updateAAD(b(4)); cipher.doFinal(b(3))
            }
            else -> throw IllegalArgumentException()
        }
    }
}
