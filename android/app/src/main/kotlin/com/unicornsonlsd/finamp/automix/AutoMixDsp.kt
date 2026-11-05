package com.unicornsonlsd.finamp.automix

import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.exp
import kotlin.math.ln
import kotlin.math.log10
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * Pure DSP used by AutoMix (no Android dependency, so it can be unit tested on a JVM).
 *
 * Input: mono samples (already downsampled to ~11-12 kHz) of one region of a track.
 * Output: tempo, a constant beat grid, a downbeat guess and a loudness curve.
 */
object AutoMixDsp {

    /** Onset envelope frames per second. */
    const val ENVELOPE_RATE = 200.0

    /** Loudness curve frames per second. */
    const val ENERGY_RATE = 20.0

    const val MIN_BPM = 68.0
    const val MAX_BPM = 190.0

    class Result(
        /** Beats per minute of the region (0 if no tempo could be found). */
        val bpm: Double,
        /** Seconds between two beats. */
        val beatPeriodSec: Double,
        /** Time (seconds, relative to region start) of the first beat of the grid. */
        val firstBeatSec: Double,
        /** Index (0..3) of the beat (counting from firstBeat) that looks like a bar's first beat. */
        val downbeatIndex: Int,
        /** 0..1, how well the region follows a steady beat grid. */
        val confidence: Double,
        /** Loudness in dBFS, [ENERGY_RATE] values per second. */
        val energyDb: DoubleArray,
        /** Loudness of the low band (< ~150 Hz) in dBFS, [ENERGY_RATE] values per second. */
        val lowEnergyDb: DoubleArray,
    )

    /** Simple biquad filter (RBJ cookbook). */
    private class Biquad(type: Int, freq: Double, q: Double, fs: Double) {
        private val b0: Double
        private val b1: Double
        private val b2: Double
        private val a1: Double
        private val a2: Double
        private var x1 = 0.0
        private var x2 = 0.0
        private var y1 = 0.0
        private var y2 = 0.0

        init {
            val w0 = 2 * PI * freq / fs
            val alpha = sin(w0) / (2 * q)
            val c = cos(w0)
            val a0: Double
            when (type) {
                LOWPASS -> {
                    a0 = 1 + alpha
                    b0 = (1 - c) / 2 / a0; b1 = (1 - c) / a0; b2 = (1 - c) / 2 / a0
                }
                HIGHPASS -> {
                    a0 = 1 + alpha
                    b0 = (1 + c) / 2 / a0; b1 = -(1 + c) / a0; b2 = (1 + c) / 2 / a0
                }
                else -> { // band pass, constant 0 dB peak gain
                    a0 = 1 + alpha
                    b0 = alpha / a0; b1 = 0.0; b2 = -alpha / a0
                }
            }
            a1 = -2 * c / a0
            a2 = (1 - alpha) / a0
        }

        fun process(x: Double): Double {
            val y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x; y2 = y1; y1 = y
            return y
        }

        companion object {
            const val LOWPASS = 0
            const val HIGHPASS = 1
            const val BANDPASS = 2
        }
    }

    fun analyze(samples: FloatArray, sampleRate: Double): Result {
        val hop = max(1, (sampleRate / ENVELOPE_RATE).roundToInt())
        val envRate = sampleRate / hop
        val frames = samples.size / hop

        // --- band energies per hop ---
        val low = Biquad(Biquad.LOWPASS, 150.0, 0.707, sampleRate)
        val low2 = Biquad(Biquad.LOWPASS, 150.0, 0.707, sampleRate)
        val mid = Biquad(Biquad.BANDPASS, 800.0, 0.6, sampleRate)
        val high = Biquad(Biquad.HIGHPASS, 2500.0, 0.707, sampleRate)

        val eLow = DoubleArray(frames)
        val eMid = DoubleArray(frames)
        val eHigh = DoubleArray(frames)
        val eAll = DoubleArray(frames)
        for (f in 0 until frames) {
            var sl = 0.0
            var sm = 0.0
            var sh = 0.0
            var sa = 0.0
            val base = f * hop
            for (i in 0 until hop) {
                val x = samples[base + i].toDouble()
                val l = low2.process(low.process(x))
                val m = mid.process(x)
                val h = high.process(x)
                sl += l * l; sm += m * m; sh += h * h; sa += x * x
            }
            eLow[f] = sl / hop; eMid[f] = sm / hop; eHigh[f] = sh / hop; eAll[f] = sa / hop
        }

        // --- onset envelope: weighted sum of log-energy rises per band ---
        val onset = DoubleArray(frames)
        val lowOnset = DoubleArray(frames)
        val c = 1e4
        for (f in 1 until frames) {
            val dl = max(0.0, ln(1 + c * eLow[f]) - ln(1 + c * eLow[f - 1]))
            val dm = max(0.0, ln(1 + c * eMid[f]) - ln(1 + c * eMid[f - 1]))
            val dh = max(0.0, ln(1 + c * eHigh[f]) - ln(1 + c * eHigh[f - 1]))
            onset[f] = 1.4 * dl + 1.0 * dm + 0.8 * dh
            lowOnset[f] = dl
        }
        // remove slow trend (moving average over ~0.4 s) and half-wave rectify
        val env = subtractMovingAverage(onset, (0.4 * envRate).roundToInt())
        val lowEnv = subtractMovingAverage(lowOnset, (0.4 * envRate).roundToInt())

        val energyDb = energyCurve(eAll, envRate)
        val lowEnergyDb = energyCurve(eLow, envRate)

        val empty = Result(0.0, 0.0, 0.0, 0, 0.0, energyDb, lowEnergyDb)
        if (frames < envRate * 6) return empty // not enough material for a tempo
        var envMean = 0.0
        for (v in env) envMean += v
        envMean /= frames
        if (envMean <= 1e-9) return empty

        // --- tempo via weighted autocorrelation ---
        val minLag = (60.0 / MAX_BPM * envRate).toInt()
        val maxLag = (60.0 / MIN_BPM * envRate).toInt() + 1
        if (maxLag * 2 >= frames) return empty
        val ac = DoubleArray(maxLag * 2 + 2)
        for (lag in 0 until ac.size) {
            var s = 0.0
            val n = frames - lag
            for (i in 0 until n) s += env[i] * env[i + lag]
            ac[lag] = s / n
        }
        var bestLag = -1
        var bestScore = Double.NEGATIVE_INFINITY
        for (lag in minLag..maxLag) {
            val bpm = 60.0 * envRate / lag
            // prefer tempi around 115 BPM (log-gaussian, ~1 octave wide)
            val w = exp(-0.5 * sq(log2(bpm / 115.0) / 0.9))
            // reward lags whose double also correlates (true beat periodicity)
            val score = w * (ac[lag] + 0.5 * ac[min(ac.size - 1, lag * 2)])
            if (score > bestScore) {
                bestScore = score; bestLag = lag
            }
        }
        if (bestLag <= 0) return empty

        // --- refine period and phase jointly with a comb over the whole region ---
        var bestPeriod = bestLag.toDouble()
        var bestPhase = 0.0
        var bestComb = Double.NEGATIVE_INFINITY
        var p = bestLag - 1.0
        while (p <= bestLag + 1.0) {
            val (phase, score) = bestPhaseFor(env, p)
            if (score > bestComb) {
                bestComb = score; bestPeriod = p; bestPhase = phase
            }
            p += 0.02
        }

        // confidence: mean envelope on the grid vs. mean envelope everywhere
        val beats = beatFrames(frames, bestPeriod, bestPhase)
        var onGrid = 0.0
        var hits = 0
        val tol = (0.03 * envRate).roundToInt() // 30 ms
        for (b in beats) {
            onGrid += localMax(env, b, 1)
            // a "hit" is a beat with a clear onset near it
            if (localMax(env, b, tol) > envMean * 2.0) hits++
        }
        onGrid /= max(1, beats.size)
        val ratio = onGrid / envMean // 1 = random, >3 = very steady
        val hitRate = hits.toDouble() / max(1, beats.size)
        val confidence = (((ratio - 1.2) / 2.5).coerceIn(0.0, 1.0) * 0.6 + hitRate * 0.4).coerceIn(0.0, 1.0)

        // --- downbeat: the beat phase (mod 4) with the strongest low-frequency onsets ---
        val barScore = DoubleArray(4)
        for ((k, b) in beats.withIndex()) barScore[k % 4] += localMax(lowEnv, b, 2)
        var downbeat = 0
        for (k in 1 until 4) if (barScore[k] > barScore[downbeat]) downbeat = k

        val periodSec = bestPeriod / envRate
        return Result(
            bpm = 60.0 / periodSec,
            beatPeriodSec = periodSec,
            firstBeatSec = (bestPhase + 0.5) / envRate, // +0.5: frame centre
            downbeatIndex = downbeat,
            confidence = confidence,
            energyDb = energyDb,
            lowEnergyDb = lowEnergyDb,
        )
    }

    private fun bestPhaseFor(env: DoubleArray, period: Double): Pair<Double, Double> {
        var bestPhase = 0.0
        var best = Double.NEGATIVE_INFINITY
        var phase = 0.0
        while (phase < period) {
            var s = 0.0
            var n = 0
            var t = phase
            while (t < env.size - 1) {
                val i = t.toInt()
                val fr = t - i
                s += env[i] * (1 - fr) + env[i + 1] * fr
                n++
                t += period
            }
            val score = if (n > 0) s / n else 0.0
            if (score > best) {
                best = score; bestPhase = phase
            }
            phase += 0.5
        }
        return bestPhase to best
    }

    private fun beatFrames(frames: Int, period: Double, phase: Double): List<Int> {
        val out = ArrayList<Int>()
        var t = phase
        while (t < frames) {
            out.add(t.roundToInt().coerceIn(0, frames - 1))
            t += period
        }
        return out
    }

    private fun localMax(a: DoubleArray, centre: Int, radius: Int): Double {
        var m = 0.0
        for (i in max(0, centre - radius)..min(a.size - 1, centre + radius)) m = max(m, a[i])
        return m
    }

    private fun subtractMovingAverage(a: DoubleArray, window: Int): DoubleArray {
        val w = max(1, window)
        val out = DoubleArray(a.size)
        var sum = 0.0
        val half = w / 2
        // prefix sums for a centred window
        val prefix = DoubleArray(a.size + 1)
        for (i in a.indices) prefix[i + 1] = prefix[i] + a[i]
        for (i in a.indices) {
            val lo = max(0, i - half)
            val hi = min(a.size, i + half + 1)
            val mean = (prefix[hi] - prefix[lo]) / (hi - lo)
            out[i] = max(0.0, a[i] - mean)
        }
        sum += 0.0
        return out
    }

    private fun energyCurve(e: DoubleArray, envRate: Double): DoubleArray {
        val per = max(1, (envRate / ENERGY_RATE).roundToInt())
        val n = e.size / per
        val out = DoubleArray(n)
        for (k in 0 until n) {
            var s = 0.0
            for (i in k * per until (k + 1) * per) s += e[i]
            val rms = sqrt(s / per)
            out[k] = if (rms <= 1e-9) -120.0 else 20 * log10(rms)
        }
        return out
    }

    private fun sq(x: Double) = x * x
    private fun log2(x: Double) = ln(x) / ln(2.0)

    /** Averaging decimator used while decoding, so we never keep full-rate audio in memory. */
    class Decimator(private val factor: Int, capacity: Int) {
        private var acc = 0.0
        private var count = 0
        var data = FloatArray(max(16, capacity))
            private set
        var size = 0
            private set

        fun push(x: Float) {
            acc += x
            count++
            if (count == factor) {
                if (size == data.size) data = data.copyOf(data.size * 2)
                data[size++] = (acc / factor).toFloat()
                acc = 0.0
                count = 0
            }
        }

        fun toArray(): FloatArray = data.copyOf(size)

        @Suppress("unused")
        fun absPeak(): Float {
            var m = 0f
            for (i in 0 until size) m = max(m, abs(data[i]))
            return m
        }
    }
}
