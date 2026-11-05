import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:logging/logging.dart';

import '../../models/finamp_models.dart';
import 'automix_analysis_service.dart';
import 'automix_models.dart';
import 'automix_planner.dart';

class _Cancelled implements Exception {}

/// Hooks the engine needs from the main player wrapper.
class AutoMixHost {
  AutoMixHost({
    required this.player,
    required this.mainEqualizer,
    required this.baseVolume,
    required this.setMixVolume,
    required this.isAllowed,
    required this.keepAlbumsGapless,
    required this.allowTempoChange,
    required this.onHoldChanged,
  });

  final AudioPlayer player;

  /// Equalizer in the main player's pipeline (used for the bass swap), if any.
  final AndroidEqualizer? mainEqualizer;

  /// Effective volume of the main player (user volume × replay gain × fades), without the mix factor.
  final double Function() baseVolume;

  /// Extra volume factor applied to the main player during a transition.
  final Future<void> Function(double) setMixVolume;

  /// Whether a transition may happen right now (setting enabled, no sleep timer ending, ...).
  final bool Function() isAllowed;
  final bool Function() keepAlbumsGapless;
  final bool Function() allowTempoChange;

  /// Called when the main player is intentionally paused (or no longer) while the incoming track waits for its cue.
  final void Function() onHoldChanged;
}

/// "AutoMix": DJ style transitions between consecutive tracks.
///
/// How it works: shortly before the transition, a second player (the overlay)
/// starts playing the *outgoing* track in sync with the main player, silently.
/// The main player then hands the outgoing track over to the overlay, jumps to
/// the next queue item (so Finamp's queue, UI and reporting work as usual),
/// waits for the right beat and starts the incoming track. Volumes, the low end
/// (equalizer) and the incoming tempo are automated until the overlay stops.
class AutoMixEngine {
  AutoMixEngine(this._host) {
    _analysis.onProgress = (p) => _status("Analyse : $p");
    _subscriptions.add(_host.player.sequenceStateStream.listen((_) => _onSequenceChanged()));
    _subscriptions.add(_host.player.positionStream.listen(_onPosition));
    _subscriptions.add(_host.player.loopModeStream.listen((_) => _onSequenceChanged()));
  }

  static final _logger = Logger("AutoMix");

  /// Human readable (French) status, shown in the settings to help diagnose problems.
  static final status = ValueNotifier<String>("En attente d'un morceau");

  /// Recent AutoMix events (newest last), shown in the settings.
  static final log = ValueNotifier<List<String>>(const []);

  static void _status(String text) {
    final line = "${DateTime.now().toIso8601String().substring(11, 19)} · $text";
    status.value = line;
    final lines = [...log.value, line];
    log.value = lines.length > 80 ? lines.sublist(lines.length - 80) : lines;
  }

  /// Adds a line to the log without changing the headline status.
  static void _trace(String text) {
    final line = "${DateTime.now().toIso8601String().substring(11, 19)} · $text";
    final lines = [...log.value, line];
    log.value = lines.length > 80 ? lines.sublist(lines.length - 80) : lines;
  }

  final AutoMixHost _host;
  final _analysis = AutoMixAnalysisService();
  final _subscriptions = <StreamSubscription<dynamic>>[];

  AudioPlayer get _main => _host.player;

  AudioPlayer? _overlay;
  AndroidEqualizer? _overlayEq;

  /// Incremented to cancel any running transition.
  int _generation = 0;

  _PlannedTransition? _planned;
  String? _planKey;
  bool _running = false;
  bool _tooLateReported = false;
  bool _holding = false;
  Timer? _speedRamp;
  double? _restoreSpeed;

  /// True while the main player is paused on purpose (incoming track waiting for its cue).
  bool get holdsPlayback => _holding;

  /// True while a transition is in progress.
  bool get isTransitioning => _running;

  AutoMixPlan? get currentPlan => _planned?.plan;

  void dispose() {
    for (final s in _subscriptions) {
      s.cancel();
    }
    _overlay?.dispose();
  }

  // ---------------------------------------------------------------------------
  // Planning
  // ---------------------------------------------------------------------------

  void _onSequenceChanged() {
    final current = _main.currentIndex;
    final next = _main.loopMode == LoopMode.one ? null : _main.nextIndex;
    final sources = _main.audioSources;
    if (current == null || current >= sources.length) {
      _planned = null;
      _planKey = null;
      return;
    }
    final key = "$current:${_idOf(sources[current])}>$next:${next == null ? "" : _idOf(sources[next])}";
    if (key == _planKey) return;
    _planKey = key;
    _planned = null;
    _tooLateReported = false;
    if (next == null || next >= sources.length) {
      _logger.info("No next track (or repeat one), nothing to mix");
      _status("Pas de morceau suivant dans la file (ou répétition d'un titre)");
      return;
    }
    _logger.info("Preparing transition for queue position $current → $next");
    _status("Analyse du morceau actuel et du suivant…");
    unawaited(_prepare(key, sources[current], sources[next], next));
  }

  Future<void> _prepare(String key, AudioSource current, AudioSource next, int nextIndex) async {
    final outItem = _queueItemOf(current);
    final inItem = _queueItemOf(next);
    final outUri = _uriOf(current);
    final inUri = _uriOf(next);
    if (outItem == null || inItem == null || outUri == null || inUri == null) {
      _logger.warning("Unsupported audio source, can't mix");
      _status("Source audio non prise en charge");
      return;
    }

    if (_host.keepAlbumsGapless() && _isAlbumContinuation(outItem, inItem)) {
      _logger.info("Next track continues the album, keeping gapless playback");
      _status("Morceau suivant = suite de l'album → pas de mix (réglage « Albums sans mix »)");
      return;
    }

    final outId = _itemId(outItem);
    final inId = _itemId(inItem);
    if (outId == null || inId == null) return;

    // analyse outgoing first (its end is needed soonest), then incoming
    _trace("Morceau actuel : ${outItem.item.title} (${_describeUri(outUri)})");
    final outAnalysis = await _analysis.analyze(
      outId,
      _analysisUri(outUri),
      durationMs: outItem.item.duration?.inMilliseconds.toDouble(),
    );
    _trace(outAnalysis == null ? "Analyse du morceau actuel : échec" : "Analyse du morceau actuel : OK ${_describe(outAnalysis)}");
    _trace("Morceau suivant : ${inItem.item.title}");
    final inAnalysis = await _analysis.analyze(
      inId,
      _analysisUri(inUri),
      durationMs: inItem.item.duration?.inMilliseconds.toDouble(),
    );
    _trace(inAnalysis == null ? "Analyse du morceau suivant : échec" : "Analyse du morceau suivant : OK ${_describe(inAnalysis)}");
    if (key != _planKey) return; // queue changed meanwhile
    if (outAnalysis == null || inAnalysis == null) {
      _logger.info("No analysis available, keeping gapless playback");
      _status(
        "Échec de l'analyse (${outAnalysis == null ? "morceau actuel" : "morceau suivant"}) : "
        "${_analysis.lastError ?? "?"}",
      );
      return;
    }
    final plan = AutoMixPlanner(
      allowTempoChange: _host.allowTempoChange(),
    ).plan(outgoing: outAnalysis, incoming: inAnalysis, outDurationMs: _main.duration?.inMilliseconds.toDouble());
    if (plan == null) {
      _logger.info("No suitable transition found, keeping gapless playback");
      _status("Aucune transition adaptée trouvée → enchaînement normal");
      return;
    }
    _logger.info("Planned: $plan");
    _status("Prêt : ${plan.description}, à ${_fmt(plan.outMixStartMs)} du morceau");
    _planned = _PlannedTransition(
      plan: plan,
      outUri: outUri,
      nextIndex: nextIndex,
      nextId: inId,
      outTag: current is UriAudioSource ? current.tag : null,
    );
  }

  // ---------------------------------------------------------------------------
  // Triggering
  // ---------------------------------------------------------------------------

  static const _overlayLeadMs = 2000.0; // overlay plays in sync before the handoff
  static const _handoffLeadMs = 3500.0; // handoff happens this long before the mix point
  static const _prepareLeadMs = 3000.0; // overlay gets loaded this long before it starts

  void _onPosition(Duration position) {
    final planned = _planned;
    if (planned == null || _running) return;
    if (!_main.playing || _main.processingState != ProcessingState.ready) return;
    final pos = position.inMilliseconds.toDouble();
    final mixStart = planned.plan.outMixStartMs;
    final startAt = mixStart - _handoffLeadMs - _overlayLeadMs - _prepareLeadMs;
    if (pos < startAt) return;
    // time left before the mix point; shorter leads when the user jumped close to the end
    final available = mixStart - pos;
    if (available < 3200) {
      // too late for a clean, synchronised handoff
      if (!_tooLateReported) {
        _tooLateReported = true;
        _status("Trop tard pour mixer ce morceau (saut trop près de la fin)");
      }
      return;
    }
    final handoffLead = min(_handoffLeadMs, max(1500.0, (available - 1200) * 0.55));
    final overlayLead = min(_overlayLeadMs, max(500.0, available - 1200 - handoffLead));
    if (!_host.isAllowed()) return;
    // the queue must still be what we planned for
    if (_main.nextIndex != planned.nextIndex || _main.loopMode == LoopMode.one) {
      _planned = null;
      _planKey = null;
      _onSequenceChanged();
      return;
    }
    _running = true;
    final generation = ++_generation;
    unawaited(_run(planned, generation, handoffLead: handoffLead, overlayLead: overlayLead));
  }

  // ---------------------------------------------------------------------------
  // The transition itself
  // ---------------------------------------------------------------------------

  void _check(int generation) {
    if (generation != _generation) throw _Cancelled();
  }

  Future<void> _ensureOverlay() async {
    if (_overlay != null) return;
    _overlayEq = _host.mainEqualizer != null ? AndroidEqualizer() : null;
    _overlay = AudioPlayer(
      handleInterruptions: false,
      handleAudioSessionActivation: false,
      audioPipeline: AudioPipeline(androidAudioEffects: [if (_overlayEq != null) _overlayEq!]),
    );
  }

  Future<void> _run(
    _PlannedTransition planned,
    int gen, {
    required double handoffLead,
    required double overlayLead,
  }) async {
    final plan = planned.plan;
    final speed = _main.speed;
    _restoreSpeed = speed;
    _speedRamp?.cancel();
    final handoffAt = plan.outMixStartMs - handoffLead;
    final overlayStart = handoffAt - overlayLead;
    _logger.info("Starting transition: $plan");
    _status("Transition en cours : ${plan.description}");
    var handedOff = false;
    try {
      // 1. load the outgoing track in the overlay player, paused just before the sync point
      await _ensureOverlay();
      final overlay = _overlay!;
      await overlay.setVolume(0);
      await overlay.setSpeed(speed);
      await overlay.setAudioSource(
        AudioSource.uri(planned.outUri, tag: planned.outTag),
        initialPosition: Duration(milliseconds: overlayStart.round()),
        preload: true,
      );
      _check(gen);
      final eqMain = _host.mainEqualizer;
      final eqOverlay = _overlayEq;
      final bassMain = eqMain == null ? null : await _BassControl.create(eqMain);
      final bassOverlay = eqOverlay == null ? null : await _BassControl.create(eqOverlay);
      _check(gen);

      // 2. start the overlay exactly when the main player reaches the same position
      await _waitForMainPosition(overlayStart, gen);
      unawaited(overlay.play());
      await _delay(min(300, overlayLead / 2), gen);
      if (overlayLead >= 1200) await _syncOverlayToMain(overlay, speed, gen);

      // 3. handoff: main → overlay (same audio, so a very short crossfade is inaudible)
      await _waitForMainPosition(handoffAt, gen);
      final outVolume = _host.baseVolume();
      for (var k = 1; k <= 4; k++) {
        await overlay.setVolume(outVolume * k / 4);
        await _host.setMixVolume(1 - k / 4);
        await _delay(15, gen);
      }
      _setHolding(true);
      handedOff = true;
      await _main.pause();
      await _main.seek(Duration(milliseconds: plan.inStartMs.round()), index: planned.nextIndex);
      // let the player report its new (buffering) state before polling it
      await _delay(120, gen);
      final incomingSpeed = speed * plan.incomingRate;
      if (incomingSpeed != speed) await _main.setSpeed(incomingSpeed);
      await bassMain?.setCut(plan.incomingBassCut(0));
      await bassOverlay?.setCut(plan.outgoingBassCut(0));

      // 4. wait until the incoming track is buffered, then start it on the cue
      final ready = await _waitUntil(
        () => _main.processingState == ProcessingState.ready,
        gen,
        until: () => overlay.position.inMilliseconds > plan.outMixStartMs - 60,
      );
      _check(gen);
      if (!ready) {
        _logger.warning("Incoming track not ready in time, falling back to a simple fade");
        await _lateEntry(planned, overlay, outVolume, speed, gen, bassMain, bassOverlay);
        return;
      }
      final cueDelay = (plan.outMixStartMs - overlay.position.inMilliseconds) / speed;
      if (cueDelay > 0) await _delay(cueDelay, gen);
      unawaited(_main.play());
      _setHolding(false);

      // 5. automate volumes, bass and tempo until the outgoing track is gone
      final startedAt = DateTime.now();
      var lastPhaseFix = DateTime.now();
      while (true) {
        _check(gen);
        final outPos = overlay.position.inMilliseconds.toDouble();
        final p = ((outPos - plan.outMixStartMs) / max(1, plan.lengthMs)).clamp(0.0, 1.0);
        if (p >= 1 || !overlay.playing || overlay.processingState == ProcessingState.completed) break;
        await overlay.setVolume(outVolume * plan.outgoingGain(p));
        await _host.setMixVolume(plan.incomingGain(p));
        await bassMain?.setCut(plan.incomingBassCut(p));
        await bassOverlay?.setCut(plan.outgoingBassCut(p));

        if (plan.mode == AutoMixMode.beatmatch &&
            DateTime.now().difference(startedAt).inMilliseconds > 250 &&
            DateTime.now().difference(lastPhaseFix).inMilliseconds >= 200) {
          lastPhaseFix = DateTime.now();
          await _fixPhase(plan, overlay, incomingSpeed);
        }
        await _delay(40, gen);
      }

      // 6. done: silence the overlay, give the main player its normal state back
      await _host.setMixVolume(1);
      await overlay.setVolume(0);
      await overlay.pause();
      await bassMain?.reset();
      await bassOverlay?.reset();
      _logger.info("Transition finished");
      _status("Transition terminée (${plan.description})");
      _rampSpeedBack(from: _main.speed, to: speed);
      unawaited(overlay.stop());
    } on _Cancelled {
      _logger.info("Transition cancelled");
      _status("Transition annulée");
      if (gen == _generation) {
        // cancelled by ourselves (e.g. playback paused before the handoff): silence the overlay
        try {
          await _overlay?.setVolume(0);
          await _overlay?.pause();
        } catch (_) {}
        if (handedOff) await _cleanup(resumeMain: false);
      }
    } catch (e, st) {
      _logger.warning("Transition failed: $e", e, st);
      _status("Erreur pendant la transition : $e");
      await _cleanup(resumeMain: _holding);
    } finally {
      if (gen == _generation) {
        _running = false;
        _setHolding(false);
      }
      // keep the plan if we never touched the main player (e.g. paused just before), so it can be retried
      if (handedOff && identical(_planned, planned)) _planned = null;
    }
  }

  /// The incoming track was not buffered on time: start it as soon as possible with a fade.
  Future<void> _lateEntry(
    _PlannedTransition planned,
    AudioPlayer overlay,
    double outVolume,
    double speed,
    int gen,
    _BassControl? bassMain,
    _BassControl? bassOverlay,
  ) async {
    await _main.setSpeed(speed);
    await bassMain?.reset();
    await _waitUntil(() => _main.processingState == ProcessingState.ready, gen, maxMs: 15000);
    await _host.setMixVolume(0);
    unawaited(_main.play());
    _setHolding(false);
    const steps = 50; // 2 s
    for (var k = 1; k <= steps; k++) {
      _check(gen);
      final p = k / steps;
      await _host.setMixVolume(sin(p * pi / 2));
      await overlay.setVolume(outVolume * cos(p * pi / 2));
      await _delay(40, gen);
    }
    await overlay.pause();
    await bassOverlay?.reset();
    await _host.setMixVolume(1);
  }

  /// Keeps the incoming beats on top of the outgoing ones by slightly nudging the incoming tempo.
  Future<void> _fixPhase(AutoMixPlan plan, AudioPlayer overlay, double incomingSpeed) async {
    if (!_main.playing || _main.processingState != ProcessingState.ready) return;
    final period = plan.inBeatPeriodMs;
    if (period == null) return;
    final outPos = overlay.position.inMilliseconds.toDouble();
    final expected = plan.inStartMs + (outPos - plan.outMixStartMs) * plan.incomingRate;
    var error = _main.position.inMilliseconds - expected;
    // only the phase within a beat matters
    error = error - period * (error / period).roundToDouble();
    double target = incomingSpeed;
    if (error.abs() > 8) {
      // remove the error over ~1.2 s, never more than 3 % tempo change
      target = incomingSpeed * (1 - (error / 1200).clamp(-0.03, 0.03));
    }
    if ((target - _main.speed).abs() > 0.0005) await _main.setSpeed(target);
  }

  Future<void> _syncOverlayToMain(AudioPlayer overlay, double speed, int gen) async {
    for (var i = 0; i < 4; i++) {
      final diff = (_main.position - overlay.position).inMilliseconds;
      if (diff.abs() <= 10) break;
      // catch up within ~350 ms
      final nudge = (diff / 350).clamp(-0.1, 0.1);
      await overlay.setSpeed(speed * (1 + nudge));
      await _delay(350, gen);
      await overlay.setSpeed(speed);
      await _delay(60, gen);
    }
  }

  void _rampSpeedBack({required double from, required double to}) {
    _speedRamp?.cancel();
    if ((from - to).abs() < 0.0005) {
      unawaited(_main.setSpeed(to));
      _restoreSpeed = null;
      return;
    }
    const steps = 40; // 8 s
    var k = 0;
    _speedRamp = Timer.periodic(const Duration(milliseconds: 200), (t) {
      k++;
      final v = from + (to - from) * (k / steps);
      unawaited(_main.setSpeed(k >= steps ? to : v));
      if (k >= steps) {
        t.cancel();
        _restoreSpeed = null;
      }
    });
  }

  // ---------------------------------------------------------------------------
  // Cancelling
  // ---------------------------------------------------------------------------

  /// Stops any transition immediately. If [resumeMain] is true and the main
  /// player was waiting for its cue, it starts playing right away.
  Future<void> abort({bool resumeMain = true, String reason = ""}) async {
    if (!_running && _speedRamp == null && _restoreSpeed == null) return;
    _logger.info("Aborting transition ($reason)");
    _generation++;
    _running = false;
    await _cleanup(resumeMain: resumeMain && _holding);
  }

  Future<void> _cleanup({required bool resumeMain}) async {
    final wasHolding = _holding;
    _setHolding(false);
    _speedRamp?.cancel();
    _speedRamp = null;
    final restore = _restoreSpeed;
    _restoreSpeed = null;
    try {
      await _overlay?.setVolume(0);
      await _overlay?.pause();
    } catch (_) {}
    await _host.setMixVolume(1);
    try {
      await _host.mainEqualizer?.setEnabled(false);
      await _overlayEq?.setEnabled(false);
    } catch (_) {}
    if (restore != null && _main.speed != restore) await _main.setSpeed(restore);
    if (resumeMain && wasHolding) unawaited(_main.play());
  }

  /// Call before the user changes the speed, so the ramp does not override it.
  void forgetSpeed() {
    _speedRamp?.cancel();
    _speedRamp = null;
    _restoreSpeed = null;
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  void _setHolding(bool value) {
    if (_holding == value) return;
    _holding = value;
    _host.onHoldChanged();
  }

  Future<void> _delay(num ms, int gen) async {
    if (ms > 0) await Future<void>.delayed(Duration(microseconds: (ms * 1000).round()));
    _check(gen);
  }

  /// Sleeps until the main player reaches [targetMs] (track time), with ~ms precision.
  Future<void> _waitForMainPosition(double targetMs, int gen) async {
    while (true) {
      _check(gen);
      if (!_main.playing) throw _Cancelled();
      final remaining = (targetMs - _main.position.inMilliseconds) / max(0.1, _main.speed);
      if (remaining <= 1) return;
      await _delay(remaining > 60 ? remaining - 30 : remaining, gen);
    }
  }

  /// Polls [condition] until true. Returns false if [until] becomes true or [maxMs] elapses first.
  Future<bool> _waitUntil(bool Function() condition, int gen, {bool Function()? until, int maxMs = 20000}) async {
    final sw = Stopwatch()..start();
    while (!condition()) {
      if ((until?.call() ?? false) || sw.elapsedMilliseconds > maxMs) return false;
      await _delay(15, gen);
    }
    return true;
  }

  static String _describe(AutoMixAnalysis a) {
    final h = a.head;
    final t = a.tail;
    return "(début ${h.bpm.toStringAsFixed(0)} BPM ${(h.confidence * 100).round()} %"
        "${t == null ? "" : ", fin ${t.bpm.toStringAsFixed(0)} BPM ${(t.confidence * 100).round()} %"})";
  }

  static String _describeUri(Uri uri) {
    if (uri.isScheme("file")) return "fichier téléchargé";
    if (uri.path.endsWith("main.m3u8")) return "streaming transcodé";
    return "streaming direct";
  }

  static String _fmt(double ms) {
    final t = (ms / 1000).round();
    return "${t ~/ 60}:${(t % 60).toString().padLeft(2, "0")}";
  }

  static FinampQueueItem? _queueItemOf(AudioSource source) {
    if (source is UriAudioSource && source.tag is FinampQueueItem) return source.tag as FinampQueueItem;
    return null;
  }

  static Uri? _uriOf(AudioSource source) => source is UriAudioSource ? source.uri : null;

  static String? _idOf(AudioSource source) => _queueItemOf(source)?.id;

  static Map<String, dynamic>? _itemJson(FinampQueueItem item) =>
      item.item.extras?["itemJson"] as Map<String, dynamic>?;

  static String? _itemId(FinampQueueItem item) => _itemJson(item)?["Id"] as String?;

  static bool _isAlbumContinuation(FinampQueueItem a, FinampQueueItem b) {
    final ja = _itemJson(a);
    final jb = _itemJson(b);
    if (ja == null || jb == null) return false;
    if (ja["AlbumId"] == null || ja["AlbumId"] != jb["AlbumId"]) return false;
    final ia = ja["IndexNumber"] as int?;
    final ib = jb["IndexNumber"] as int?;
    final da = ja["ParentIndexNumber"] as int? ?? 1;
    final db = jb["ParentIndexNumber"] as int? ?? 1;
    if (ia == null || ib == null) return false;
    return (da == db && ib == ia + 1) || (db == da + 1 && ib == 1);
  }

  /// Transcoded streams (HLS) can't be decoded by the analyzer: use the original file instead.
  static Uri _analysisUri(Uri uri) {
    if (!uri.path.endsWith("main.m3u8")) return uri;
    final segments = uri.pathSegments.toList();
    final audioIdx = segments.lastIndexOf("Audio");
    if (audioIdx < 0 || audioIdx + 1 >= segments.length) return uri;
    final id = segments[audioIdx + 1];
    return uri.replace(
      pathSegments: [...segments.sublist(0, audioIdx), "Items", id, "File"],
      queryParameters: {if (uri.queryParameters["ApiKey"] != null) "ApiKey": uri.queryParameters["ApiKey"]!},
    );
  }
}

class _PlannedTransition {
  _PlannedTransition({
    required this.plan,
    required this.outUri,
    required this.nextIndex,
    required this.nextId,
    required this.outTag,
  });

  final AutoMixPlan plan;
  final Uri outUri;
  final int nextIndex;
  final String nextId;
  final dynamic outTag;
}

/// Turns the low bands of an [AndroidEqualizer] down (0 = flat, 1 = bass removed).
class _BassControl {
  _BassControl._(this._eq, this._bands, this._minDb);

  final AndroidEqualizer _eq;
  final List<(AndroidEqualizerBand, double)> _bands; // band, weight
  final double _minDb;
  double _current = -1;
  bool _enabled = false;

  static Future<_BassControl?> create(AndroidEqualizer eq) async {
    try {
      final params = await eq.parameters.timeout(const Duration(seconds: 2));
      final bands = <(AndroidEqualizerBand, double)>[];
      for (final band in params.bands) {
        final f = band.centerFrequency;
        if (f <= 150) {
          bands.add((band, 1.0));
        } else if (f <= 400) {
          bands.add((band, 0.6));
        } else if (f <= 1000) {
          bands.add((band, 0.1));
        }
      }
      if (bands.isEmpty) return null;
      // don't go all the way down, a full cut sounds hollow on some devices
      return _BassControl._(eq, bands, max(params.minDecibels, -15));
    } catch (e) {
      Logger("AutoMix").warning("Equalizer unavailable: $e");
      return null;
    }
  }

  Future<void> setCut(double amount) async {
    final a = amount.clamp(0.0, 1.0);
    if ((a - _current).abs() < 0.04 && !(a == 0 && _current != 0) && !(a == 1 && _current != 1)) return;
    _current = a;
    if (a > 0 && !_enabled) {
      await _eq.setEnabled(true);
      _enabled = true;
    }
    for (final (band, weight) in _bands) {
      await band.setGain(_minDb * a * weight);
    }
  }

  Future<void> reset() async {
    for (final (band, _) in _bands) {
      await band.setGain(0);
    }
    await _eq.setEnabled(false);
    _enabled = false;
    _current = 0;
  }
}
