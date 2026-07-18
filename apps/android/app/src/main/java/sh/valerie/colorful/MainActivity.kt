package sh.valerie.colorful

import android.content.ComponentName
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.media3.session.MediaController
import androidx.media3.session.SessionToken
import com.google.common.util.concurrent.ListenableFuture
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

private data class SearchTrack(
    val id: String,
    val title: String,
    val artist: String,
    val duration: String,
)

class MainActivity : ComponentActivity() {
    private var engineHandle = 0L
    private var controllerFuture: ListenableFuture<MediaController>? = null
    private val providerExecutor = Executors.newSingleThreadExecutor()
    private val loginGeneration = AtomicInteger(0)
    private val tidal = TidalClient()
    private lateinit var tokenStore: SecureTokenStore

    private var librarySize by mutableIntStateOf(0)
    private var status by mutableStateOf("Opening portable engine…")
    private var tidalLinked by mutableStateOf(false)
    private var tidalCountry by mutableStateOf("US")
    private var loginBusy by mutableStateOf(false)
    private var deviceAuthorization by mutableStateOf<DeviceAuthorization?>(null)
    private var providerMessage by mutableStateOf("")
    private var searchQuery by mutableStateOf("")
    private var searchBusy by mutableStateOf(false)
    private var searchResults by mutableStateOf(emptyList<SearchTrack>())

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        tokenStore = SecureTokenStore(this)
        tidalLinked = tokenStore.readTidalRefreshToken() != null
        tidalCountry = tokenStore.tidalCountryCode()
        runCatching {
            engineHandle = NativeCore.openEngine(getDatabasePath("colorful.sqlite").absolutePath)
            refreshSnapshot()
        }.onFailure { status = it.message ?: "Core startup failed" }
        connectPlaybackSession()
        resumePendingTidalLogin()

        setContent {
            MaterialTheme {
                Column(
                    modifier = Modifier.fillMaxSize().background(Color(0xFF101012))
                        .padding(horizontal = 20.dp, vertical = 22.dp),
                ) {
                    Text("colorful / android", color = Color(0xFFFF5C9A),
                        style = MaterialTheme.typography.labelMedium)
                    Spacer(Modifier.height(6.dp))
                    Text(status, color = Color(0xFFAAAAB2), style = MaterialTheme.typography.bodySmall)
                    Spacer(Modifier.height(18.dp))

                    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        Text(
                            if (tidalLinked) "TIDAL linked · $tidalCountry" else "TIDAL is not linked",
                            color = Color.White,
                            modifier = Modifier.weight(1f),
                        )
                        Button(
                            onClick = if (tidalLinked) ::unlinkTidal else ::startTidalLogin,
                            enabled = !loginBusy,
                            colors = ButtonDefaults.buttonColors(
                                containerColor = Color(0xFFFF5C9A), contentColor = Color.Black,
                            ),
                        ) { Text(if (tidalLinked) "Unlink" else if (loginBusy) "Waiting…" else "Link") }
                    }

                    deviceAuthorization?.let { authorization ->
                        Spacer(Modifier.height(10.dp))
                        Column(
                            Modifier.fillMaxWidth().border(1.dp, Color(0xFF44444B)).padding(12.dp),
                        ) {
                            Text("Enter ${authorization.userCode}", color = Color.White)
                            Text(authorization.verificationUrl, color = Color(0xFFAAAAB2),
                                style = MaterialTheme.typography.bodySmall)
                            Spacer(Modifier.height(8.dp))
                            Button(onClick = { openAuthorization(authorization) }) {
                                Text("Open TIDAL")
                            }
                        }
                    }
                    if (providerMessage.isNotBlank()) {
                        Spacer(Modifier.height(8.dp))
                        Text(providerMessage, color = Color(0xFFFF9BBC),
                            style = MaterialTheme.typography.bodySmall)
                    }

                    Spacer(Modifier.height(20.dp))
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        OutlinedTextField(
                            value = searchQuery,
                            onValueChange = { searchQuery = it },
                            label = { Text("Search TIDAL") },
                            singleLine = true,
                            modifier = Modifier.weight(1f),
                        )
                        Button(
                            onClick = ::searchTidal,
                            enabled = !searchBusy && searchQuery.isNotBlank(),
                        ) { Text(if (searchBusy) "…" else "Search") }
                    }
                    Spacer(Modifier.height(10.dp))
                    LazyColumn(modifier = Modifier.weight(1f)) {
                        items(searchResults, key = { it.id }) { track ->
                            Row(
                                Modifier.fillMaxWidth().border(0.5.dp, Color(0xFF2C2C31))
                                    .padding(horizontal = 10.dp, vertical = 9.dp),
                            ) {
                                Column(Modifier.weight(1f)) {
                                    Text(track.title, color = Color.White,
                                        style = MaterialTheme.typography.bodyMedium)
                                    Text(track.artist, color = Color(0xFF8D8D96),
                                        style = MaterialTheme.typography.bodySmall)
                                }
                                Text(track.duration, color = Color(0xFF8D8D96),
                                    style = MaterialTheme.typography.bodySmall)
                            }
                        }
                    }

                    Spacer(Modifier.height(10.dp))
                    Text("Local library entries  $librarySize", color = Color(0xFF8D8D96),
                        style = MaterialTheme.typography.bodySmall)
                }
            }
        }
    }

    override fun onDestroy() {
        loginGeneration.incrementAndGet()
        providerExecutor.shutdownNow()
        controllerFuture?.let(MediaController::releaseFuture)
        if (engineHandle != 0L) NativeCore.close(engineHandle)
        super.onDestroy()
    }

    private fun connectPlaybackSession() {
        val token = SessionToken(this, ComponentName(this, PlaybackService::class.java))
        val future = MediaController.Builder(this, token).buildAsync()
        controllerFuture = future
        future.addListener(
            {
                runCatching { future.get() }
                    .onSuccess { status = "ABI ${NativeCore.abiVersion()} · SQLite + Media3 session ready" }
                    .onFailure { status = it.message ?: "Media3 session failed" }
            },
            ContextCompat.getMainExecutor(this),
        )
    }

    private fun refreshSnapshot() {
        val value = NativeCore.snapshotJson(engineHandle).getJSONObject("value")
        librarySize = value.getJSONArray("library").length()
        status = "ABI ${NativeCore.abiVersion()} · SQLite opened on this device"
    }

    private fun startTidalLogin() {
        val generation = loginGeneration.incrementAndGet()
        loginBusy = true
        providerMessage = "Starting device authorization…"
        providerExecutor.execute {
            runCatching {
                tokenStore.savePendingTidalAuthorization(tidal.startDeviceAuthorization())
            }
                .onSuccess { pending ->
                    val authorization = pending.authorization
                    runOnUiThread {
                        if (generation != loginGeneration.get()) return@runOnUiThread
                        deviceAuthorization = authorization
                        providerMessage = "Approve this device in TIDAL; colorful is waiting."
                    }
                    pollTidalLogin(generation, authorization, pending.expiresAtMs)
                }
                .onFailure { error -> finishProviderFailure(generation, error) }
        }
    }

    private fun resumePendingTidalLogin() {
        if (tidalLinked) {
            tokenStore.clearPendingTidalAuthorization()
            return
        }
        val pending = tokenStore.pendingTidalAuthorization() ?: return
        val generation = loginGeneration.incrementAndGet()
        loginBusy = true
        deviceAuthorization = pending.authorization
        providerMessage = "Resuming TIDAL authorization…"
        providerExecutor.execute {
            pollTidalLogin(generation, pending.authorization, pending.expiresAtMs)
        }
    }

    private fun pollTidalLogin(
        generation: Int,
        authorization: DeviceAuthorization,
        deadline: Long,
    ) {
        var delayMs = authorization.intervalSeconds * 1000L
        while (generation == loginGeneration.get() && System.currentTimeMillis() < deadline) {
            try {
                Thread.sleep(delayMs)
                when (val result = tidal.pollDeviceAuthorization(authorization)) {
                    is DevicePollResult.Complete -> {
                        val countryCode = tidal.accountCountryCode(result.token.accessToken)
                        tokenStore.saveTidalRefreshToken(result.token.refreshToken)
                        tokenStore.saveTidalCountryCode(countryCode)
                        tokenStore.clearPendingTidalAuthorization()
                        runOnUiThread {
                            if (generation != loginGeneration.get()) return@runOnUiThread
                            tidalLinked = true
                            tidalCountry = countryCode
                            loginBusy = false
                            deviceAuthorization = null
                            providerMessage = "TIDAL linked. The refresh token is protected by Android Keystore."
                        }
                        return
                    }
                    is DevicePollResult.Pending -> if (result.slowDown) delayMs += 5_000L
                }
            } catch (interrupted: InterruptedException) {
                Thread.currentThread().interrupt()
                return
            } catch (error: Throwable) {
                finishProviderFailure(generation, error)
                return
            }
        }
        finishProviderFailure(generation, IllegalStateException("TIDAL device login expired"))
    }

    private fun unlinkTidal() {
        loginGeneration.incrementAndGet()
        tokenStore.clearTidalRefreshToken()
        tokenStore.clearPendingTidalAuthorization()
        tidalLinked = false
        tidalCountry = "US"
        loginBusy = false
        deviceAuthorization = null
        providerMessage = "TIDAL unlinked from this device."
    }

    private fun openAuthorization(authorization: DeviceAuthorization) {
        runCatching { startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(authorization.verificationUrl))) }
            .onFailure { providerMessage = it.message ?: "Could not open the authorization link" }
    }

    private fun searchTidal() {
        val query = searchQuery.trim()
        if (query.isEmpty()) return
        searchBusy = true
        providerMessage = "Searching TIDAL…"
        providerExecutor.execute {
            runCatching {
                val document = tidal.searchTracks(query, tokenStore.tidalCountryCode())
                val tracks = NativeCore.mapTidalTracksJson(document).getJSONArray("value")
                List(tracks.length()) { index -> tracks.getJSONObject(index).toSearchTrack() }
            }.onSuccess { tracks ->
                runOnUiThread {
                    searchResults = tracks
                    searchBusy = false
                    providerMessage = if (tracks.isEmpty()) "No tracks found." else "${tracks.size} tracks"
                }
            }.onFailure { error ->
                runOnUiThread {
                    searchBusy = false
                    providerMessage = error.message ?: "TIDAL search failed"
                }
            }
        }
    }

    private fun finishProviderFailure(generation: Int, error: Throwable) {
        if (generation != loginGeneration.get()) return
        tokenStore.clearPendingTidalAuthorization()
        runOnUiThread {
            if (generation != loginGeneration.get()) return@runOnUiThread
            loginBusy = false
            providerMessage = error.message ?: "TIDAL login failed"
        }
    }

    private fun JSONObject.toSearchTrack(): SearchTrack {
        val artists = optJSONArray("artists") ?: JSONArray()
        val artistNames = List(artists.length()) { index ->
            artists.optJSONObject(index)?.optString("name").orEmpty()
        }.filter { it.isNotBlank() }
        val durationMs = if (isNull("durationMs")) 0L else optLong("durationMs")
        return SearchTrack(
            id = getJSONObject("id").getString("providerId"),
            title = optString("title", "Unknown title"),
            artist = artistNames.joinToString(", ").ifBlank { "Unknown artist" },
            duration = if (durationMs > 0) "%d:%02d".format(durationMs / 60_000, durationMs / 1000 % 60) else "—",
        )
    }
}
