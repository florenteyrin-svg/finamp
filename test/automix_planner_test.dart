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
}) {
  const rate = 4.0;
  final n = (lengthMs / 1000 * rate).floor();
  final energy = [for (var i = 0; i < n; i++) energyAt(startMs + i * 1000 / rate)];
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
  );
}

AutoMixAnalysis track({
  required double durationMs,
  double bpm = 124,
  double confidence = 0.8,
  required double Function(double ms) energyAt,
}) {
  return AutoMixAnalysis(
    durationMs: durationMs,
    head: region(startMs: 0, lengthMs: 30000, bpm: bpm, confidence: confidence, energyAt: energyAt),
    tail: region(
      startMs: durationMs - 45000,
      lengthMs: 45000,
      bpm: bpm,
      confidence: confidence,
      firstBeatMs: 120,
      energyAt: energyAt,
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
    expect(plan.lengthMs, inInclusiveRange(2500, 9000));
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
    expect(plan.incomingBassCut(0.1), 1);
    expect(plan.incomingBassCut(0.9), 0);
    expect(plan.outgoingBassCut(0.1), 0);
    expect(plan.outgoingBassCut(0.9), 1);
  });

  test("serialisation round trip", () {
    final a = track(durationMs: 200000, energyAt: (ms) => -12);
    final b = AutoMixAnalysis.fromMap(a.toMap());
    expect(b.head.bpm, a.head.bpm);
    expect(b.tail!.startMs, a.tail!.startMs);
    expect(b.tail!.energyDb.length, a.tail!.energyDb.length);
  });
}
