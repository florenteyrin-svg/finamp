package com.unicornsonlsd.finamp.widgets

import android.content.Context
import android.os.Process

/** What the widgets show. Sent by the Dart side (lib/services/home_screen_widgets.dart). */
data class NowPlayingState(
    val title: String? = null,
    val artist: String? = null,
    val album: String? = null,
    val artPath: String? = null,
    val nextTitle: String? = null,
    val nextArtist: String? = null,
    val playing: Boolean = false,
) {
    companion object {
        fun fromMap(map: Map<*, *>?): NowPlayingState = NowPlayingState(
            title = map?.get("title") as? String,
            artist = map?.get("artist") as? String,
            album = map?.get("album") as? String,
            artPath = map?.get("artPath") as? String,
            nextTitle = map?.get("nextTitle") as? String,
            nextArtist = map?.get("nextArtist") as? String,
            playing = map?.get("playing") as? Boolean ?: false,
        )
    }
}

/** Keeps the last state so the widgets can redraw after a reboot or a launcher restart. */
object NowPlayingStore {
    private const val PREFS = "finamp_home_screen_widgets"

    fun save(context: Context, state: NowPlayingState) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putString("title", state.title)
            .putString("artist", state.artist)
            .putString("album", state.album)
            .putString("artPath", state.artPath)
            .putString("nextTitle", state.nextTitle)
            .putString("nextArtist", state.nextArtist)
            .putBoolean("playing", state.playing)
            .putInt("pid", Process.myPid())
            .apply()
    }

    fun load(context: Context): NowPlayingState {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        return NowPlayingState(
            title = prefs.getString("title", null),
            artist = prefs.getString("artist", null),
            album = prefs.getString("album", null),
            artPath = prefs.getString("artPath", null),
            nextTitle = prefs.getString("nextTitle", null),
            nextArtist = prefs.getString("nextArtist", null),
            // Saved by another process: the app was closed or the phone restarted since, so nothing is playing.
            playing = prefs.getBoolean("playing", false) && prefs.getInt("pid", -1) == Process.myPid(),
        )
    }
}
