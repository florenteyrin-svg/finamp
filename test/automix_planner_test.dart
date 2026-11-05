import 'package:finamp/services/automix/automix_models.dart';
import 'package:finamp/services/automix/automix_planner.dart';
import 'package:flutter_test/flutter_test.dart';

/// Builds a region with an energy curve given by [energyAt] (time in ms → dB).
AutoMixRegion region({
  required double startMs,
  required double lengthMs,
  double bpm = 124,
  double confidence = 0.8,
  double firstBeatMs = 0,
  int downbeatIndex = 0,
  required double Function(double ms) energyAt,
  double Function(double ms)? vocalAt,
}) {
  const rate = 20.0;
  final n = (lengthMs / 1000 * rate).floor();
  final energy = [for (var i = 0; i < n; i++) energyAt(startMs + i * 1000 / rate)];
  final vocal = vocalAt == null ? <double>[] : [for (var i = 0; i < n; i++) vocalAt(startMs + i * 1000 / rate)];
  return AutoMixRegion(
    startMs: startMs,
    lengthMs: lengthMs,
    bpm: bpm,
    beatPeriodMs: bpm > 0 ? 60000 / bpm : 0,
    firstBeatMs: startMs + firstBeatMs,
    downbeatIndex: downbeatIndex,
    confidence: confidence,
    energyRate: rate,
    energyDb: energy,
    lowEnergyDb: energy,
    vocalDb: vocal,
  );
}

AutoMixAnalysis track({
  required double durationMs,
  double bpm = 124,
  double confidence = 0.8,
  required double Function(double ms) energyAt,
  double Function(double ms)? vocalAt,
}) {
  return AutoMixAnalysis(
    durationMs: durationMs,
    head: region(startMs: 0, lengthMs: 30000, bpm: bpm, confidence: confidence, energyAt: energyAt, vocalAt: vocalAt),
    tail: region(
      startMs: durationMs - 45000,
      lengthMs: 45000,
      bpm: bpm,
      confidence: confidence,
      firstBeatMs: 120,
      energyAt: energyAt,
      vocalAt: vocalAt,
    ),
  );
}

void main() {
  final planner = AutoMixPlanner();

  test("two house tracks at close tempos get a long beat matched mix", () {
    final out = track(durationMs: 300000, bpm: 124, energyAt: (ms) => ms < 299000 ? -12 : -90);
    final inc = track(durationMs: 280000, bpm: 122, energyAt: (ms) => -12);
    final plan = planner.plan(outgoing: out, incoming: inc, outDurationMs: 300000)!;
    expect(plan.mode, AutoMixMode.beatmatch);
    expect(plan.lengthMs, closeTo(16 * 60000 / 124, 1));
    expect(plan.incomingRate, closeTo(124 / 122, 1e-6));
    expect(plan.outEndMs, lessThanOrEqualTo(299000));
    // mix starts on a downbeat of the outgoing grid
    final bar = 4 * 60000 / 124;
    final offset = (plan.outMixStartMs - out.tail!.firstDownbeatMs) / bar;
    expect(offset, closeTo(offset.roundToDouble(), 1e-6));
  });

  test("half time tempos are matched (rap 87 BPM into 174 BPM)", () {
    final out = track(durationMs: 200000, bpm: 87, energyAt: (ms) => ms < 199000 ? -12 : -90);
    final inc = track(durationMs: 200000, bpm: 172, energyAt: (ms) => -12);
    final plan = planner.plan(outgoing: out, incoming: inc, outDurationMs: 200000)!;
    expect(plan.mode, AutoMixMode.beatmatch);
    expect(plan.incomingRate, closeTo(87 / 86, 1e-6));
  });

  test("very different tempos fall back to a blend when the outgoing track fades out", () {
    // fade out over the last 10 s
    double fade(double ms) => ms < 290000 ? -12 : -12 - (ms - 290000) / 10000 * 50;
    final out = track(durationMs: 300000, bpm: 95, energyAt: fade);
    final inc = track(durationMs: 200000, bpm: 140, energyAt: (ms) => -12);
    final plan = planner.plan(outgoing: out, incoming: inc, outDurationMs: 300000)!;
    expect(plan.mode, AutoMixMode.blend);
    expect(plan.incomingRate, 1);
    expect(plan.lengthMs, inInclusiveRange(6000, 10000));
  });

  test("hard ending and hard start: quick transition that removes silence", () {
    final out = track(durationMs: 180000, bpm: 100, confidence: 0.2, energyAt: (ms) => ms < 177000 ? -10 : -100);
    final inc = track(
      durationMs: 180000,
      bpm: 150,
      confidence: 0.2,
      energyAt: (ms) => ms < 800 ? -100 : -10,
    );
    final plan = planner.plan(outgoing: out, incoming: inc, outDurationMs: 180000)!;
    expect(plan.mode, AutoMixMode.quick);
    expect(plan.outEndMs, closeTo(177000, 300));
    expect(plan.inStartMs, inInclusiveRange(650, 800));
  });

  test("tempo matching can be turned off", () {
    final out = track(durationMs: 300000, bpm: 124, energyAt: (ms) => ms < 299000 ? -12 : -90);
    final inc = track(durationMs: 280000, bpm: 120, energyAt: (ms) => -12);
    final plan = AutoMixPlanner(allowTempoChange: false).plan(outgoing: out, incoming: inc, outDurationMs: 300000)!;
    expect(plan.mode, isNot(AutoMixMode.beatmatch));
  });

  test("gain curves", () {
    final out = track(durationMs: 300000, bpm: 124, energyAt: (ms) => ms < 299000 ? -12 : -90);
    final inc = track(durationMs: 280000, bpm: 124, energyAt: (ms) => -12);
    final plan = planner.plan(outgoing: out, incoming: inc, outDurationMs: 300000)!;
    expect(plan.incomingGain(0), 0);
    expect(plan.incomingGain(1), closeTo(1, 1e-9));
    expect(plan.outgoingGain(0), 1);
    expect(plan.outgoingGain(1), closeTo(0, 1e-9));
  });

  test("serialisation round trip", () {
    final a = track(durationMs: 200000, energyAt: (ms) => -12);
    final b = AutoMixAnalysis.fromMap(a.toMap());
    expect(b.head.bpm, a.head.bpm);
    expect(b.tail!.startMs, a.tail!.startMs);
    expect(b.tail!.energyDb.length, a.tail!.energyDb.length);
  });

  test("tempos 11 % apart: only the incoming track is synced (DJ sync), the playing one is untouched", () {
    final out = track(durationMs: 300000, bpm: 126, energyAt: (ms) => ms < 299000 ? -12 : -90);
    final inc = track(durationMs: 280000, bpm: 113, energyAt: (ms) => -12);
    final plan = planner.plan(outgoing: out, incoming: inc, outDurationMs: 300000)!;
    expect(plan.mode, AutoMixMode.beatmatch);
    expect(plan.outgoingRate, 1);
    expect(113 * plan.incomingRate, closeTo(126, 1e-6));
  });

  test("tempos more than 12 % apart are not synced", () {
    final out = track(durationMs: 300000, bpm: 110, energyAt: (ms) => ms < 299000 ? -12 : -90);
    final inc = track(durationMs: 280000, bpm: 126, energyAt: (ms) => -12);
    final plan = planner.plan(outgoing: out, incoming: inc, outDurationMs: 300000)!;
    expect(plan.mode, isNot(AutoMixMode.beatmatch));
  });

  test("vocal handover: incoming vocals land on the bar right after the outgoing vocals end", () {
    // outgoing: vocals until 280 s, then instrumental outro until 299 s
    final out = track(
      durationMs: 300000,
      bpm: 120,
      energyAt: (ms) => ms < 299000 ? -12 : -90,
      vocalAt: (ms) => ms < 280000 ? -13 : -30,
    );
    // incoming: 16 s instrumental intro, vocals from 16 s
    final inc = track(
      durationMs: 240000,
      bpm: 120,
      energyAt: (ms) => -12,
      vocalAt: (ms) => ms >= 16000 ? -13 : -30,
    );
    final plan = planner.plan(outgoing: out, incoming: inc, outDurationMs: 300000)!;
    expect(plan.mode, AutoMixMode.beatmatch);
    expect(plan.vocalAligned, isTrue);
    // time at which the incoming vocals are heard, in outgoing track time
    final inVocalAt = plan.outMixStartMs + (16000 - plan.inStartMs) / plan.beatRatio!;
    expect(inVocalAt, inInclusiveRange(280000, 280000 + 4 * 500 + 600));
    expect(plan.outEndMs, lessThan(299000));
  });

  test("vocal handover without a common tempo", () {
    final out = track(
      durationMs: 300000,
      bpm: 90,
      energyAt: (ms) => ms < 299000 ? -12 : -90,
      vocalAt: (ms) => ms < 285000 ? -13 : -30,
    );
    final inc = track(
      durationMs: 240000,
      bpm: 140,
      energyAt: (ms) => -12,
      vocalAt: (ms) => ms >= 6000 ? -13 : -30,
    );
    final plan = planner.plan(outgoing: out, incoming: inc, outDurationMs: 300000)!;
    expect(plan.mode, AutoMixMode.blend);
    expect(plan.vocalAligned, isTrue);
    final inVocalAt = plan.outMixStartMs + (6000 - plan.inStartMs);
    expect(inVocalAt, closeTo(285300, 400));
  });
}
