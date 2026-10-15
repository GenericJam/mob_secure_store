// mob_secure_store plugin — Android bridge (EncryptedSharedPreferences).
//
// Ported from Operator's OperatorSecureStore.kt (itself from muster_app's
// MusterSecureStore.kt). AndroidX Jetpack Security's EncryptedSharedPreferences
// under a MasterKey held in the Android Keystore (hardware-backed where the
// device has a TEE/StrongBox): keys and values are encrypted at rest and only
// this app can read them.
//
// The generated MobPluginBootstrap.registerAll(activity) runs from
// MainActivity.onCreate before the BEAM starts: it calls register() (the C NIF
// caches this class and its method IDs while the app class loader is on the
// stack) and then setActivity(), which opens the preferences. Keys and values
// cross JNI as byte arrays; keys are UTF-8 (MobSecureStore checks), values any
// bytes, stored Base64-encoded since SharedPreferences holds strings.
package io.mob.securestore

import android.app.Activity
import android.content.Context
import android.content.SharedPreferences
import android.util.Base64
import android.util.Log
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey

object MobSecureStoreBridge : io.mob.plugin.MobActivityAware {
    private const val TAG = "MobSecureStore"
    private const val PREFS_NAME = "mob_secure_store"

    @Volatile
    private var prefs: SharedPreferences? = null

    @JvmStatic external fun nativeRegister()

    @JvmStatic
    fun register() {
        nativeRegister()
    }

    override fun setActivity(activity: Activity) {
        init(activity.applicationContext)
    }

    // Idempotent; safe on every onCreate. A failure (e.g. a Keystore that
    // can't produce the master key) is logged and leaves prefs null, so every
    // bridge call throws and the NIF answers {:error, {:jni, :call_failed}}:
    // the store fails closed rather than pretending the key is absent.
    @JvmStatic
    fun init(context: Context) {
        if (prefs != null) return
        synchronized(this) {
            if (prefs != null) return
            try {
                val masterKey = MasterKey.Builder(context)
                    .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
                    .build()

                prefs = EncryptedSharedPreferences.create(
                    context,
                    PREFS_NAME,
                    masterKey,
                    EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                    EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
                )
            } catch (e: Exception) {
                Log.e(TAG, "can't open the encrypted store", e)
            }
        }
    }

    private fun store(): SharedPreferences =
        prefs ?: throw IllegalStateException("mob_secure_store isn't initialised")

    private fun key(bytes: ByteArray) = String(bytes, Charsets.UTF_8)

    // null when the key is absent.
    @JvmStatic
    fun getBridge(key: ByteArray): ByteArray? =
        logged { store().getString(key(key), null)?.let { Base64.decode(it, Base64.NO_WRAP) } }

    // commit(), not apply(): :ok from the NIF means written, not queued.
    @JvmStatic
    fun putBridge(key: ByteArray, value: ByteArray): Boolean = logged {
        store().edit().putString(key(key), Base64.encodeToString(value, Base64.NO_WRAP)).commit()
    }

    // Removing an absent key commits true.
    @JvmStatic
    fun deleteBridge(key: ByteArray): Boolean = logged { store().edit().remove(key(key)).commit() }

    // Logs and rethrows: the NIF turns the exception into :call_failed.
    private inline fun <T> logged(block: () -> T): T =
        try {
            block()
        } catch (e: Exception) {
            Log.e(TAG, "secure store call failed", e)
            throw e
        }
}
