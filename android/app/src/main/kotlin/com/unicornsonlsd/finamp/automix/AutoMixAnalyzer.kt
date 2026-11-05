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

    class DecodedRegion(
        val samples: FloatArray,
        val sampleRate: Double,
        val startUs: Long,
        /** (index of the first decimated sample of an output buffer, its presentation time) */
        val marks: List<Pair<Int, Long>> = emptyList(),
    )

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

    /** Downloads the whole body of [url] into [target]. */
    private fun downloadFull(url: String, target: File) {
        RandomAccessFile(target, "rw").use { file ->
            val conn = open(url, null)
            try {
                if (conn.responseCode !in 200..299) throw IOException("HTTP ${conn.responseCode}")
                copyTo(conn, file, 0, "téléchargement complet", MAX_DOWNLOAD_BYTES)
            } finally { conn.disconnect() }
        }
    }

    /**
     * Downloads only the start and the end of [url] (HTTP range requests) and writes them one after
     * the other into [target]. Returns false (and downloads nothing) when this isn't possible or
     * useful: no range support, small file, or an MP4 container (whose index would point to the
     * wrong bytes).
     */
    private fun downloadHeadAndTail(url: String, target: File, durationMs: Long, headMs: Long, tailMs: Long): Boolean {
        val probe = open(url, "bytes=0-15")
        val total: Long
        try {
            if (probe.responseCode != 206) return false
            val cr = probe.getHeaderField("Content-Range") ?: return false
            total = cr.substringAfter('/').trim().toLongOrNull() ?: return false
            val start = probe.inputStream.use { it.readBytes() }
            if (start.size >= 8 && String(start, 4, 4, Charsets.US_ASCII) == "ftyp") return false
        } finally { probe.disconnect() }

        val bytesPerMs = total.toDouble() / durationMs
        val margin = 768L * 1024
        val headBytes = ((headMs + 5000) * bytesPerMs).toLong() + margin
        val tailBytes = ((tailMs + 5000) * bytesPerMs).toLong() + 64 * 1024
        if (headBytes + tailBytes >= total * 0.8) return false

        RandomAccessFile(target, "rw").use { file ->
            val c1 = open(url, "bytes=0-${headBytes - 1}")
            try {
                if (c1.responseCode != 206) throw IOException("HTTP ${c1.responseCode}")
                copyTo(c1, file, 0, "téléchargement du début", headBytes + 1)
            } finally { c1.disconnect() }
            val c2 = open(url, "bytes=${total - tailBytes}-")
            try {
                if (c2.responseCode != 206) throw IOException("HTTP ${c2.responseCode}")
                copyTo(c2, file, file.length(), "téléchargement de la fin", tailBytes + 1)
            } finally { c2.disconnect() }
        }
        return true
    }

    fun analyze(uri: String, headMs: Long, tailMs: Long, cacheDir: File, durationMs: Long = -1): Map<String, Any?> {
        val isRemote = uri.startsWith("http://") || uri.startsWith("https://")
        try {
            if (!isRemote) return analyzeFile(uri.removePrefix("file://"), headMs, tailMs, durationMs)
            val tmp = File.createTempFile("automix", ".audio", cacheDir)
            try {
                if (durationMs > 0) {
                    progress = "connexion au serveur"
                    val partial = try {
                        downloadHeadAndTail(uri, tmp, durationMs, headMs, tailMs)
                    } catch (e: Exception) {
                        Log.w(TAG, "partial download failed: ${e.message}")
                        false
                    }
                    if (partial) {
                        try {
                            return analyzeConcatenated(tmp.absolutePath, headMs, tailMs, durationMs)
                        } catch (e: Exception) {
                            Log.w(TAG, "analysis of partial file failed (${e.message}), using the full file")
                            progress = "nouvel essai avec le fichier complet"
                        }
                    }
                }
                tmp.delete()
                progress = "téléchargement complet"
                downloadFull(uri, tmp)
                return analyzeFile(tmp.absolutePath, headMs, tailMs, durationMs)
            } finally {
                tmp.delete()
            }
        } finally {
            progress = "idle"
        }
    }

    private class Opened(val extractor: MediaExtractor, val codec: MediaCodec, val format: MediaFormat) {
        fun close() {
            try { codec.stop() } catch (_: Exception) {}
            try { codec.release() } catch (_: Exception) {}
            try { extractor.release() } catch (_: Exception) {}
        }
    }

    private fun openDecoder(path: String): Opened {
        val extractor = MediaExtractor()
        try {
            extractor.setDataSource(path)
            var format: MediaFormat? = null
            for (i in 0 until extractor.trackCount) {
                val f = extractor.getTrackFormat(i)
                if (f.getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true) {
                    extractor.selectTrack(i); format = f; break
                }
            }
            if (format == null) throw IllegalArgumentException("no audio track")
            val codec = MediaCodec.createDecoderByType(format.getString(MediaFormat.KEY_MIME)!!)
            codec.configure(format, null, null, 0)
            codec.start()
            return Opened(extractor, codec, format)
        } catch (e: Exception) {
            extractor.release()
            throw e
        }
    }

    /**
     * [path] holds the start of the track immediately followed by its end. Decodes it in one go
     * (no seeking), the first [headMs] are the head region, the last [tailMs] the tail region,
     * aligned so that they end at [durationMs].
     */
    private fun analyzeConcatenated(path: String, headMs: Long, tailMs: Long, durationMs: Long): Map<String, Any?> {
        val started = System.currentTimeMillis()
        progress = "décodage"
        val d = openDecoder(path)
        val all = try { decode(d.extractor, d.codec, 0L, Long.MAX_VALUE, seek = false, label = "décodage") } finally { d.close() }
        val rate = all.sampleRate
        val headCount = min(all.samples.size, (headMs / 1000.0 * rate).toInt())
        val tailCount = min(all.samples.size - headCount, (tailMs / 1000.0 * rate).toInt())
        // the decoder must have gone through both parts (some stop at the junction)
        if (all.samples.size < (headMs + tailMs) / 1000.0 * rate * 0.95) {
            throw IllegalStateException("only ${(all.samples.size / rate).toInt()} s decoded")
        }
        if (headCount < rate * 10 || tailCount < rate * 10) throw IllegalStateException("not enough audio decoded")
        val head = DecodedRegion(all.samples.copyOfRange(0, headCount), rate, 0L)
        val tailSamples = all.samples.copyOfRange(all.samples.size - tailCount, all.samples.size)
        val tailIndex = all.samples.size - tailCount
        // Containers like FLAC carry absolute sample positions in each frame, so the decoder's
        // timestamps jump at the junction and stay exact: prefer them over the end alignment.
        val firstPts = all.marks.firstOrNull()?.second ?: 0L
        val lastPts = all.marks.lastOrNull()?.second ?: 0L
        val decodedUs = (all.samples.size / rate * 1e6).toLong()
        val ptsJump = lastPts - firstPts > decodedUs + 5_000_000L && lastPts <= durationMs * 1000 + 3_000_000L
        val mark = all.marks.lastOrNull { it.first <= tailIndex }
        val tailTiming: String
        val tailStartUs = if (ptsJump && mark != null && mark.second > firstPts + decodedUs / 2) {
            tailTiming = "pts"
            mark.second + ((tailIndex - mark.first) / rate * 1e6).toLong()
        } else {
            tailTiming = "fin"
            durationMs * 1000 - (tailCount / rate * 1e6).toLong()
        }
        val tail = DecodedRegion(tailSamples, rate, tailStartUs)
        progress = "calcul du tempo"
        val out = HashMap<String, Any?>()
        out["durationMs"] = durationMs.toDouble()
        out["head"] = regionToMap(head)
        out["tail"] = regionToMap(tail)
        out["tailTiming"] = tailTiming
        Log.i(TAG, "analyzed partial file in ${System.currentTimeMillis() - started} ms")
        return out
    }

    /** Analysis of a complete file, seeking to its end. */
    private fun analyzeFile(path: String, headMs: Long, tailMs: Long, knownDurationMs: Long): Map<String, Any?> {
        val started = System.currentTimeMillis()
        val extractor = MediaExtractor()
        try {
            progress = "lecture du fichier"
            extractor.setDataSource(path)
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
            val durationUs = if (format.containsKey(MediaFormat.KEY_DURATION)) format.getLong(MediaFormat.KEY_DURATION)
                else if (knownDurationMs > 0) knownDurationMs * 1000 else -1L

            val mime = format.getString(MediaFormat.KEY_MIME)!!
            val codec = MediaCodec.createDecoderByType(mime)
            codec.configure(format, null, null, 0)
            codec.start()
            try {
                val headEnd = if (durationUs > 0) min(headMs * 1000, durationUs) else headMs * 1000
                progress = "décodage du début"
                val head = decode(extractor, codec, 0L, headEnd, seek = false, label = "décodage du début")

                var tail: DecodedRegion? = null
                if (durationUs > 0) {
                    val tailStart = max(headEnd, durationUs - tailMs * 1000)
                    if (durationUs - tailStart > 6_000_000L) {
                        // a fresh decoder: reusing one after end-of-stream doesn't work on every device
                        progress = "décodage de la fin"
                        val d = openDecoder(path)
                        try {
                            tail = decode(d.extractor, d.codec, tailStart, Long.MAX_VALUE, seek = true, label = "décodage de la fin")
                        } finally { d.close() }
                    }
                }

                val out = HashMap<String, Any?>()
                out["durationMs"] = if (durationUs > 0) durationUs / 1000.0 else null
                progress = "calcul du tempo"
                out["head"] = regionToMap(head)
                out["tail"] = tail?.let { regionToMap(it) }
                Log.i(TAG, "analyzed file in ${System.currentTimeMillis() - started} ms")
                return out
            } finally {
                try { codec.stop() } catch (_: Exception) {}
                codec.release()
            }
        } finally {
            extractor.release()
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
            "vocalEnergyDb" to r.vocalEnergyDb.toList(),
        )
    }

    /** Decodes [startUs, endUs) to mono, decimated to ~11 kHz. */
    private fun decode(
        extractor: MediaExtractor, codec: MediaCodec, startUs: Long, endUs: Long, seek: Boolean, label: String,
    ): DecodedRegion {
        if (seek) extractor.seekTo(startUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
        // without seeking, timestamps may jump (concatenated file): keep every buffer
        val filterByTime = seek || endUs != Long.MAX_VALUE
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
        val marks = ArrayList<Pair<Int, Long>>()

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
                    if (info.size > 0 && (!filterByTime || (pts >= startUs && (endUs == Long.MAX_VALUE || pts < endUs)))) {
                        if (regionStartUs < 0) regionStartUs = if (seek) pts else startUs
                        lastOutputUs = pts
                        val done = decimator!!.size / (sampleRate.toDouble() / factor)
                        progress = "$label : ${done.toInt()} s"
                        val d = decimator!!
                        marks.add(d.size to pts)
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
        return DecodedRegion(d.toArray(), sampleRate.toDouble() / factor, regionStartUs, marks)
    }
}
