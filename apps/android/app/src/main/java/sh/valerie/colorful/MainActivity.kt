package sh.valerie.colorful

import android.content.ComponentName
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.MaterialTheme
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

class MainActivity : ComponentActivity() {
    private var engineHandle = 0L
    private var controllerFuture: ListenableFuture<MediaController>? = null
    private var librarySize by mutableIntStateOf(0)
    private var status by mutableStateOf("Opening portable engine…")

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        runCatching {
            engineHandle = NativeCore.openEngine(getDatabasePath("colorful.sqlite").absolutePath)
            refreshSnapshot()
        }.onFailure { status = it.message ?: "Core startup failed" }
        connectPlaybackSession()

        setContent {
            MaterialTheme {
                Column(
                    modifier = Modifier.fillMaxSize().background(Color(0xFF101012))
                        .padding(horizontal = 22.dp, vertical = 28.dp),
                    verticalArrangement = Arrangement.Center,
                ) {
                    Text("COLORFUL / ANDROID", color = Color(0xFFFF5C9A),
                        style = MaterialTheme.typography.labelMedium)
                    Spacer(Modifier.height(10.dp))
                    Text("The portable core is alive.", color = Color.White,
                        style = MaterialTheme.typography.headlineMedium)
                    Spacer(Modifier.height(8.dp))
                    Text(status, color = Color(0xFFAAAAB2))
                    Spacer(Modifier.height(24.dp))
                    Text("Persisted library entries  $librarySize", color = Color.White)
                    Spacer(Modifier.height(18.dp))
                    Button(
                        onClick = ::writePersistenceMarker,
                        modifier = Modifier.fillMaxWidth().border(1.dp, Color(0xFFFF5C9A)),
                        colors = ButtonDefaults.buttonColors(
                            containerColor = Color(0xFFFF5C9A), contentColor = Color.Black),
                    ) { Text("Write persistence marker") }
                }
            }
        }
    }

    override fun onDestroy() {
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
                    .onSuccess {
                        status = "ABI ${NativeCore.abiVersion()} · SQLite + Media3 session ready"
                    }
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

    private fun writePersistenceMarker() {
        runCatching {
            val track = JSONObject()
                .put("id", JSONObject().put("provider", "local")
                    .put("providerId", "android-jni-marker"))
                .put("title", "Android persistence marker")
                .put("version", JSONObject.NULL)
                .put("artists", JSONArray())
                .put("albumId", JSONObject.NULL)
                .put("albumTitle", JSONObject.NULL)
                .put("artwork", JSONObject.NULL)
                .put("durationMs", JSONObject.NULL)
                .put("isrc", JSONObject.NULL)
                .put("explicit", JSONObject.NULL)
            NativeCore.dispatchJson(
                engineHandle,
                JSONObject().put("command", "add_to_library").put("track", track),
            )
            refreshSnapshot()
            status = "Marker saved. Force-close and reopen to verify it."
        }.onFailure { status = it.message ?: "Marker write failed" }
    }
}
