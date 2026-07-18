package sh.valerie.colorful

import android.os.Bundle
import androidx.media3.session.SessionCommand

object PlaybackProtocol {
    const val ACTION_PLAY_TRACK = "sh.valerie.colorful.play_track"
    const val ACTION_ENQUEUE_TRACK = "sh.valerie.colorful.enqueue_track"
    const val TRACK_JSON = "track_json"
    const val RESULT_ERROR = "error"

    val playTrack = SessionCommand(ACTION_PLAY_TRACK, Bundle.EMPTY)
    val enqueueTrack = SessionCommand(ACTION_ENQUEUE_TRACK, Bundle.EMPTY)
}
