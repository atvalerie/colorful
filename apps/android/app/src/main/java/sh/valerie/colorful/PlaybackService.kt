package sh.valerie.colorful

import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.MimeTypes
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import androidx.media3.session.SessionCommand
import androidx.media3.session.SessionError
import androidx.media3.session.SessionResult
import com.google.common.util.concurrent.ListenableFuture
import com.google.common.util.concurrent.SettableFuture
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.Executors

@androidx.annotation.OptIn(markerClass = [UnstableApi::class])
class PlaybackService : MediaSessionService() {
    private val providerExecutor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())
    private val tidal = TidalClient()
    private lateinit var tokenStore: SecureTokenStore
    private var cachedToken: TidalUserToken? = null
    private var engineHandle = 0L
    private var mediaSession: MediaSession? = null
    private var lastMediaIndex = C.INDEX_UNSET

    private val checkpoint = object : Runnable {
        override fun run() {
            val player = mediaSession?.player ?: return
            if (player.currentMediaItem != null) {
                dispatchCore("checkpoint_position", "positionMs" to player.currentPosition.coerceAtLeast(0L))
            }
            mainHandler.postDelayed(this, 15_000L)
        }
    }

    override fun onCreate() {
        super.onCreate()
        tokenStore = SecureTokenStore(this)
        engineHandle = NativeCore.openEngine(getDatabasePath("colorful.sqlite").absolutePath)
        val audioAttributes = AudioAttributes.Builder()
            .setUsage(C.USAGE_MEDIA)
            .setContentType(C.AUDIO_CONTENT_TYPE_MUSIC)
            .build()
        val player = ExoPlayer.Builder(this)
            .setAudioAttributes(audioAttributes, true)
            .setHandleAudioBecomingNoisy(true)
            .build()
        player.addListener(object : Player.Listener {
            override fun onIsPlayingChanged(isPlaying: Boolean) {
                if (player.currentMediaItem != null) dispatchCore(if (isPlaying) "play" else "pause")
            }

            override fun onMediaItemTransition(mediaItem: MediaItem?, reason: Int) {
                val index = player.currentMediaItemIndex
                if (lastMediaIndex != C.INDEX_UNSET && index != C.INDEX_UNSET && index != lastMediaIndex) {
                    dispatchCore(if (index > lastMediaIndex) "skip_next" else "skip_previous")
                }
                lastMediaIndex = index
            }

            override fun onPositionDiscontinuity(
                oldPosition: Player.PositionInfo,
                newPosition: Player.PositionInfo,
                reason: Int,
            ) {
                if (player.currentMediaItem != null) {
                    dispatchCore("checkpoint_position", "positionMs" to newPosition.positionMs.coerceAtLeast(0L))
                }
            }
        })
        mediaSession = MediaSession.Builder(this, player)
            .setCallback(SessionCallback())
            .build()
        mainHandler.post(checkpoint)
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? = mediaSession

    override fun onDestroy() {
        mainHandler.removeCallbacks(checkpoint)
        mediaSession?.run {
            if (player.currentMediaItem != null) {
                dispatchCore("checkpoint_position", "positionMs" to player.currentPosition.coerceAtLeast(0L))
            }
            player.release()
            release()
        }
        mediaSession = null
        providerExecutor.shutdownNow()
        if (engineHandle != 0L) NativeCore.close(engineHandle)
        engineHandle = 0L
        super.onDestroy()
    }

    private inner class SessionCallback : MediaSession.Callback {
        override fun onConnect(
            session: MediaSession,
            controller: MediaSession.ControllerInfo,
        ): MediaSession.ConnectionResult {
            val commands = MediaSession.ConnectionResult.DEFAULT_SESSION_COMMANDS.buildUpon()
                .add(PlaybackProtocol.playTrack)
                .add(PlaybackProtocol.enqueueTrack)
                .build()
            return MediaSession.ConnectionResult.AcceptedResultBuilder(session)
                .setAvailableSessionCommands(commands)
                .build()
        }

        override fun onCustomCommand(
            session: MediaSession,
            controller: MediaSession.ControllerInfo,
            customCommand: SessionCommand,
            args: Bundle,
        ): ListenableFuture<SessionResult> {
            val enqueue = when (customCommand.customAction) {
                PlaybackProtocol.ACTION_PLAY_TRACK -> false
                PlaybackProtocol.ACTION_ENQUEUE_TRACK -> true
                else -> return super.onCustomCommand(session, controller, customCommand, args)
            }
            val future = SettableFuture.create<SessionResult>()
            val trackJson = args.getString(PlaybackProtocol.TRACK_JSON).orEmpty()
            providerExecutor.execute {
                runCatching { prepareTrack(trackJson) }
                    .onSuccess { prepared ->
                        mainHandler.post {
                            if (enqueue) {
                                dispatchTrack("enqueue", prepared.track)
                                session.player.addMediaItem(prepared.mediaItem)
                            } else {
                                dispatchTrack("play_tracks", prepared.track)
                                lastMediaIndex = C.INDEX_UNSET
                                session.player.setMediaItem(prepared.mediaItem)
                                session.player.prepare()
                                session.player.play()
                            }
                            future.set(SessionResult(SessionResult.RESULT_SUCCESS))
                        }
                    }
                    .onFailure { error ->
                        val extras = Bundle().apply {
                            putString(PlaybackProtocol.RESULT_ERROR, error.message ?: "Playback failed")
                        }
                        future.set(SessionResult(SessionError.ERROR_UNKNOWN, extras))
                    }
            }
            return future
        }
    }

    private data class PreparedTrack(val track: JSONObject, val mediaItem: MediaItem)

    private fun prepareTrack(trackJson: String): PreparedTrack {
        val track = JSONObject(trackJson)
        val id = track.getJSONObject("id").getString("providerId")
        var source = tidal.playbackSource(id, accessToken(false).accessToken)
        if (source.presentation == "PREVIEW" && source.previewReason == "FULL_REQUIRES_SUBSCRIPTION") {
            source = tidal.playbackSource(id, accessToken(true).accessToken)
        }
        if (source.presentation == "PREVIEW") {
            error("TIDAL only returned a preview (${source.previewReason ?: "unknown reason"})")
        }
        val artists = track.optJSONArray("artists") ?: JSONArray()
        val artist = List(artists.length()) { index ->
            artists.optJSONObject(index)?.optString("name").orEmpty()
        }.filter(String::isNotBlank).joinToString(", ")
        val artwork = track.optJSONObject("artwork")?.optString("url")?.takeIf(String::isNotBlank)
        val metadata = MediaMetadata.Builder()
            .setTitle(track.optString("title", "Unknown title"))
            .setArtist(artist.ifBlank { "Unknown artist" })
            .setAlbumTitle(track.optString("albumTitle").takeIf(String::isNotBlank))
            .apply { artwork?.let { setArtworkUri(Uri.parse(it)) } }
            .build()
        val mimeType = if (source.manifestType == "MPEG_DASH") {
            MimeTypes.APPLICATION_MPD
        } else {
            MimeTypes.APPLICATION_M3U8
        }
        val mediaItem = MediaItem.Builder()
            .setMediaId("tidal:$id")
            .setUri(source.uri)
            .setMimeType(mimeType)
            .setMediaMetadata(metadata)
            .build()
        return PreparedTrack(track, mediaItem)
    }

    private fun accessToken(force: Boolean): TidalUserToken {
        val cached = cachedToken
        if (!force && cached != null && System.currentTimeMillis() < cached.expiresAtMs - 30_000L) {
            return cached
        }
        val refreshToken = tokenStore.readTidalRefreshToken()
            ?: error("Connect TIDAL before playing music")
        val refreshed = tidal.refreshUserToken(refreshToken)
        tokenStore.saveTidalRefreshToken(refreshed.refreshToken)
        runCatching { tidal.accountInfo(refreshed.accessToken) }.onSuccess {
            tokenStore.saveTidalCountryCode(it.countryCode)
        }
        cachedToken = refreshed
        return refreshed
    }

    private fun dispatchTrack(command: String, track: JSONObject) {
        val payload = JSONObject().put("command", command)
        if (command == "play_tracks") payload.put("tracks", JSONArray().put(track))
        else payload.put("track", track)
        NativeCore.dispatchJson(engineHandle, payload)
    }

    private fun dispatchCore(command: String, vararg values: Pair<String, Any>) {
        if (engineHandle == 0L) return
        runCatching {
            val payload = JSONObject().put("command", command)
            values.forEach { (key, value) -> payload.put(key, value) }
            NativeCore.dispatchJson(engineHandle, payload)
        }
    }
}
