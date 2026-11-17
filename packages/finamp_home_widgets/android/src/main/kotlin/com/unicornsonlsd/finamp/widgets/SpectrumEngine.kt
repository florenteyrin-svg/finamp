package com.unicornsonlsd.finamp.widgets

import android.Manifest
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.graphics.Shader
import android.media.audiofx.Visualizer
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import android.util.Log
import android.widget.RemoteViews
import kotlin.math.PI
import kotlin.math.hypot
import kotlin.math.ln
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.sin

/**
 * Live spectrum of what Finamp plays, behind the title and artist of the vinyl widget.
 *
 * Android's Visualizer analyses the player's own audio session (it needs the microphone permission, but only hears
 * the app's music). Its FFT is grouped into bands on a logarithmic scale, smoothed, drawn in one of [STYLE_COUNT]
 * styles (tap the spectrum for the next one) and sent to the widget about 12 times per second, only while music
 * plays and the screen is on.
 */
object SpectrumEngine {
    private const val TAG = "FinampSpectrum"
    const val STYLE_COUNT = 6
    private const val BANDS = 22
    private const val FRAME_MS = 80L
    private const val PREFS = "finamp_home_widgets"

    private var visualizer: Visualizer? = null
    private var sessionId = 0
    private var appContext: Context? = null
    private val handler = Handler(Looper.getMainLooper())
    private val levels = FloatArray(BANDS)
    private val peaks = FloatArray(BANDS)
    @Volatile private var fft: ByteArray? = null
    private var running = false
    private var lastBitmap: Bitmap? = null

    /** From the app: the player's audio session, whether it plays, and whether the user turned the spectrum on. */
    fun update(context: Context, newSessionId: Int, playing: Boolean, turnedOn: Boolean) {
        appContext = context.applicationContext
        val wanted = turnedOn && playing && newSessionId != 0 && hasPermission(context) && hasVinylWidget(context)
        if (!wanted) {
            stop(clear = !turnedOn || !playing)
            return
        }
        if (visualizer == null || sessionId != newSessionId) {
            release()
            try {
                visualizer = Visualizer(newSessionId).apply {
                    captureSize = Visualizer.getCaptureSizeRange()[1].coerceAtMost(1024)
                    scalingMode = Visualizer.SCALING_MODE_NORMALIZED
                    setDataCaptureListener(
                        object : Visualizer.OnDataCaptureListener {
                            override fun onWaveFormDataCapture(v: Visualizer?, data: ByteArray?, rate: Int) {}
                            override fun onFftDataCapture(v: Visualizer?, data: ByteArray?, rate: Int) {
                                fft = data?.copyOf()
                            }
                        },
                        Visualizer.getMaxCaptureRate(),
                        false,
                        true,
                    )
                    enabled = true
                }
                sessionId = newSessionId
            } catch (e: Exception) {
                Log.w(TAG, "Visualizer unavailable for session $newSessionId", e)
                release()
                return
            }
        }
        if (!running) {
            running = true
            handler.post(tick)
        }
    }

    private val tick = object : Runnable {
        override fun run() {
            val context = appContext ?: return
            if (!running) return
            val started = SystemClock.uptimeMillis()
            val power = context.getSystemService(Context.POWER_SERVICE) as PowerManager
            if (power.isInteractive) {
                try {
                    pushFrame(context)
                } catch (e: Exception) {
                    Log.w(TAG, "Could not draw the spectrum", e)
                }
            }
            handler.postDelayed(this, max(10L, FRAME_MS - (SystemClock.uptimeMillis() - started)))
        }
    }

    private fun stop(clear: Boolean) {
        running = false
        handler.removeCallbacks(tick)
        release()
        if (clear) {
            levels.fill(0f); peaks.fill(0f)
            appContext?.let { context -> runCatching { pushFrame(context, blank = true) } }
        }
    }

    private fun release() {
        try {
            visualizer?.enabled = false
            visualizer?.release()
        } catch (_: Exception) {
        }
        visualizer = null
        sessionId = 0
    }

    private fun hasPermission(context: Context) =
        context.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED

    private fun ids(context: Context): IntArray =
        AppWidgetManager.getInstance(context).getAppWidgetIds(ComponentName(context, VinylWidget::class.java))

    private fun hasVinylWidget(context: Context) = ids(context).isNotEmpty()

    /** FFT -> [BANDS] levels between 0 and 1, logarithmic frequencies, fast attack, slow decay. */
    private fun analyse() {
        val data = fft ?: return
        val bins = data.size / 2
        val minBin = 1.0
        val maxBin = (bins - 1).toDouble()
        for (b in 0 until BANDS) {
            val from = (minBin * (maxBin / minBin).pow(b.toDouble() / BANDS)).toInt().coerceAtLeast(1)
            val to = (minBin * (maxBin / minBin).pow((b + 1).toDouble() / BANDS)).toInt().coerceAtLeast(from + 1)
            var sum = 0.0
            var count = 0
            for (k in from until min(to, bins)) {
                val re = data[2 * k].toDouble()
                val im = data[2 * k + 1].toDouble()
                sum += hypot(re, im)
                count++
            }
            val magnitude = if (count > 0) sum / count else 0.0
            // to dB-ish 0..1, treble lifted a bit so the right side moves too
            val db = 20 * ln(1 + magnitude) / ln(10.0)
            val tilt = 1 + 0.6 * b / BANDS
            val target = ((db * tilt) / 40.0).coerceIn(0.0, 1.0).toFloat()
            levels[b] = if (target > levels[b]) target else levels[b] * 0.82f + target * 0.18f
            peaks[b] = if (levels[b] > peaks[b]) levels[b] else max(0f, peaks[b] - 0.025f)
        }
    }

    private fun pushFrame(context: Context, blank: Boolean = false) {
        val widgetIds = ids(context)
        if (widgetIds.isEmpty()) return
        if (!blank) analyse()
        val density = context.resources.displayMetrics.density
        val w = (230 * density * 0.5f).toInt().coerceAtLeast(100)
        val h = (52 * density * 0.5f).toInt().coerceAtLeast(24)
        val bitmap = lastBitmap?.takeIf { it.width == w && it.height == h } ?: Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        lastBitmap = bitmap
        bitmap.eraseColor(Color.TRANSPARENT)
        if (!blank) draw(Canvas(bitmap), w.toFloat(), h.toFloat(), style(context))
        val views = RemoteViews(context.packageName, R.layout.widget_now_playing_vinyl)
        views.setImageViewBitmap(R.id.widget_spectrum, bitmap)
        AppWidgetManager.getInstance(context).partiallyUpdateAppWidget(widgetIds, views)
    }

    fun style(context: Context) = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getInt("spectrumStyle", 0)

    fun nextStyle(context: Context) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        prefs.edit().putInt("spectrumStyle", (style(context) + 1) % STYLE_COUNT).apply()
    }

    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)

    private fun draw(canvas: Canvas, w: Float, h: Float, style: Int) {
        val slot = w / BANDS
        val bar = slot * 0.64f
        paint.shader = null
        paint.style = Paint.Style.FILL
        when (style) {
            // 1. bars from the bottom
            0 -> {
                paint.color = Color.argb(80, 255, 255, 255)
                for (i in 0 until BANDS) {
                    val x = i * slot + (slot - bar) / 2
                    val top = h - max(h * 0.06f, h * levels[i])
                    canvas.drawRoundRect(RectF(x, top, x + bar, h), bar / 2, bar / 2, paint)
                }
            }
            // 2. mirrored bars from the middle
            1 -> {
                paint.color = Color.argb(80, 255, 255, 255)
                for (i in 0 until BANDS) {
                    val x = i * slot + (slot - bar) / 2
                    val half = max(h * 0.04f, h / 2 * levels[i])
                    canvas.drawRoundRect(RectF(x, h / 2 - half, x + bar, h / 2 + half), bar / 2, bar / 2, paint)
                }
            }
            // 3. coloured bars (blue to purple)
            2 -> {
                paint.shader = LinearGradient(0f, 0f, w, 0f, Color.argb(110, 90, 170, 255), Color.argb(110, 200, 110, 255), Shader.TileMode.CLAMP)
                for (i in 0 until BANDS) {
                    val x = i * slot + (slot - bar) / 2
                    val top = h - max(h * 0.06f, h * levels[i])
                    canvas.drawRoundRect(RectF(x, top, x + bar, h), bar / 2, bar / 2, paint)
                }
                paint.shader = null
            }
            // 4. square bars with falling peaks
            3 -> {
                for (i in 0 until BANDS) {
                    val x = i * slot + (slot - bar) / 2
                    paint.color = Color.argb(65, 255, 255, 255)
                    canvas.drawRect(x, h - max(h * 0.05f, h * levels[i]), x + bar, h, paint)
                    paint.color = Color.argb(150, 255, 255, 255)
                    val peak = h - h * min(1f, peaks[i])
                    canvas.drawRect(x, max(0f, peak - h * 0.05f), x + bar, max(h * 0.05f, peak), paint)
                }
            }
            // 5. glowing wave through the bands
            4 -> {
                paint.style = Paint.Style.STROKE
                paint.strokeCap = Paint.Cap.ROUND
                paint.strokeJoin = Paint.Join.ROUND
                for ((layer, alpha) in listOf(0 to 50, 1 to 120)) {
                    paint.strokeWidth = if (layer == 0) h * 0.12f else h * 0.045f
                    paint.color = Color.argb(alpha, 255, 255, 255)
                    val path = Path()
                    for (i in 0..BANDS * 4) {
                        val u = i / (BANDS * 4f)
                        val level = levels[min(BANDS - 1, (u * BANDS).toInt())]
                        val y = h / 2 - (h / 2 * 0.9f) * level * sin(u * PI * 9 + SystemClock.uptimeMillis() / 180.0).toFloat()
                        if (i == 0) path.moveTo(0f, y) else path.lineTo(u * w, y)
                    }
                    canvas.drawPath(path, paint)
                }
            }
            // 6. LED dots
            else -> {
                val rows = 7
                val rowH = h / rows
                val radius = min(slot, rowH) * 0.3f
                for (i in 0 until BANDS) {
                    val lit = (levels[i] * rows).toInt()
                    for (r in 0 until rows) {
                        paint.color = Color.argb(if (r < lit) 130 else 24, 255, 255, 255)
                        canvas.drawCircle(i * slot + slot / 2, h - (r + 0.5f) * rowH, radius, paint)
                    }
                }
            }
        }
    }
}
