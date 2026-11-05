package com.unicornsonlsd.finamp.automix

import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.util.Log
import java.io.File
import java.io.IOException
import java.io.RandomAccessFile
import java.net.HttpURLConnection
import java.net.URL
import java.nio.ByteOrder
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * Decodes the start and the end of a track (local file or http(s) URL) with the platform decoders
 * and runs [AutoMixDsp] on both regions. Must be called from a background thread.
 */
object AutoMixAnalyzer {
    private const val TAG = "AutoMixAnalyzer"
    private const val TARGET_RATE = 11025.0
    private const val TIMEOUT_US = 10_000L

    class DecodedRegion(val samples: FloatArray, val sampleRate: Double, val startUs: Long)

    private const val MAX_DOWNLOAD_BYTES = 150L * 1024 * 1024

    /** What the analyzer is doing right now (polled by Dart for the AutoMix log). */
    @Volatile
    var progress: String = "idle"

    private fun open(url: String, range: String?): HttpURLConnection {
        @Suppress("DEPRECATION")
        val conn = URL(url).openConnection() as HttpURLConnection
        conn.connectTimeout = 15_000
        conn.readTimeout = 20_000
        conn.instanceFollowRedirects = true
        if (range != null) conn.setRequestProperty("Range", range)
        return conn
    }

    /** Copies the response body to [file] at [offset]. Returns the number of bytes written. */
    private fun copyTo(conn: HttpURLConnection, file: RandomAccessFile, offset: Long, label: String, limit: Long): Long {
        var total = 0L
        file.seek(offset)
        conn.inputStream.use { input ->
            val buf = ByteArray(64 * 1024)
            while (true) {
                val n = input.read(buf)
                if (n < 0) break
                total += n
                if (total > limit) throw IOException("file too large")
                file.write(buf, 0, n)
                progress = "$label: ${total / 1024} Ko"
            }
        }
        return total
    }

    /**
     * Downloads only the start and the end of [url] (HTTP range requests) into a file of the full size,
     * so the platform extractor can decode both regions. Falls back to a full download when the server
     * doesn't support ranges or the file is small.
     */
    private fun download(url: String, target: File, durationMs: Long, headMs: Long, tailMs: Long) {
        RandomAccessFile(target, "rw").use { file ->
            if (durationMs <= 0) {
                val conn = open(url, null)
                try {
                    if (conn.responseCode !in 200..299) throw IOException("HTTP ${conn.responseCode}")
                    copyTo(conn, file, 0, "téléchargement complet", MAX_DOWNLOAD_BYTES)
                } finally { conn.disconnect() }
                return
            }
            // first request: tells us the size, and gets the start of the file
            val probe = open(url, "bytes=0-1")
            val total: Long
            try {
                val code = probe.responseCode
                if (code == 200) {
                    // no range support: take the whole body
                    copyTo(probe, file, 0, "téléchargement complet", MAX_DOWNLOAD_BYTES)
                    return
                }
                if (code != 206) throw IOException("HTTP $code")
                val cr = probe.getHeaderField("Content-Range") ?: throw IOException("no Content-Range")
                total = cr.substringAfter('/').trim().toLong()
            } finally { probe.disconnect() }

            val bytesPerMs = total.toDouble() / durationMs
            val margin = 768L * 1024
            val headBytes = ((headMs + 5000) * bytesPerMs).toLong() + margin
            val tailBytes = ((tailMs + 10000) * bytesPerMs).toLong() + margin
            file.setLength(total)
            if (headBytes + tailBytes >= total) {
                val conn = open(url, null)
                try { copyTo(conn, file, 0, "téléchargement complet", MAX_DOWNLOAD_BYTES) } finally { conn.disconnect() }
                return
            }
            val c1 = open(url, "bytes=0-${headBytes - 1}")
            try {
                if (c1.responseCode != 206) throw IOException("HTTP ${c1.responseCode}")
                copyTo(c1, file, 0, "téléchargement du début", headBytes + 1)
            } finally { c1.disconnect() }
            val tailStart = total - tailBytes
            val c2 = open(url, "bytes=$tailStart-")
            try {
                if (c2.responseCode != 206) throw IOException("HTTP ${c2.responseCode}")
                copyTo(c2, file, tailStart, "téléchargement de la fin", tailBytes + 1)
            } finally { c2.disconnect() }
        }
    }

    fun analyze(uri: String, headMs: Long, tailMs: Long, cacheDir: File, durationMs: Long = -1): Map<String, Any?> {
        return try {
            analyzeInternal(uri, headMs, tailMs, cacheDir, durationMs, partial = true)
        } catch (e: Exception) {
            if (!(uri.startsWith("http://") || uri.startsWith("https://")) || durationMs <= 0) throw e
            Log.w(TAG, "partial analysis failed (${e.message}), retrying with the full file")
            progress = "nouvel essai avec le fichier complet (${e.message})"
            analyzeInternal(uri, headMs, tailMs, cacheDir, -1, partial = false)
        } finally {
            progress = "idle"
        }
    }

    private fun analyzeInternal(
        uri: String, headMs: Long, tailMs: Long, cacheDir: File, durationMs: Long, partial: Boolean,
    ): Map<String, Any?> {
        val started = System.currentTimeMillis()
        val isRemote = uri.startsWith("http://") || uri.startsWith("https://")
        val tmp = if (isRemote) File.createTempFile("automix", ".audio", cacheDir) else null
        val extractor = MediaExtractor()
        try {
            if (tmp != null) {
                progress = "connexion au serveur"
                download(uri, tmp, if (partial) durationMs else -1, headMs, tailMs)
                Log.i(TAG, "downloaded ${tmp.length() / 1024} KB in ${System.currentTimeMillis() - started} ms")
                progress = "lecture du fichier"
                extractor.setDataSource(tmp.absolutePath)
            } else {
                progress = "lecture du fichier local"
                extractor.setDataSource(uri.removePrefix("file://"))
            }
            var trackIndex = -1
            var format: MediaFormat? = null
            for (i in 0 until extractor.trackCount) {
                val f = extractor.getTrackFormat(i)
                if (f.getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true) {
                    trackIndex = i; format = f; break
                }
            }
            if (trackIndex < 0 || format == null) throw IllegalArgumentException("no audio track")
            extractor.selectTrack(trackIndex)
            val durationUs = if (format.containsKey(MediaFormat.KEY_DURATION)) format.getLong(MediaFormat.KEY_DURATION) else -1L

            val mime = format.getString(MediaFormat.KEY_MIME)!!
            val codec = MediaCodec.createDecoderByType(mime)
            codec.configure(format, null, null, 0)
            codec.start()
            try {
                val headEnd = if (durationUs > 0) min(headMs * 1000, durationUs) else headMs * 1000
                progress = "décodage du début"
                val head = decode(extractor, codec, 0L, headEnd)

                var tail: DecodedRegion? = null
                if (durationUs > 0) {
                    val tailStart = max(headEnd, durationUs - tailMs * 1000)
                    if (durationUs - tailStart > 6_000_000L) {
                        codec.flush()
                        progress = "décodage de la fin"
                        tail = decode(extractor, codec, tailStart, Long.MAX_VALUE)
                    }
                }

                val out = HashMap<String, Any?>()
                out["durationMs"] = if (durationUs > 0) durationUs / 1000.0 else null
                progress = "calcul du tempo"
                out["head"] = regionToMap(head)
                out["tail"] = tail?.let { regionToMap(it) }
                Log.i(TAG, "analyzed in ${System.currentTimeMillis() - started} ms: $uri".replace(Regex("ApiKey=[^&]+"), "ApiKey=***"))
                return out
            } finally {
                try { codec.stop() } catch (_: Exception) {}
                codec.release()
            }
        } finally {
            extractor.release()
            tmp?.delete()
        }
    }

    private fun regionToMap(region: DecodedRegion): Map<String, Any?> {
        val r = AutoMixDsp.analyze(region.samples, region.sampleRate)
        return mapOf(
            "startMs" to region.startUs / 1000.0,
            "lengthMs" to region.samples.size / region.sampleRate * 1000.0,
            "bpm" to r.bpm,
            "beatPeriodMs" to r.beatPeriodSec * 1000.0,
            "firstBeatMs" to region.startUs / 1000.0 + r.firstBeatSec * 1000.0,
            "downbeatIndex" to r.downbeatIndex,
            "confidence" to r.confidence,
            "energyRate" to AutoMixDsp.ENERGY_RATE,
            "energyDb" to r.energyDb.toList(),
            "lowEnergyDb" to r.lowEnergyDb.toList(),
        )
    }

    /** Decodes [startUs, endUs) to mono, decimated to ~11 kHz. */
    private fun decode(extractor: MediaExtractor, codec: MediaCodec, startUs: Long, endUs: Long): DecodedRegion {
        extractor.seekTo(startUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
        val info = MediaCodec.BufferInfo()
        var inputDone = false
        var outputDone = false

        var sampleRate = -1
        var channels = -1
        var isFloat = false
        var decimator: AutoMixDsp.Decimator? = null
        var factor = 1
        var regionStartUs = -1L
        var lastOutputUs = -1L

        fun applyFormat(f: MediaFormat) {
            sampleRate = f.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            channels = f.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
            isFloat = f.containsKey(MediaFormat.KEY_PCM_ENCODING) &&
                f.getInteger(MediaFormat.KEY_PCM_ENCODING) == AudioFormat.ENCODING_PCM_FLOAT
            factor = max(1, (sampleRate / TARGET_RATE).roundToInt())
            val seconds = if (endUs == Long.MAX_VALUE) 60.0 else (endUs - startUs) / 1e6
            decimator = AutoMixDsp.Decimator(factor, (seconds * sampleRate / factor).toInt() + 1024)
        }

        val deadline = System.currentTimeMillis() + 30_000
        while (!outputDone) {
            if (System.currentTimeMillis() > deadline) {
                if (decimator != null && lastOutputUs >= 0) break // keep what we have
                throw IllegalStateException("decoder timeout")
            }
            if (!inputDone) {
                val inIndex = codec.dequeueInputBuffer(TIMEOUT_US)
                if (inIndex >= 0) {
                    val buf = codec.getInputBuffer(inIndex)!!
                    val size = extractor.readSampleData(buf, 0)
                    val t = extractor.sampleTime
                    if (size < 0 || (endUs != Long.MAX_VALUE && t >= endUs + 200_000)) {
                        codec.queueInputBuffer(inIndex, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                        inputDone = true
                    } else {
                        codec.queueInputBuffer(inIndex, 0, size, t, 0)
                        extractor.advance()
                    }
                }
            }
            val outIndex = codec.dequeueOutputBuffer(info, TIMEOUT_US)
            when {
                outIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> applyFormat(codec.outputFormat)
                outIndex >= 0 -> {
                    if (decimator == null) applyFormat(codec.outputFormat)
                    val buf = codec.getOutputBuffer(outIndex)!!
                    buf.position(info.offset)
                    buf.limit(info.offset + info.size)
                    buf.order(ByteOrder.nativeOrder())
                    val pts = info.presentationTimeUs
                    if (info.size > 0 && pts >= startUs && (endUs == Long.MAX_VALUE || pts < endUs)) {
                        if (regionStartUs < 0) regionStartUs = pts
                        lastOutputUs = pts
                        val d = decimator!!
                        if (isFloat) {
                            val fb = buf.asFloatBuffer()
                            val frames = fb.remaining() / channels
                            for (i in 0 until frames) {
                                var s = 0f
                                for (ch in 0 until channels) s += fb.get()
                                d.push(s / channels)
                            }
                        } else {
                            val sb = buf.asShortBuffer()
                            val frames = sb.remaining() / channels
                            for (i in 0 until frames) {
                                var s = 0f
                                for (ch in 0 until channels) s += sb.get() / 32768f
                                d.push(s / channels)
                            }
                        }
                    }
                    codec.releaseOutputBuffer(outIndex, false)
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) outputDone = true
                }
            }
        }
        val d = decimator ?: throw IllegalStateException("decoder produced no audio")
        if (lastOutputUs < 0) throw IllegalStateException("no audio in requested range")
        return DecodedRegion(d.toArray(), sampleRate.toDouble() / factor, regionStartUs)
    }
}
