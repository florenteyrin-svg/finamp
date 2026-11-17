import 'dart:async';

import 'package:get_it/get_it.dart';

import '../components/global_snackbar.dart';
import 'music_assistant_service.dart';
import 'music_player_background_task.dart';
import 'queue_service.dart';

/// "Casting" to a Music Assistant player (Apple TV...).
///
/// The music plays on the player; the phone keeps playing the same queue **muted**, as a mirror, so the player
/// screen (title, cover, progress, queue), the notification, the widgets and Android Auto stay right and their
/// buttons work as a remote:
/// * play / pause / seek are forwarded to the player (MusicPlayerBackgroundTask.castForwarder);
/// * when the phone moves to another track (next, previous, an album, a playlist...), the queue from that track
///   is sent to the player, unless the player is already on it (the end of a track on both sides);
/// * every 3 seconds the mirror follows the player: same track, same position, same play state.
class MusicAssistantCast {
  MusicAssistantCast._();
  static final instance = MusicAssistantCast._();

  final _service = MusicAssistantService.instance;
  StreamSubscription<void>? _trackSubscription;
  Timer? _syncTimer;
  String? _lastSentTrack;

  MusicAssistantPlayer? get player => _service.activePlayer.valueOrNull;
  bool get active => player != null;

  MusicPlayerBackgroundTask get _handler => GetIt.instance<MusicPlayerBackgroundTask>();
  QueueService get _queueService => GetIt.instance<QueueService>();

  Future<void> start(MusicAssistantPlayer target) async {
    await _stopListening();
    await _handler.setCastMuted(true);
    _service.activePlayer.add(target);
    _handler.castForwarder = (command, args) => _service.command(target.id, command, args);
    await _sendQueue();
    if (!_handler.playbackState.value.playing) {
      _handler.suppressCastForward = true;
      try {
        await _handler.play();
      } finally {
        _handler.suppressCastForward = false;
      }
    }
    _trackSubscription = _queueService
        .getCurrentTrackStream()
        .map((item) => item?.baseItemId.raw)
        .distinct()
        .skip(1)
        .asyncMap((trackId) => _onLocalTrackChanged(trackId))
        .listen((_) {});
    _syncTimer = Timer.periodic(const Duration(seconds: 3), (_) => _follow());
  }

  /// The phone moved to another track: send the queue from there, unless the player already plays it.
  Future<void> _onLocalTrackChanged(String? trackId) async {
    final target = player;
    if (target == null || trackId == null || trackId == _lastSentTrack) return;
    try {
      final now = await _service.nowPlaying(target.id);
      if (now?.jellyfinId == trackId) {
        _lastSentTrack = trackId;
        return;
      }
    } catch (e) {
      _service.log(e);
    }
    await _sendQueue();
  }

  Future<void> _sendQueue() async {
    final target = player;
    if (target == null) return;
    final queue = _queueService.getQueue();
    final current = queue.currentTrack;
    if (current == null) return;
    _lastSentTrack = current.baseItemId.raw;
    if (current.baseItemId.raw.startsWith("ext-")) {
      GlobalSnackbar.message((_) => GlobalSnackbar.requireL10n.musicAssistantNotInLibrary);
      return;
    }
    final ids = [
      current,
      ...queue.nextUp,
      ...queue.queue,
    ].map((item) => item.baseItemId.raw).where((id) => !id.startsWith("ext-")).take(300).toList();
    try {
      await _service.play(target.id, ids, _handler.playbackPosition);
    } catch (e) {
      _service.log(e);
      GlobalSnackbar.message((_) => GlobalSnackbar.requireL10n.musicAssistantError(e.toString()));
    }
  }

  /// Makes the muted mirror follow the player (track, position, play state) without sending anything back.
  Future<void> _follow() async {
    final target = player;
    if (target == null) return;
    MusicAssistantNowPlaying? now;
    try {
      now = await _service.nowPlaying(target.id);
    } catch (e) {
      _service.log(e);
      return;
    }
    if (now == null || player == null) return;
    _handler.suppressCastForward = true;
    try {
      final queue = _queueService.getQueue();
      final localId = queue.currentTrack?.baseItemId.raw;
      if (now.jellyfinId != null && now.jellyfinId != localId) {
        final upcoming = [?queue.currentTrack, ...queue.nextUp, ...queue.queue];
        final offset = upcoming.indexWhere((item) => item.baseItemId.raw == now!.jellyfinId);
        if (offset > 0) {
          _lastSentTrack = now.jellyfinId;
          await _queueService.skipByOffset(offset);
        }
      }
      final drift = (_handler.playbackPosition - now.position).abs();
      if (drift > const Duration(seconds: 3)) await _handler.seek(now.position);
      final playing = _handler.playbackState.value.playing;
      if (now.playing && !playing) await _handler.play();
      if (!now.playing && playing) await _handler.pause();
    } finally {
      _handler.suppressCastForward = false;
    }
  }

  Future<void> _stopListening() async {
    await _trackSubscription?.cancel();
    _trackSubscription = null;
    _syncTimer?.cancel();
    _syncTimer = null;
    _handler.castForwarder = null;
  }

  /// Stops the player: "stop", then "pause" if it still plays (or "stop" is refused), checked each time.
  Future<void> _stopPlayer(MusicAssistantPlayer target) async {
    Object? lastError;
    for (final command in ["stop", "pause", "pause"]) {
      try {
        await _service.command(target.id, command);
      } catch (e) {
        lastError = e;
        _service.log("$command: $e");
      }
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      try {
        final now = await _service.nowPlaying(target.id);
        if (now == null || !now.playing) return;
      } catch (e) {
        lastError = e;
      }
    }
    GlobalSnackbar.message(
      (_) => GlobalSnackbar.requireL10n.musicAssistantError(lastError?.toString() ?? "${target.name} still playing"),
    );
  }

  /// Leaves casting: the player keeps playing, the phone pauses and is no longer muted.
  Future<void> stop() async {
    await _stopListening();
    _service.activePlayer.add(null);
    await _handler.pause();
    await _handler.setCastMuted(false);
  }

  /// Stops the player and carries on in Finamp, which is already at the same track and second.
  Future<void> resumeHere() async {
    final target = player;
    if (target == null) return;
    await _follow();
    await _stopListening();
    await _stopPlayer(target);
    _service.activePlayer.add(null);
    await _handler.setCastMuted(false);
    await _handler.play();
  }
}
