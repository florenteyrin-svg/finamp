package com.unicornsonlsd.finamp.widget

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.BitmapShader
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Shader
import android.net.Uri
import android.util.Log
import android.view.KeyEvent
import android.view.View
import android.widget.RemoteViews
import com.unicornsonlsd.finamp.R
import java.io.File
import kotlin.math.min

/** What the home screen widgets show. Written by the app (see MainActivity), read by the widgets. */
data class WidgetState(
    val title: String?,
    val artist: String?,
    val album: String?,
    val playing: Boolean,
    val artPath: String?,
) {
    companion object {
        private const val PREFS = "finamp_home_widget"

        fun load(context: Context): WidgetState {
            val p = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            return WidgetState(
                title = p.getString("title", null),
                artist = p.getString("artist", null),
                album = p.getString("album", null),
                playing = p.getBoolean("playing", false),
                artPath = p.getString("artPath", null),
            )
        }

        fun save(context: Context, state: WidgetState) {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
                .putString("title", state.title)
                .putString("artist", state.artist)
                .putString("album", state.album)
                .putBoolean("playing", state.playing)
                .putString("artPath", state.artPath)
                .apply()
        }
    }
}

object FinampWidgets {
    private const val TAG = "FinampWidgets"

    private val providers = listOf(
        FinampBarWidget::class.java,
        FinampCardWidget::class.java,
        FinampCoverWidget::class.java,
        FinampMiniWidget::class.java,
    )

    /** Redraws every Finamp widget on the home screen with the saved state. */
    fun updateAll(context: Context) {
        val manager = AppWidgetManager.getInstance(context)
        for (cls in providers) {
            val ids = manager.getAppWidgetIds(ComponentName(context, cls))
            if (ids.isEmpty()) continue
            val provider = cls.getDeclaredConstructor().newInstance()
            provider.updateWidgets(context, manager, ids)
        }
    }

    /** A broadcast to audio_service's media button receiver, like a headset button press. */
    fun mediaButton(context: Context, keyCode: Int): PendingIntent {
        val intent = Intent(Intent.ACTION_MEDIA_BUTTON)
            .setComponent(ComponentName(context, "com.ryanheise.audioservice.MediaButtonReceiver"))
            .putExtra(Intent.EXTRA_KEY_EVENT, KeyEvent(KeyEvent.ACTION_DOWN, keyCode))
        return PendingIntent.getBroadcast(
            context,
            keyCode,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    fun openApp(context: Context): PendingIntent? {
        val intent = context.packageManager.getLaunchIntentForPackage(context.packageName) ?: return null
        intent.flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
        return PendingIntent.getActivity(context, 0, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }

    /** Loads the album art (a local file), cropped square, scaled to [sizePx] and with rounded corners. */
    fun loadArt(path: String?, sizePx: Int, radiusPx: Float): Bitmap? {
        if (path.isNullOrEmpty()) return null
        return try {
            val file = File(if (path.startsWith("file://") || path.startsWith("content://")) Uri.parse(path).path ?: path else path)
            if (!file.exists()) return null
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(file.absolutePath, bounds)
            var sample = 1
            while (min(bounds.outWidth, bounds.outHeight) / (sample * 2) >= sizePx) sample *= 2
            val src = BitmapFactory.decodeFile(file.absolutePath, BitmapFactory.Options().apply { inSampleSize = sample })
                ?: return null
            // center crop to a square
            val side = min(src.width, src.height)
            val square = Bitmap.createBitmap(src, (src.width - side) / 2, (src.height - side) / 2, side, side)
            val scaled = Bitmap.createScaledBitmap(square, sizePx, sizePx, true)
            if (radiusPx <= 0f) return scaled
            val out = Bitmap.createBitmap(sizePx, sizePx, Bitmap.Config.ARGB_8888)
            val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                shader = BitmapShader(scaled, Shader.TileMode.CLAMP, Shader.TileMode.CLAMP)
            }
            Canvas(out).drawRoundRect(RectF(0f, 0f, sizePx.toFloat(), sizePx.toFloat()), radiusPx, radiusPx, paint)
            out
        } catch (e: Throwable) {
            Log.w(TAG, "could not load album art: ${e.message}")
            null
        }
    }
}

/** Common behaviour of the four widget models; each one only describes its layout. */
abstract class FinampWidgetBase : AppWidgetProvider() {
    protected abstract val layoutId: Int

    /** Size (px) the art is rendered at, and its corner radius (dp; 0 = square). */
    protected open val artSizePx = 300
    protected open val artRadiusDp = 12f

    protected open val hasArt = true
    protected open val hasArtist = true
    protected open val hasAlbum = false
    protected open val hasPrevious = true

    override fun onUpdate(context: Context, appWidgetManager: AppWidgetManager, appWidgetIds: IntArray) {
        updateWidgets(context, appWidgetManager, appWidgetIds)
    }

    fun updateWidgets(context: Context, manager: AppWidgetManager, ids: IntArray) {
        val views = build(context)
        for (id in ids) {
            try {
                manager.updateAppWidget(id, views)
            } catch (e: Exception) {
                Log.w("FinampWidgets", "update failed: ${e.message}")
            }
        }
    }

    private fun build(context: Context): RemoteViews {
        val state = WidgetState.load(context)
        val views = RemoteViews(context.packageName, layoutId)
        val nothing = state.title.isNullOrEmpty()

        views.setTextViewText(R.id.widget_title, if (nothing) context.getString(R.string.widget_nothing_playing) else state.title)
        if (hasArtist) {
            val artist = if (nothing) context.getString(R.string.widget_tap_to_open) else state.artist.orEmpty()
            views.setTextViewText(R.id.widget_artist, artist)
            views.setViewVisibility(R.id.widget_artist, if (artist.isEmpty()) View.GONE else View.VISIBLE)
        }
        if (hasAlbum) {
            val album = if (nothing) "" else state.album.orEmpty()
            views.setTextViewText(R.id.widget_album, album)
            views.setViewVisibility(R.id.widget_album, if (album.isEmpty()) View.GONE else View.VISIBLE)
        }
        if (hasArt) {
            val radiusPx = artRadiusDp * context.resources.displayMetrics.density
            val art = FinampWidgets.loadArt(state.artPath, artSizePx, radiusPx)
            if (art != null) {
                views.setImageViewBitmap(R.id.widget_art, art)
            } else {
                views.setImageViewResource(R.id.widget_art, R.drawable.widget_ic_music)
            }
        }

        views.setImageViewResource(R.id.widget_play, if (state.playing) R.drawable.widget_ic_pause else R.drawable.widget_ic_play)
        views.setOnClickPendingIntent(R.id.widget_play, FinampWidgets.mediaButton(context, KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE))
        views.setOnClickPendingIntent(R.id.widget_next, FinampWidgets.mediaButton(context, KeyEvent.KEYCODE_MEDIA_NEXT))
        if (hasPrevious) {
            views.setOnClickPendingIntent(R.id.widget_previous, FinampWidgets.mediaButton(context, KeyEvent.KEYCODE_MEDIA_PREVIOUS))
        }
        FinampWidgets.openApp(context)?.let { views.setOnClickPendingIntent(R.id.widget_root, it) }
        return views
    }
}

/** 4×1: small cover, title/artist, previous/play/next. */
class FinampBarWidget : FinampWidgetBase() {
    override val layoutId = R.layout.widget_bar
    override val artSizePx = 160
    override val artRadiusDp = 10f
}

/** 4×2: large cover, title, artist, album and controls. */
class FinampCardWidget : FinampWidgetBase() {
    override val layoutId = R.layout.widget_card
    override val artSizePx = 320
    override val artRadiusDp = 16f
    override val hasAlbum = true
}

/** 2×2 and bigger: full-size cover with title, play and next on top. */
class FinampCoverWidget : FinampWidgetBase() {
    override val layoutId = R.layout.widget_cover
    override val artSizePx = 500
    override val artRadiusDp = 24f
    override val hasPrevious = false
}

/** 2×1: title, play and next. */
class FinampMiniWidget : FinampWidgetBase() {
    override val layoutId = R.layout.widget_mini
    override val hasArt = false
    override val hasArtist = false
    override val hasPrevious = false
}
