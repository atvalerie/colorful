package sh.valerie.colorful

import org.json.JSONObject

object NativeCore {
    init { System.loadLibrary("colorful_jni") }

    external fun abiVersion(): Int
    private external fun open(path: ByteArray): ByteArray
    private external fun dispatch(handle: Long, command: ByteArray): ByteArray
    private external fun snapshot(handle: Long): ByteArray
    private external fun mapTidalTracks(document: ByteArray): ByteArray
    external fun close(handle: Long): Boolean

    fun openEngine(path: String): Long =
        response(open(path.encodeToByteArray())).getJSONObject("value").getLong("handle")
    fun dispatchJson(handle: Long, command: JSONObject): JSONObject =
        response(dispatch(handle, command.toString().encodeToByteArray()))
    fun snapshotJson(handle: Long): JSONObject = response(snapshot(handle))
    fun mapTidalTracksJson(document: String): JSONObject =
        response(mapTidalTracks(document.encodeToByteArray()))

    private fun response(bytes: ByteArray): JSONObject {
        val result = JSONObject(bytes.decodeToString())
        check(result.getBoolean("ok")) { result.optString("error", "colorful core failed") }
        return result
    }
}
