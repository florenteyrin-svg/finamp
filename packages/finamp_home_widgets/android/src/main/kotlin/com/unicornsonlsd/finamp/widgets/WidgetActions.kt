package com.unicornsonlsd.finamp.widgets

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.support.v4.media.MediaBrowserCompat
import android.support.v4.media.session.MediaControllerCompat
import android.util.Log

/**
 * "Album" and "Artist" buttons of the widgets. They send the same custom actions as the player buttons in
 * Android Auto (CustomPlaybackActions in lib/models/finamp_models.dart) to the app's media session, which works
 * whether the app is open or not.
 */
object WidgetActions {
    const val PLAY_ALBUM = "playCurrentAlbum"
    const val PLAY_ARTIST = "playCurrentArtist"

    /** Not a media session action: switches the spectrum of the vinyl widget to its next style. */
    const val NEXT_SPECTRUM_STYLE = "nextSpectrumStyle"
    private const val EXTRA_ACTION = "action"

    fun pendingIntent(context: Context, action: String): PendingIntent {
        val intent = Intent(context, WidgetActionReceiver::class.java)
            .setAction("com.unicornsonlsd.finamp.widgets.$action")
            .putExtra(EXTRA_ACTION, action)
        return PendingIntent.getBroadcast(
            context,
            action.hashCode(),
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    /** Connects to the app's media session (audio_service) and sends [action]; [done] runs afterwards. */
    fun send(context: Context, action: String, done: () -> Unit) {
        val app = context.applicationContext
        var browser: MediaBrowserCompat? = null
        val callback = object : MediaBrowserCompat.ConnectionCallback() {
            override fun onConnected() {
                try {
                    MediaControllerCompat(app, browser!!.sessionToken).transportControls.sendCustomAction(action, null)
                } catch (e: Exception) {
                    Log.w("FinampWidgets", "Could not send $action", e)
                } finally {
                    browser?.disconnect()
                    done()
                }
            }

            override fun onConnectionFailed() {
                Log.w("FinampWidgets", "Could not reach the media session for $action")
                done()
            }
        }
        browser = MediaBrowserCompat(app, ComponentName(app, "com.ryanheise.audioservice.AudioService"), callback, null)
        browser.connect()
    }

    fun actionOf(intent: Intent): String? = intent.getStringExtra(EXTRA_ACTION)
}

class WidgetActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = WidgetActions.actionOf(intent) ?: return
        if (action == WidgetActions.NEXT_SPECTRUM_STYLE) {
            SpectrumEngine.nextStyle(context)
            return
        }
        val pending = goAsync()
        WidgetActions.send(context, action) { pending.finish() }
    }
}
