package com.unicornsonlsd.finamp.widgets

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.SystemClock
import android.util.Log
import android.view.KeyEvent
import android.view.View
import android.widget.RemoteViews
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

    /** 4x2: a record that spins while playing, with the art as its label, progress and controls. */
    VINYL(R.layout.widget_now_playing_vinyl, 80, false),
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
class VinylWidget : NowPlayingWidgetProvider(WidgetModel.VINYL)

object NowPlayingWidgets {
    private val providers = mapOf(
        WidgetModel.COVER to CoverWidget::class.java,
        WidgetModel.BAR to BarWidget::class.java,
        WidgetModel.MEDIUM to MediumWidget::class.java,
        WidgetModel.LARGE to LargeWidget::class.java,
        WidgetModel.CONTROLS to ControlsWidget::class.java,
        WidgetModel.VINYL to VinylWidget::class.java,
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
                val shown = when {
                    model == WidgetModel.VINYL -> Artwork.circle(art)
                    model.roundedArt -> Artwork.rounded(art, res.getDimension(R.dimen.widget_art_radius), artSizePx)
                    else -> art
                }
                views.setImageViewBitmap(R.id.widget_art, shown)
            } else {
                views.setImageViewResource(
                    R.id.widget_art,
                    if (model == WidgetModel.VINYL) R.drawable.widget_ic_music else R.drawable.widget_art_placeholder,
                )
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

        if (model == WidgetModel.VINYL) {
            renderVinyl(views, state)
            renderSpinningLabel(context, views, state, art)
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
        if (model == WidgetModel.MEDIUM || model == WidgetModel.LARGE || model == WidgetModel.CONTROLS ||
            model == WidgetModel.VINYL
        ) {
            views.setOnClickPendingIntent(R.id.widget_skip_previous, mediaButton(context, KeyEvent.KEYCODE_MEDIA_PREVIOUS))
        }
        // Same as the player buttons in Android Auto: the whole album in order / the artist shuffled
        views.setOnClickPendingIntent(R.id.widget_btn_album, WidgetActions.pendingIntent(context, WidgetActions.PLAY_ALBUM))
        views.setOnClickPendingIntent(R.id.widget_btn_artist, WidgetActions.pendingIntent(context, WidgetActions.PLAY_ARTIST))
        views.setOnClickPendingIntent(R.id.widget_root, openApp(context))
        return views
    }

    /** The record spins (an indeterminate ProgressBar, the only animation widgets can run) only while playing. */
    private fun renderVinyl(views: RemoteViews, state: NowPlayingState) {
        views.setViewVisibility(R.id.widget_vinyl_spinning, if (state.playing) View.VISIBLE else View.GONE)
        views.setViewVisibility(R.id.widget_vinyl_still, if (state.playing) View.GONE else View.VISIBLE)
        views.setImageViewResource(
            R.id.widget_tonearm,
            if (state.playing) R.drawable.widget_tonearm_on else R.drawable.widget_tonearm_off,
        )
        val duration = state.durationMs
        val position = state.currentPositionMs().coerceAtLeast(0)
        if (duration != null && duration > 0) {
            views.setProgressBar(R.id.widget_progress, 1000, (position * 1000 / duration).toInt().coerceIn(0, 1000), false)
            views.setTextViewText(R.id.widget_duration, formatTime(duration))
        } else {
            views.setProgressBar(R.id.widget_progress, 1000, 0, false)
            views.setTextViewText(R.id.widget_duration, "")
        }
        val qualityLogo = when (state.quality) {
            "Hi-Res" -> R.drawable.widget_quality_hires
            "CD" -> R.drawable.widget_quality_cd
            "MP3" -> R.drawable.widget_quality_mp3
            else -> null
        }
        if (qualityLogo == null || state.title == null) {
            views.setViewVisibility(R.id.widget_quality, View.GONE)
        } else {
            views.setViewVisibility(R.id.widget_quality, View.VISIBLE)
            views.setImageViewResource(R.id.widget_quality, qualityLogo)
            views.setContentDescription(R.id.widget_quality, state.quality)
        }

        // Counts up by itself while playing
        views.setChronometer(R.id.widget_elapsed, SystemClock.elapsedRealtime() - position, null, state.playing)
    }

    private val labelFrameIds = intArrayOf(R.id.widget_label_0, R.id.widget_label_1, R.id.widget_label_2, R.id.widget_label_3, R.id.widget_label_4, R.id.widget_label_5, R.id.widget_label_6, R.id.widget_label_7, R.id.widget_label_8, R.id.widget_label_9, R.id.widget_label_10, R.id.widget_label_11, R.id.widget_label_12, R.id.widget_label_13, R.id.widget_label_14, R.id.widget_label_15, R.id.widget_label_16, R.id.widget_label_17, R.id.widget_label_18, R.id.widget_label_19, R.id.widget_label_20, R.id.widget_label_21, R.id.widget_label_22, R.id.widget_label_23, R.id.widget_label_24, R.id.widget_label_25, R.id.widget_label_26, R.id.widget_label_27, R.id.widget_label_28, R.id.widget_label_29, R.id.widget_label_30, R.id.widget_label_31, R.id.widget_label_32, R.id.widget_label_33, R.id.widget_label_34, R.id.widget_label_35, R.id.widget_label_36, R.id.widget_label_37, R.id.widget_label_38, R.id.widget_label_39, R.id.widget_label_40, R.id.widget_label_41, R.id.widget_label_42, R.id.widget_label_43, R.id.widget_label_44, R.id.widget_label_45, R.id.widget_label_46, R.id.widget_label_47, R.id.widget_label_48, R.id.widget_label_49, R.id.widget_label_50, R.id.widget_label_51, R.id.widget_label_52, R.id.widget_label_53, R.id.widget_label_54, R.id.widget_label_55, R.id.widget_label_56, R.id.widget_label_57, R.id.widget_label_58, R.id.widget_label_59, R.id.widget_label_60, R.id.widget_label_61, R.id.widget_label_62, R.id.widget_label_63, R.id.widget_label_64, R.id.widget_label_65, R.id.widget_label_66, R.id.widget_label_67, R.id.widget_label_68, R.id.widget_label_69, R.id.widget_label_70, R.id.widget_label_71, R.id.widget_label_72, R.id.widget_label_73, R.id.widget_label_74, R.id.widget_label_75, R.id.widget_label_76, R.id.widget_label_77, R.id.widget_label_78, R.id.widget_label_79, R.id.widget_label_80, R.id.widget_label_81, R.id.widget_label_82, R.id.widget_label_83, R.id.widget_label_84, R.id.widget_label_85, R.id.widget_label_86, R.id.widget_label_87, R.id.widget_label_88, R.id.widget_label_89, R.id.widget_label_90, R.id.widget_label_91, R.id.widget_label_92, R.id.widget_label_93, R.id.widget_label_94, R.id.widget_label_95, R.id.widget_label_96, R.id.widget_label_97, R.id.widget_label_98, R.id.widget_label_99, R.id.widget_label_100, R.id.widget_label_101, R.id.widget_label_102, R.id.widget_label_103, R.id.widget_label_104, R.id.widget_label_105, R.id.widget_label_106, R.id.widget_label_107)

    /**
     * Makes the album art turn with the record: widgets cannot rotate a picture, so each frame of a ViewFlipper
     * shows the art turned a little further (108 frames, 16 ms each: 60 frames per second, one turn in 1.73 s
     * like the grooves). The frames are PNG files handed over by address (content://), so their number and size are
     * not limited by the amount of data a widget update may carry.
     */
    private fun renderSpinningLabel(context: Context, views: RemoteViews, state: NowPlayingState, art: android.graphics.Bitmap?) {
        val frames = if (state.playing && art != null) {
            Artwork.rotatedLabelFiles(context, state.artPath ?: "", art, labelFrameIds.size, 144)
        } else {
            null
        }
        val spinning = frames != null
        views.setViewVisibility(R.id.widget_label_spinning, if (spinning) View.VISIBLE else View.GONE)
        views.setViewVisibility(R.id.widget_art, if (spinning) View.GONE else View.VISIBLE)
        frames?.forEachIndexed { i, uri -> views.setImageViewUri(labelFrameIds[i], uri) }
    }

    private fun formatTime(ms: Long): String {
        val totalSeconds = ms / 1000
        return "%d:%02d".format(totalSeconds / 60, totalSeconds % 60)
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
        val intent = (context.packageManager.getLaunchIntentForPackage(context.packageName) ?: Intent())
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
