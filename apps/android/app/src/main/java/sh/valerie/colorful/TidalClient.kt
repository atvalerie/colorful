package sh.valerie.colorful

import android.net.Uri
import android.util.Base64
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.UnknownHostException
import java.net.URL
import java.net.URLEncoder

data class DeviceAuthorization(
    val deviceCode: String,
    val userCode: String,
    val verificationUrl: String,
    val expiresInSeconds: Long,
    val intervalSeconds: Long,
)

data class TidalUserToken(val accessToken: String, val refreshToken: String)

sealed interface DevicePollResult {
    data class Complete(val token: TidalUserToken) : DevicePollResult
    data class Pending(val slowDown: Boolean) : DevicePollResult
}

class TidalClient {
    fun startDeviceAuthorization(): DeviceAuthorization {
        requireDeviceConfiguration()
        val response = request(
            "https://auth.tidal.com/v1/oauth2/device_authorization",
            "POST",
            form = mapOf(
                "client_id" to BuildConfig.TIDAL_DEVICE_CLIENT_ID,
                "scope" to "r_usr+w_usr+w_sub",
            ),
        )
        response.requireSuccess("TIDAL device login failed to start")
        val value = JSONObject(response.body)
        val verification = value.string("verificationUriComplete")
            .ifBlank { value.string("verificationUri") }
        return DeviceAuthorization(
            deviceCode = value.string("deviceCode"),
            userCode = value.string("userCode"),
            verificationUrl = normalizeHttpsUrl(verification),
            expiresInSeconds = value.long("expiresIn", 300L),
            intervalSeconds = value.long("interval", 5L).coerceAtLeast(1L),
        ).also {
            check(it.deviceCode.isNotBlank() && it.verificationUrl.isNotBlank()) {
                "TIDAL returned an incomplete device authorization"
            }
        }
    }

    fun pollDeviceAuthorization(start: DeviceAuthorization): DevicePollResult {
        val response = request(
            "https://auth.tidal.com/v1/oauth2/token",
            "POST",
            authorization = basic(BuildConfig.TIDAL_DEVICE_CLIENT_ID, BuildConfig.TIDAL_DEVICE_CLIENT_SECRET),
            form = mapOf(
                "client_id" to BuildConfig.TIDAL_DEVICE_CLIENT_ID,
                "scope" to "r_usr+w_usr+w_sub",
                "device_code" to start.deviceCode,
                "grant_type" to "urn:ietf:params:oauth:grant-type:device_code",
            ),
        )
        val value = runCatching { JSONObject(response.body) }.getOrDefault(JSONObject())
        if (response.code in 200..299) {
            val refreshToken = value.string("refresh_token")
            check(refreshToken.isNotBlank()) { "TIDAL login returned no refresh token" }
            return DevicePollResult.Complete(
                TidalUserToken(value.string("access_token"), refreshToken),
            )
        }
        return when (val error = value.string("error")) {
            "authorization_pending" -> DevicePollResult.Pending(false)
            "slow_down" -> DevicePollResult.Pending(true)
            else -> error("TIDAL device login failed: ${error.ifBlank { "HTTP ${response.code}" }}")
        }
    }

    /** Returns the raw JSON:API document; colorful-core owns normalization. */
    fun accountCountryCode(accessToken: String): String {
        return runCatching {
            val response = request(
                "https://login.tidal.com/oauth2/me",
                "GET",
                authorization = "Bearer $accessToken",
            )
            if (response.code !in 200..299) return@runCatching DEFAULT_COUNTRY
            JSONObject(response.body).string("countryCode").trim().uppercase()
        }.getOrDefault(DEFAULT_COUNTRY)
            .takeIf { it.matches(Regex("[A-Z]{2}")) }
            ?: DEFAULT_COUNTRY
    }

    fun searchTracks(query: String, countryCode: String, limit: Int = 30): String {
        requireBrowseConfiguration()
        val tokenResponse = request(
            "https://auth.tidal.com/v1/oauth2/token",
            "POST",
            authorization = basic(BuildConfig.TIDAL_BROWSE_CLIENT_ID, BuildConfig.TIDAL_BROWSE_CLIENT_SECRET),
            form = mapOf("grant_type" to "client_credentials", "scope" to "r_usr w_usr w_sub"),
        )
        tokenResponse.requireSuccess("TIDAL catalog authorization failed")
        val accessToken = JSONObject(tokenResponse.body).string("access_token")
        check(accessToken.isNotBlank()) { "TIDAL returned no catalog token" }

        val pathQuery = Uri.encode(query.trim())
        val url = Uri.parse("https://openapi.tidal.com/v2/searchResults/$pathQuery/relationships/tracks")
            .buildUpon()
            .appendQueryParameter("countryCode", normalizedCountry(countryCode))
            .appendQueryParameter("include", "tracks.albums,tracks.artists,tracks.albums.coverArt")
            .appendQueryParameter("page[limit]", limit.coerceIn(1, 50).toString())
            .build().toString()
        val response = request(url, "GET", authorization = "Bearer $accessToken")
        response.requireSuccess("TIDAL search failed")
        return response.body
    }

    private fun request(
        url: String,
        method: String,
        authorization: String? = null,
        form: Map<String, String>? = null,
    ): HttpResponse {
        repeat(3) { attempt ->
            try {
                return requestOnce(url, method, authorization, form)
            } catch (error: UnknownHostException) {
                if (attempt == 2) {
                    throw IllegalStateException(
                        "Android cannot resolve ${URL(url).host}; check the active network or Private DNS",
                        error,
                    )
                }
                Thread.sleep(500L * (attempt + 1))
            }
        }
        error("unreachable")
    }

    private fun requestOnce(
        url: String,
        method: String,
        authorization: String?,
        form: Map<String, String>?,
    ): HttpResponse {
        val connection = URL(url).openConnection() as HttpURLConnection
        return try {
            connection.requestMethod = method
            connection.connectTimeout = 15_000
            connection.readTimeout = 20_000
            connection.setRequestProperty("Accept", "application/json")
            connection.setRequestProperty("User-Agent", "colorful/0.1 (Android)")
            authorization?.let { connection.setRequestProperty("Authorization", it) }
            if (form != null) {
                val body = form.entries.joinToString("&") { (key, value) ->
                    "${key.formEncode()}=${value.formEncode()}"
                }.encodeToByteArray()
                connection.doOutput = true
                connection.setRequestProperty("Content-Type", "application/x-www-form-urlencoded")
                connection.setFixedLengthStreamingMode(body.size)
                connection.outputStream.use { it.write(body) }
            }
            val code = connection.responseCode
            val stream = if (code in 200..299) connection.inputStream else connection.errorStream
            HttpResponse(code, stream?.bufferedReader()?.use { it.readText() }.orEmpty())
        } finally {
            connection.disconnect()
        }
    }

    private fun requireDeviceConfiguration() = check(
        BuildConfig.TIDAL_DEVICE_CLIENT_ID.isNotBlank() && BuildConfig.TIDAL_DEVICE_CLIENT_SECRET.isNotBlank(),
    ) { "TIDAL device credentials were not available when this APK was built" }

    private fun requireBrowseConfiguration() = check(
        BuildConfig.TIDAL_BROWSE_CLIENT_ID.isNotBlank() && BuildConfig.TIDAL_BROWSE_CLIENT_SECRET.isNotBlank(),
    ) { "TIDAL catalog credentials were not available when this APK was built" }

    private data class HttpResponse(val code: Int, val body: String) {
        fun requireSuccess(message: String) {
            check(code in 200..299) { "$message (HTTP $code)" }
        }
    }

    private fun JSONObject.string(key: String): String = optString(key, "")
    private fun JSONObject.long(key: String, fallback: Long): Long = optLong(key, fallback)
    private fun String.formEncode(): String = URLEncoder.encode(this, Charsets.UTF_8.name())
    private fun basic(id: String, secret: String): String = "Basic " + Base64.encodeToString(
        "$id:$secret".encodeToByteArray(), Base64.NO_WRAP,
    )
    private fun normalizeHttpsUrl(value: String): String = when {
        value.startsWith("https://", true) -> value
        value.startsWith("http://", true) -> "https://${value.substringAfter("://")}" 
        else -> "https://${value.trimStart('/')}"
    }

    private fun normalizedCountry(value: String): String = value.trim().uppercase()
        .takeIf { it.matches(Regex("[A-Z]{2}")) }
        ?: DEFAULT_COUNTRY

    private companion object {
        const val DEFAULT_COUNTRY = "US"
    }
}
