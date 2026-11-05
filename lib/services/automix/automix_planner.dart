import 'dart:math';

import 'automix_models.dart';

/// Decides how to go from one track to the next, from their analyses.
/// Pure logic, no I/O, so it can be unit tested.
class AutoMixPlanner {
  AutoMixPlanner({this.allowTempoChange = true});

  final bool allowTempoChange;

  /// Max tempo change applied to the incoming track (±).
  static const maxRateChange = 0.06;
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
    final beatmatch = _tryBeatmatch(
      tail: tail,
      head: head,
      outContentEndMs: outContentEndMs,
      outFadeStartMs: outFadeStartMs,
      inContentStartMs: inContentStartMs,
    );
    if (beatmatch != null) return beatmatch;

    // ---- blend: the outgoing track fades out, or the incoming one has a soft intro ----
    if (outFadeLengthMs >= 2500) {
      // start the incoming track once the outgoing one has dropped ~8 dB
      final dropIdx = outSmooth.lastIndexWhere((e) => e >= outLoud - 8);
      var mixStart = dropIdx < 0 ? outFadeStartMs : tail.timeOfFrame(dropIdx + 1);
      mixStart = mixStart.clamp(outContentEndMs - 9000, outContentEndMs - 2500).toDouble();
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
      final length = min(4000.0, outContentEndMs - tail.startMs);
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
    const length = 1200.0;
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
  }) {
    if (!tail.hasTempo || !head.hasTempo) return null;
    if (tail.confidence < minBeatConfidence || head.confidence < minBeatConfidence) return null;

    // incoming tempo, allowing half/double time (e.g. 87 BPM rap vs 174 BPM)
    var inBpm = head.bpm;
    var inBeatMultiplier = 1.0; // incoming beats per outgoing beat
    for (final m in [0.5, 2.0]) {
      if ((head.bpm * m / tail.bpm - 1).abs() < (inBpm / tail.bpm - 1).abs()) {
        inBpm = head.bpm * m;
        inBeatMultiplier = m;
      }
    }
    final rate = tail.bpm / inBpm;
    final maxChange = allowTempoChange ? maxRateChange : 0.008;
    if ((rate - 1).abs() > maxChange) return null;

    final outBeat = tail.beatPeriodMs;
    final steady = tail.confidence >= 0.6 && head.confidence >= 0.6;
    // house & co: long 16 beat blends; everything else 8 beats
    var beats = steady && tail.bpm >= 112 ? 16 : 8;

    // the blend should be finished when the outgoing track stops "playing"
    final targetEnd = min(outContentEndMs, outFadeStartMs + 2 * outBeat);
    double? mixStart;
    while (beats >= 4) {
      final candidate = tail.downbeatAtOrBefore(targetEnd - beats * outBeat);
      if (candidate >= tail.startMs + outBeat) {
        mixStart = candidate;
        break;
      }
      beats ~/= 2;
    }
    if (mixStart == null) return null;
    final mixEnd = min(mixStart + beats * outBeat, outContentEndMs);

    // the incoming track must have sound right from its first bar
    var inStart = head.downbeatAtOrAfter(inContentStartMs - head.beatPeriodMs * 0.25);
    if (inStart < 0) inStart += head.beatPeriodMs * 4;
    if (inStart > head.endMs - 4000) return null;

    final inMult = inBeatMultiplier == 1 ? "" : " (×$inBeatMultiplier)";
    return AutoMixPlan(
      mode: AutoMixMode.beatmatch,
      outMixStartMs: mixStart,
      outEndMs: mixEnd,
      inStartMs: inStart,
      incomingRate: rate,
      bassSwapFraction: 0.5,
      inFadeFraction: 0.45,
      outFadeStartFraction: 0.5,
      outBeatPeriodMs: outBeat,
      inBeatPeriodMs: head.beatPeriodMs,
      description:
          "beatmatch $beats beats, ${tail.bpm.toStringAsFixed(1)}→${head.bpm.toStringAsFixed(1)} BPM$inMult",
    );
  }
}
