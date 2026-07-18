package sh.valerie.colorful

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Stores provider refresh credentials encrypted by a non-exportable Android Keystore key. */
class SecureTokenStore(context: Context) {
    private val preferences = context.getSharedPreferences("provider_credentials", Context.MODE_PRIVATE)

    fun hasTidalRefreshToken(): Boolean = preferences.contains(TIDAL_TOKEN)

    fun saveTidalRefreshToken(token: String) {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, key())
        preferences.edit()
            .putString(TIDAL_TOKEN, Base64.encodeToString(cipher.doFinal(token.encodeToByteArray()), Base64.NO_WRAP))
            .putString(TIDAL_IV, Base64.encodeToString(cipher.iv, Base64.NO_WRAP))
            .apply()
    }

    fun readTidalRefreshToken(): String? {
        val encrypted = preferences.getString(TIDAL_TOKEN, null) ?: return null
        val iv = preferences.getString(TIDAL_IV, null) ?: return null
        return runCatching {
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(
                Cipher.DECRYPT_MODE,
                key(),
                GCMParameterSpec(128, Base64.decode(iv, Base64.NO_WRAP)),
            )
            cipher.doFinal(Base64.decode(encrypted, Base64.NO_WRAP)).decodeToString()
        }.getOrNull()
    }

    fun clearTidalRefreshToken() {
        preferences.edit().remove(TIDAL_TOKEN).remove(TIDAL_IV).remove(TIDAL_COUNTRY).apply()
    }

    fun tidalCountryCode(): String = preferences.getString(TIDAL_COUNTRY, null)
        ?.uppercase()
        ?.takeIf { it.matches(Regex("[A-Z]{2}")) }
        ?: DEFAULT_COUNTRY

    fun saveTidalCountryCode(countryCode: String) {
        val normalized = countryCode.trim().uppercase().takeIf { it.matches(Regex("[A-Z]{2}")) }
            ?: DEFAULT_COUNTRY
        preferences.edit().putString(TIDAL_COUNTRY, normalized).apply()
    }

    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").run {
            init(
                KeyGenParameterSpec.Builder(
                    KEY_ALIAS,
                    KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
                ).setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .build(),
            )
            generateKey()
        }
    }

    private companion object {
        const val KEY_ALIAS = "colorful.tidal.refresh.v1"
        const val TIDAL_TOKEN = "tidal_refresh_token"
        const val TIDAL_IV = "tidal_refresh_iv"
        const val TIDAL_COUNTRY = "tidal_country_code"
        const val DEFAULT_COUNTRY = "US"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
    }
}
