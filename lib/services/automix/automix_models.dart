import 'dart:math';

/// Analysis of one region (start or end) of a track, produced by the native
/// analyzer (android/.../automix/AutoMixAnalyzer.kt).
/// All times are absolute track times in milliseconds.
class AutoMixRegion {
  AutoMixRegion({
    required this.startMs,
    required this.lengthMs,
    required this.bpm,
    required this.beatPeriodMs,
    required this.firstBeatMs,
    required this.downbeatIndex,
    required this.confidence,
    required this.energyRate,
    required this.energyDb,
    required this.lowEnergyDb,
    this.vocalDb = const [],
  });

  final double startMs;
  final double lengthMs;
  final double bpm;
  final double beatPeriodMs;
  final double firstBeatMs;
  final int downbeatIndex;
  final double confidence;

  /// Values per second of [energyDb] / [lowEnergyDb].
  final double energyRate;
  final List<double> energyDb;
  final List<double> lowEnergyDb;

  /// Energy of the voice band (300-3400 Hz), same rate as [energyDb]. May be empty.
  final List<double> vocalDb;

  double get endMs => startMs + lengthMs;
  double get frameMs => 1000.0 / energyRate;
  bool get hasTempo => bpm > 0 && beatPeriodMs > 0;

  /// Time of the first beat of a bar (according to [downbeatIndex]).
  double get firstDownbeatMs => firstBeatMs + downbeatIndex * beatPeriodMs;

  /// Latest downbeat at or before [ms] (may be before the region start).
  double downbeatAtOrBefore(double ms) {
    final bar = beatPeriodMs * 4;
    final k = ((ms - firstDownbeatMs) / bar).floorToDouble();
    return firstDownbeatMs + k * bar;
  }

  /// First downbeat at or after [ms].
  double downbeatAtOrAfter(double ms) {
    final bar = beatPeriodMs * 4;
    final k = ((ms - firstDownbeatMs) / bar).ceilToDouble();
    return firstDownbeatMs + k * bar;
  }

  /// Loudness, as a value that is high when the track is "fully playing".
  /// 90th percentile of the energy curve, ignoring silence.
  double get loudDb {
    final values = energyDb.where((e) => e > -70).toList()..sort();
    if (values.isEmpty) return -70;
    return values[((values.length - 1) * 0.9).round()];
  }

  /// Energy curve smoothed over [windowMs].
  List<double> smoothedEnergy({double windowMs = 1000}) {
    final half = max(0, (windowMs / frameMs / 2).round());
    final out = List<double>.filled(energyDb.length, -120);
    for (var i = 0; i < energyDb.length; i++) {
      var sum = 0.0;
      var n = 0;
      for (var j = max(0, i - half); j <= min(energyDb.length - 1, i + half); j++) {
        // average in linear power, convert back to dB
        sum += pow(10, energyDb[j] / 10);
        n++;
      }
      out[i] = 10 * log(max(1e-12, sum / n)) / ln10;
    }
    return out;
  }

  double timeOfFrame(int i) => startMs + i * frameMs;

  factory AutoMixRegion.fromMap(Map<dynamic, dynamic> map) {
    List<double> list(dynamic v) => (v as List<dynamic>? ?? const []).map((e) => (e as num).toDouble()).toList();
    return AutoMixRegion(
      startMs: (map["startMs"] as num).toDouble(),
      lengthMs: (map["lengthMs"] as num).toDouble(),
      bpm: (map["bpm"] as num).toDouble(),
      beatPeriodMs: (map["beatPeriodMs"] as num).toDouble(),
      firstBeatMs: (map["firstBeatMs"] as num).toDouble(),
      downbeatIndex: (map["downbeatIndex"] as num).toInt(),
      confidence: (map["confidence"] as num).toDouble(),
      energyRate: (map["energyRate"] as num).toDouble(),
      energyDb: list(map["energyDb"]),
      lowEnergyDb: list(map["lowEnergyDb"]),
      vocalDb: list(map["vocalEnergyDb"]),
    );
  }

  Map<String, dynamic> toMap() => {
    "startMs": startMs,
    "lengthMs": lengthMs,
    "bpm": bpm,
    "beatPeriodMs": beatPeriodMs,
    "firstBeatMs": firstBeatMs,
    "downbeatIndex": downbeatIndex,
    "confidence": confidence,
    "energyRate": energyRate,
    "energyDb": energyDb.map((e) => double.parse(e.toStringAsFixed(1))).toList(),
    "lowEnergyDb": lowEnergyDb.map((e) => double.parse(e.toStringAsFixed(1))).toList(),
    "vocalEnergyDb": vocalDb.map((e) => double.parse(e.toStringAsFixed(1))).toList(),
  };

  /// Rough "someone is singing/rapping" detector, per energy frame.
  /// Voice-band share of the total energy, compared to its typical value in this region,
  /// smoothed over ~0.6 s. Returns an empty list when there's no voice band data.
  List<bool> vocalActivity() {
    final n = min(vocalDb.length, energyDb.length);
    if (n < 20) return const [];
    final loud = loudDb;
    final ratio = [for (var i = 0; i < n; i++) vocalDb[i] - energyDb[i]];
    final sorted = [...ratio]..sort();
    // baseline: the voice share in the least "vocal" tenth of the region (instrumental parts)
    final baseline = sorted[(sorted.length * 0.1).floor()];
    final half = max(1, (300 / frameMs).round());
    final out = List<bool>.filled(n, false);
    for (var i = 0; i < n; i++) {
      var sum = 0.0;
      var c = 0;
      for (var j = max(0, i - half); j <= min(n - 1, i + half); j++) {
        sum += ratio[j];
        c++;
      }
      final r = sum / c;
      // voice band clearly above its usual share, and the track is reasonably loud
      out[i] = r > baseline + 4 && vocalDb[i] > loud - 22 && energyDb[i] > loud - 20;
    }
    return out;
  }

  /// Time (ms) of the end of the last vocal phrase in this region, or null.
  /// A phrase must last at least [minPhraseMs] to count.
  double? lastVocalEndMs({double minPhraseMs = 1200}) {
    final act = vocalActivity();
    var run = 0;
    for (var i = act.length - 1; i >= 0; i--) {
      if (act[i]) {
        run++;
        if (run * frameMs >= minPhraseMs) {
          // walk forward to the end of this phrase
          var j = i;
          while (j + 1 < act.length && act[j + 1]) {
            j++;
          }
          return timeOfFrame(j + 1);
        }
      } else {
        run = 0;
      }
    }
    return null;
  }

  /// Time (ms) of the start of the first vocal phrase at or after [fromMs], or null.
  double? firstVocalStartMs({double fromMs = 0, double minPhraseMs = 1200}) {
    final act = vocalActivity();
    var run = 0;
    for (var i = 0; i < act.length; i++) {
      if (timeOfFrame(i) < fromMs) continue;
      if (act[i]) {
        run++;
        if (run * frameMs >= minPhraseMs) return timeOfFrame(i - run + 1);
      } else {
        run = 0;
      }
    }
    return null;
  }
}

class AutoMixAnalysis {
  AutoMixAnalysis({required this.durationMs, required this.head, required this.tail, this.tailTiming});

  /// How the end region was positioned in time ("pts", "fin", "fichier complet"), for diagnostics.
  final String? tailTiming;

  final double? durationMs;
  final AutoMixRegion head;
  final AutoMixRegion? tail;

  static const int formatVersion = 3;

  factory AutoMixAnalysis.fromMap(Map<dynamic, dynamic> map) => AutoMixAnalysis(
    durationMs: (map["durationMs"] as num?)?.toDouble(),
    head: AutoMixRegion.fromMap(map["head"] as Map<dynamic, dynamic>),
    tail: map["tail"] == null ? null : AutoMixRegion.fromMap(map["tail"] as Map<dynamic, dynamic>),
    tailTiming: map["tailTiming"] as String?,
  );

  Map<String, dynamic> toMap() => {
    "version": formatVersion,
    "durationMs": durationMs,
    "head": head.toMap(),
    "tail": tail?.toMap(),
    "tailTiming": tailTiming,
  };
}

enum AutoMixMode {
  /// Tempo-matched, beat-aligned DJ style blend with a bass swap.
  beatmatch,

  /// Overlap during the outgoing fade-out / quiet intro, no beat alignment.
  blend,

  /// Short overlap at the very end, mostly removes silence between tracks.
  quick,
}

/// A planned transition. Times are track times (ms) of the respective track.
class AutoMixPlan {
  AutoMixPlan({
    required this.mode,
    required this.outMixStartMs,
    required this.outEndMs,
    required this.inStartMs,
    required this.incomingRate,
    this.outgoingRate = 1,
    this.beatRatio,
    this.vocalAligned = false,
    required this.bassSwapFraction,
    required this.inFadeFraction,
    required this.outFadeStartFraction,
    required this.outBeatPeriodMs,
    required this.inBeatPeriodMs,
    required this.description,
  });

  final AutoMixMode mode;

  /// Position in the outgoing track at which the incoming track starts.
  final double outMixStartMs;

  /// Position in the outgoing track at which it is silenced / stopped.
  final double outEndMs;

  /// Position in the incoming track at which it starts playing.
  final double inStartMs;

  /// Playback rate of the incoming track during the transition, relative to the
  /// user's speed (tempo matching). Ramped back to 1 after the transition.
  final double incomingRate;

  /// Playback rate the outgoing track ramps to before the incoming one starts (tempo ramp).
  final double outgoingRate;

  /// Incoming track time per outgoing track time while beats are locked (in beat / out beat).
  final double? beatRatio;

  /// The transition is placed so the incoming vocals start right after the outgoing ones end.
  final bool vocalAligned;

  /// Fraction (0..1) of the transition at which the low end is handed over from
  /// the outgoing track to the incoming one. null = no bass swap.
  final double? bassSwapFraction;

  /// Fraction of the transition over which the incoming volume rises to full.
  final double inFadeFraction;

  /// Fraction of the transition at which the outgoing volume starts to drop.
  final double outFadeStartFraction;

  /// Beat period of both tracks, used for phase correction (beatmatch only).
  final double? outBeatPeriodMs;
  final double? inBeatPeriodMs;

  final String description;

  /// Duration of the transition in outgoing track time.
  double get lengthMs => outEndMs - outMixStartMs;

  /// Gain (0..1) of the incoming track at transition progress [p] (0..1).
  double incomingGain(double p) {
    if (inFadeFraction <= 0) return 1;
    final x = (p / inFadeFraction).clamp(0.0, 1.0);
    return sin(x * pi / 2); // equal power
  }

  /// Gain (0..1) of the outgoing track at transition progress [p] (0..1).
  double outgoingGain(double p) {
    if (p <= outFadeStartFraction) return 1;
    final x = ((p - outFadeStartFraction) / max(1e-6, 1 - outFadeStartFraction)).clamp(0.0, 1.0);
    return cos(x * pi / 2);
  }

  /// Bass cut (0 = full bass, 1 = maximal cut) for the incoming track.
  double incomingBassCut(double p) {
    final swap = bassSwapFraction;
    if (swap == null) return 0;
    return _smoothStep(1 - (p - swap) / 0.04);
  }

  /// Bass cut (0 = full bass, 1 = maximal cut) for the outgoing track.
  double outgoingBassCut(double p) {
    final swap = bassSwapFraction;
    if (swap == null) {
      // blends: gently remove the outgoing low end in the second half
      if (mode == AutoMixMode.blend) return _smoothStep((p - 0.4) / 0.4);
      return 0;
    }
    return _smoothStep((p - swap) / 0.04);
  }

  static double _smoothStep(double x) {
    final t = x.clamp(0.0, 1.0);
    return t * t * (3 - 2 * t);
  }

  @override
  String toString() =>
      "AutoMixPlan($description: out ${outMixStartMs.round()}→${outEndMs.round()}ms, in from ${inStartMs.round()}ms, rates out ${outgoingRate.toStringAsFixed(3)} in ${incomingRate.toStringAsFixed(3)})";
}
