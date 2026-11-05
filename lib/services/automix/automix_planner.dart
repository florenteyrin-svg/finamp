import 'dart:math';

import 'automix_models.dart';

/// Decides how to go from one track to the next, from their analyses.
/// Pure logic, no I/O, so it can be unit tested.
class AutoMixPlanner {
  AutoMixPlanner({this.allowTempoChange = true});

  final bool allowTempoChange;

  /// Max tempo difference that is bridged with a tempo ramp (±). Each track moves half of it.
  static const maxRateChange = 0.16;

  /// Below this, only the incoming track is adjusted (no ramp on the outgoing one).
  static const smallRateChange = 0.03;
  static const minBeatConfidence = 0.45;

  /// [outDurationMs] is the duration of the outgoing track as known by the player.
  AutoMixPlan? plan({required AutoMixAnalysis outgoing, required AutoMixAnalysis incoming, double? outDurationMs}) {
    final tail = outgoing.tail;
    if (tail == null) return null;
    final head = incoming.head;

    final outLoud = tail.loudDb;
    final inLoud = head.loudDb;
    if (outLoud < -60 || inLoud < -60) return null; // silence / broken analysis

    // ---- where does the outgoing track really end, and does it fade out? ----
    final outSmooth = tail.smoothedEnergy(windowMs: 750);
    final outSilence = max(-60.0, outLoud - 32);
    final lastSound = tail.energyDb.lastIndexWhere((e) => e > outSilence);
    if (lastSound < 0) return null;
    final outContentEndMs = min(tail.timeOfFrame(lastSound + 1), outDurationMs ?? double.infinity);
    // last moment the track is still (nearly) at full level
    final fullIdx = outSmooth.lastIndexWhere((e) => e >= outLoud - 5);
    final outFadeStartMs = fullIdx < 0 ? tail.startMs : tail.timeOfFrame(fullIdx + 1);
    final outFadeLengthMs = max(0.0, outContentEndMs - outFadeStartMs);

    // ---- where does the incoming track really start? ----
    final inSmooth = head.smoothedEnergy(windowMs: 500);
    final inSilence = max(-60.0, inLoud - 32);
    final firstSound = head.energyDb.indexWhere((e) => e > inSilence);
    if (firstSound < 0) return null;
    // start one frame early: better a few ms of silence than a cut attack
    final inContentStartMs = head.timeOfFrame(max(0, firstSound - 1));
    final inFullIdx = inSmooth.indexWhere((e) => e >= inLoud - 5);
    final inFullAtMs = inFullIdx < 0 ? head.endMs : head.timeOfFrame(inFullIdx);
    final inIntroLengthMs = max(0.0, inFullAtMs - inContentStartMs);

    // ---- beat matched mix, when both tracks have a steady, compatible beat ----
    // ---- where do the vocals end / start? ----
    var outVocalEndMs = tail.lastVocalEndMs();
    if (outVocalEndMs != null && (outVocalEndMs > outContentEndMs - 300 || outVocalEndMs < tail.startMs + 3000)) {
      outVocalEndMs = null; // sung until the very end, or unusable
    }
    final inVocalStartMs = head.firstVocalStartMs(fromMs: inContentStartMs + 800);

    final beatmatch = _tryBeatmatch(
      tail: tail,
      head: head,
      outContentEndMs: outContentEndMs,
      outFadeStartMs: outFadeStartMs,
      inContentStartMs: inContentStartMs,
      outVocalEndMs: outVocalEndMs,
      inVocalStartMs: inVocalStartMs,
    );
    if (beatmatch != null) return beatmatch;

    // ---- vocal handover without beat matching: next vocals start right after the last ones ----
    if (outVocalEndMs != null && inVocalStartMs != null) {
      final inStart = max(max(0.0, inContentStartMs - 50), inVocalStartMs - 8000);
      final pre = inVocalStartMs - inStart;
      final mixStart = outVocalEndMs + 150 - pre;
      final outEnd = min(outContentEndMs, outVocalEndMs + 2500);
      if (mixStart >= tail.startMs && outEnd - mixStart >= 2000) {
        final length = outEnd - mixStart;
        return AutoMixPlan(
          mode: AutoMixMode.blend,
          outMixStartMs: mixStart,
          outEndMs: outEnd,
          inStartMs: inStart,
          incomingRate: 1,
          vocalAligned: true,
          bassSwapFraction: null,
          inFadeFraction: (pre / length * 0.8).clamp(0.1, 0.9).toDouble(),
          outFadeStartFraction: ((outVocalEndMs - 600 - mixStart) / length).clamp(0.0, 0.9).toDouble(),
          outBeatPeriodMs: null,
          inBeatPeriodMs: null,
          description: "voix → voix ${(length / 1000).toStringAsFixed(1)}s",
        );
      }
    }

    // ---- blend: the outgoing track fades out, or the incoming one has a soft intro ----
    if (outFadeLengthMs >= 2500) {
      // start the incoming track once the outgoing one has dropped ~8 dB
      final dropIdx = outSmooth.lastIndexWhere((e) => e >= outLoud - 8);
      var mixStart = dropIdx < 0 ? outFadeStartMs : tail.timeOfFrame(dropIdx + 1);
      mixStart = mixStart.clamp(outContentEndMs - 10000, outContentEndMs - 6000).toDouble();
      mixStart = max(mixStart, tail.startMs);
      final length = outContentEndMs - mixStart;
      // if the incoming track starts loud, fade it in over the first part
      final inFade = inIntroLengthMs > 1500 ? 0.15 : min(0.6, 1500 / length);
      return AutoMixPlan(
        mode: AutoMixMode.blend,
        outMixStartMs: mixStart,
        outEndMs: outContentEndMs,
        inStartMs: max(0, inContentStartMs - 50),
        incomingRate: 1,
        bassSwapFraction: null,
        inFadeFraction: inFade,
        outFadeStartFraction: 0.1,
        outBeatPeriodMs: null,
        inBeatPeriodMs: null,
        description: "blend ${(length / 1000).toStringAsFixed(1)}s (outgoing fades out)",
      );
    }

    if (inIntroLengthMs >= 3000) {
      // abrupt ending but soft intro: let the intro rise under the last seconds
      final length = min(6000.0, outContentEndMs - tail.startMs);
      return AutoMixPlan(
        mode: AutoMixMode.blend,
        outMixStartMs: outContentEndMs - length,
        outEndMs: outContentEndMs,
        inStartMs: max(0, inContentStartMs - 50),
        incomingRate: 1,
        bassSwapFraction: null,
        inFadeFraction: 0.05,
        outFadeStartFraction: 0.5,
        outBeatPeriodMs: null,
        inBeatPeriodMs: null,
        description: "blend ${(length / 1000).toStringAsFixed(1)}s (soft intro)",
      );
    }

    // ---- both ends are "hard": just glue them together tightly ----
    const length = 2500.0;
    return AutoMixPlan(
      mode: AutoMixMode.quick,
      outMixStartMs: max(tail.startMs, outContentEndMs - length),
      outEndMs: outContentEndMs,
      inStartMs: max(0, inContentStartMs - 30),
      incomingRate: 1,
      bassSwapFraction: null,
      inFadeFraction: 0.25,
      outFadeStartFraction: 0.35,
      outBeatPeriodMs: null,
      inBeatPeriodMs: null,
      description: "quick (hard ending)",
    );
  }

  AutoMixPlan? _tryBeatmatch({
    required AutoMixRegion tail,
    required AutoMixRegion head,
    required double outContentEndMs,
    required double outFadeStartMs,
    required double inContentStartMs,
    double? outVocalEndMs,
    double? inVocalStartMs,
  }) {
    if (!tail.hasTempo || !head.hasTempo) return null;
    if (tail.confidence < minBeatConfidence || head.confidence < minBeatConfidence) return null;

    // incoming tempo, allowing half/double time (e.g. 87 BPM rap vs 174 BPM)
    var inBpm = head.bpm;
    var inBeatMultiplier = 1.0;
    for (final m in [0.5, 2.0]) {
      if ((head.bpm * m / tail.bpm - 1).abs() < (inBpm / tail.bpm - 1).abs()) {
        inBpm = head.bpm * m;
        inBeatMultiplier = m;
      }
    }
    // incoming track time per outgoing track time when beats are locked
    final ratio = tail.bpm / inBpm;
    final maxChange = allowTempoChange ? maxRateChange : 0.008;
    if ((ratio - 1).abs() > maxChange) return null;
    // small differences: only the incoming track moves; bigger ones: both meet halfway (tempo ramp)
    final outRate = (ratio - 1).abs() <= smallRateChange ? 1.0 : 1 / sqrt(ratio);
    final inRate = ratio * outRate;

    final outBeat = tail.beatPeriodMs;
    final inBeat = head.beatPeriodMs;
    final inMult = inBeatMultiplier == 1 ? "" : " (×$inBeatMultiplier)";
    final tempo = "${tail.bpm.toStringAsFixed(0)}→${head.bpm.toStringAsFixed(0)} BPM$inMult";

    // ---- vocal handover on the beat ----
    if (outVocalEndMs != null && inVocalStartMs != null) {
      // bar of the outgoing track where the incoming vocals should come in
      var landing = tail.downbeatAtOrAfter(outVocalEndMs + 0.25 * outBeat);
      if (landing > outContentEndMs - outBeat) landing = tail.downbeatAtOrBefore(outContentEndMs - outBeat);
      // bar of the incoming track where its vocals start (a short pickup before it is fine)
      final inVocalBar = head.downbeatAtOrBefore(inVocalStartMs + 0.5 * inBeat);
      final preferredBars = tail.bpm >= 112 ? 4 : 2;
      for (var bars = preferredBars; bars >= 1; bars--) {
        final inStart = inVocalBar - bars * 4 * inBeat;
        // the beats lock incoming time to outgoing time through the ratio
        final mixStart = landing - bars * 4 * inBeat / ratio;
        if (inStart < max(0.0, inContentStartMs - 0.3 * inBeat)) continue;
        if (mixStart < tail.startMs + outBeat) continue;
        final outEnd = min(outContentEndMs, landing + 4 * outBeat);
        final length = outEnd - mixStart;
        if (length < 4 * outBeat) continue;
        final landingFraction = (landing - mixStart) / length;
        return AutoMixPlan(
          mode: AutoMixMode.beatmatch,
          outMixStartMs: mixStart,
          outEndMs: outEnd,
          inStartMs: inStart,
          incomingRate: inRate,
          outgoingRate: outRate,
          beatRatio: ratio,
          vocalAligned: true,
          bassSwapFraction: null,
          inFadeFraction: landingFraction * 0.75,
          outFadeStartFraction: max(0.0, (landing - 2 * outBeat - mixStart) / length),
          outBeatPeriodMs: outBeat,
          inBeatPeriodMs: inBeat,
          description: "beatmatch voix → voix, $bars mesure${bars > 1 ? "s" : ""} d'intro, $tempo",
        );
      }
    }

    // ---- classic DJ blend at the end of the outgoing track ----
    final steady = tail.confidence >= 0.6 && head.confidence >= 0.6;
    var beats = steady && tail.bpm >= 112 ? 16 : 8;
    double? mixStart;
    for (final targetEnd in [min(outContentEndMs, outFadeStartMs + 4 * outBeat), outContentEndMs]) {
      var b = beats;
      while (b >= 8 && mixStart == null) {
        final candidate = tail.downbeatAtOrBefore(targetEnd - b * outBeat);
        if (candidate >= tail.startMs + outBeat) {
          mixStart = candidate;
          beats = b;
        } else {
          b ~/= 2;
        }
      }
      if (mixStart != null) break;
    }
    if (mixStart == null) return null;
    final mixEnd = min(mixStart + beats * outBeat, outContentEndMs);

    // the incoming track must have sound right from its first bar
    var inStart = head.downbeatAtOrAfter(inContentStartMs - inBeat * 0.25);
    if (inStart < 0) inStart += inBeat * 4;
    if (inStart > head.endMs - 4000) return null;

    return AutoMixPlan(
      mode: AutoMixMode.beatmatch,
      outMixStartMs: mixStart,
      outEndMs: mixEnd,
      inStartMs: inStart,
      incomingRate: inRate,
      outgoingRate: outRate,
      beatRatio: ratio,
      bassSwapFraction: null,
      inFadeFraction: 0.45,
      outFadeStartFraction: 0.5,
      outBeatPeriodMs: outBeat,
      inBeatPeriodMs: inBeat,
      description: "beatmatch $beats temps, $tempo",
    );
  }
}
