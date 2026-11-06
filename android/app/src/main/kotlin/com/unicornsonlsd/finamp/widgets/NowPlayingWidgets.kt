package com.unicornsonlsd.finamp.widgets

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.util.Log
import android.view.KeyEvent
import android.view.View
import android.widget.RemoteViews
import com.unicornsonlsd.finamp.MainActivity
import com.unicornsonlsd.finamp.R
import java.util.concurrent.Executors

/**
 * Home screen widget models. Each model is its own provider so it shows up separately in the
 * launcher's widget picker; they all draw the same [NowPlayingState].
 */
/** [artSizeDp] is about the size the art is shown at, 0 for no art. */
enum class WidgetModel(val layout: Int, val artSizeDp: Int, val roundedArt: Boolean) {
    /** 2x2: the album art fills the widget, title and play button on top of it. */
    COVER(R.layout.widget_now_playing_cover, 200, false),

    /** 4x1: small art, title and artist, play and next. */
    BAR(R.layout.widget_now_playing_bar, 52, true),

    /** 4x2: art on the left, title, artist and album, previous / play / next. */
    MEDIUM(R.layout.widget_now_playing_medium, 126, true),

    /** 4x4: big art, title, artist, controls and the next track. */
    LARGE(R.layout.widget_now_playing_large, 210, true),

    /** 2x1: previous / play / next only, on a translucent background. */
    CONTROLS(R.layout.widget_now_playing_controls, 0, false),
}

abstract class NowPlayingWidgetProvider(private val model: WidgetModel) : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        val views = NowPlayingWidgets.render(context, model, NowPlayingStore.load(context))
        manager.updateAppWidget(ids, views)
    }

    override fun onAppWidgetOptionsChanged(context: Context, manager: AppWidgetManager, id: Int, options: Bundle) {
        onUpdate(context, manager, intArrayOf(id))
    }
}

class CoverWidget : NowPlayingWidgetProvider(WidgetModel.COVER)
class BarWidget : NowPlayingWidgetProvider(WidgetModel.BAR)
class MediumWidget : NowPlayingWidgetProvider(WidgetModel.MEDIUM)
class LargeWidget : NowPlayingWidgetProvider(WidgetModel.LARGE)
class ControlsWidget : NowPlayingWidgetProvider(WidgetModel.CONTROLS)

object NowPlayingWidgets {
    private val providers = mapOf(
        WidgetModel.COVER to CoverWidget::class.java,
        WidgetModel.BAR to BarWidget::class.java,
        WidgetModel.MEDIUM to MediumWidget::class.java,
        WidgetModel.LARGE to LargeWidget::class.java,
        WidgetModel.CONTROLS to ControlsWidget::class.java,
    )

    // One thread, so updates are applied in the order they were sent.
    private val worker = Executors.newSingleThreadExecutor()

    /** [update] off the main thread: decoding album art is too slow for it. */
    fun updateInBackground(context: Context, state: NowPlayingState) {
        worker.execute {
            try {
                update(context, state)
            } catch (e: Exception) {
                Log.w("FinampWidgets", "Could not update the widgets", e)
            }
        }
    }

    /** Saves [state] and redraws every widget placed on the home screen. */
    fun update(context: Context, state: NowPlayingState) {
        NowPlayingStore.save(context, state)
        val manager = AppWidgetManager.getInstance(context)
        for ((model, provider) in providers) {
            val ids = manager.getAppWidgetIds(ComponentName(context, provider))
            if (ids.isEmpty()) continue
            manager.updateAppWidget(ids, render(context, model, state))
        }
    }

    fun render(context: Context, model: WidgetModel, state: NowPlayingState): RemoteViews {
        val views = RemoteViews(context.packageName, model.layout)
        val res = context.resources
        val hasTrack = state.title != null

        // Album art, and a background tinted with its colour (like Apple Music's widgets).
        val artSizePx = (model.artSizeDp * res.displayMetrics.density).toInt()
        val art = if (model.artSizeDp > 0) {
            Artwork.load(state.artPath, artSizePx)
        } else {
            null
        }
        val background = art?.let { Artwork.backgroundColor(it) } ?: Artwork.defaultBackground(context)
        views.setInt(R.id.widget_background, "setColorFilter", background)
        if (model == WidgetModel.CONTROLS) {
            views.setInt(R.id.widget_background, "setImageAlpha", 0xD9)
        }
        if (model.artSizeDp > 0) {
            if (art != null) {
                val shown = if (model.roundedArt) Artwork.rounded(art, res.getDimension(R.dimen.widget_art_radius), artSizePx) else art
                views.setImageViewBitmap(R.id.widget_art, shown)
            } else {
                views.setImageViewResource(R.id.widget_art, R.drawable.widget_art_placeholder)
            }
        }

        // Texts
        views.setTextViewText(R.id.widget_title, state.title ?: context.getString(R.string.widget_nothing_playing))
        if (model != WidgetModel.CONTROLS) {
            views.setTextViewText(R.id.widget_artist, if (hasTrack) state.artist.orEmpty() else context.getString(R.string.widget_tap_to_open))
        }
        if (model == WidgetModel.MEDIUM || model == WidgetModel.LARGE) {
            setOptionalText(views, R.id.widget_album, if (hasTrack) state.album else null)
        }
        if (model == WidgetModel.LARGE) {
            val next = state.nextTitle
            if (next == null) {
                views.setViewVisibility(R.id.widget_up_next, View.GONE)
            } else {
                views.setViewVisibility(R.id.widget_up_next, View.VISIBLE)
                val line = if (state.nextArtist.isNullOrBlank()) next else "$next · ${state.nextArtist}"
                views.setTextViewText(R.id.widget_next_track, line)
            }
        }

        // Buttons
        views.setImageViewResource(R.id.widget_play, if (state.playing) R.drawable.widget_ic_pause else R.drawable.widget_ic_play)
        views.setContentDescription(
            R.id.widget_play,
            context.getString(if (state.playing) R.string.widget_pause else R.string.widget_play),
        )
        views.setOnClickPendingIntent(R.id.widget_play, mediaButton(context, KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE))
        if (model != WidgetModel.COVER) {
            views.setOnClickPendingIntent(R.id.widget_skip_next, mediaButton(context, KeyEvent.KEYCODE_MEDIA_NEXT))
        }
        if (model == WidgetModel.MEDIUM || model == WidgetModel.LARGE || model == WidgetModel.CONTROLS) {
            views.setOnClickPendingIntent(R.id.widget_skip_previous, mediaButton(context, KeyEvent.KEYCODE_MEDIA_PREVIOUS))
        }
        views.setOnClickPendingIntent(R.id.widget_root, openApp(context))
        return views
    }

    private fun setOptionalText(views: RemoteViews, id: Int, text: String?) {
        if (text.isNullOrBlank()) {
            views.setViewVisibility(id, View.GONE)
        } else {
            views.setViewVisibility(id, View.VISIBLE)
            views.setTextViewText(id, text)
        }
    }

    private fun openApp(context: Context): PendingIntent {
        val intent = Intent(context, MainActivity::class.java)
            .setAction(Intent.ACTION_MAIN)
            .addCategory(Intent.CATEGORY_LAUNCHER)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED)
        return PendingIntent.getActivity(
            context,
            0,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    /** Same media button events as headphones: handled by the audio service, even when the app is closed. */
    private fun mediaButton(context: Context, keyCode: Int): PendingIntent {
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
}
