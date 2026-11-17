import 'dart:async';

import 'package:get_it/get_it.dart';
import 'package:rxdart/rxdart.dart';

import '../components/global_snackbar.dart';
import 'music_assistant_service.dart';
import 'music_player_background_task.dart';
import 'queue_service.dart';

/// "Casting" to a Music Assistant player (Apple TV...): while it is on, whatever starts playing in Finamp (an
/// album, a playlist, shuffle, next...) goes to the player instead of the phone. The phone's player stays muted
/// and paused; it only follows the queue, and each new start is handed over to Music Assistant.
class MusicAssistantCast {
  MusicAssistantCast._();
  static final instance = MusicAssistantCast._();

  final _service = MusicAssistantService.instance;
  StreamSubscription<void>? _subscription;

  /// Track last handed over, so pausing the phone after a hand-over does not send it again.
  String? _lastTrack;

  MusicAssistantPlayer? get player => _service.activePlayer.valueOrNull;
  bool get active => player != null;

  /// Sends what Finamp plays to [player] and keeps doing so for anything played next.
  Future<void> start(MusicAssistantPlayer player) async {
    final handler = GetIt.instance<MusicPlayerBackgroundTask>();
    final queueService = GetIt.instance<QueueService>();
    await handler.setCastMuted(true);
    _service.activePlayer.add(player);
    await _send(handler, queueService);
    await _subscription?.cancel();
    _subscription =
        Rx.combineLatest2<bool, String?, (bool, String?)>(
              handler.playbackState.map((state) => state.playing).distinct(),
              queueService.getCurrentTrackStream().map((item) => item?.baseItemId.raw).distinct(),
              (playing, trackId) => (playing, trackId),
            )
            .skip(1)
            .debounceTime(const Duration(milliseconds: 500))
            .asyncMap((event) async {
              final (playing, trackId) = event;
              if (trackId != null && trackId != _lastTrack) {
                // Something else started in Finamp (album, playlist, next...): hand it over to the player
                await _send(handler, queueService);
              } else if (playing) {
                // Finamp's own play button: resume the player where it is, the phone stays silent
                await handler.pause();
                final target = this.player; // null once casting stopped
                if (target != null) {
                  try {
                    await _service.command(target.id, "play");
                  } catch (e) {
                    _service.log(e);
                  }
                }
              }
            })
            .listen((_) {});
  }

  Future<void> _send(MusicPlayerBackgroundTask handler, QueueService queueService) async {
    final target = player;
    if (target == null) return;
    final queue = queueService.getQueue();
    final current = queue.currentTrack;
    if (current == null) return;
    _lastTrack = current.baseItemId.raw;
    final position = handler.playbackPosition;
    if (handler.playbackState.value.playing) await handler.pause();
    final ids = [
      current,
      ...queue.nextUp,
      ...queue.queue,
    ].map((item) => item.baseItemId.raw).where((id) => !id.startsWith("ext-")).take(300).toList();
    if (ids.isEmpty || current.baseItemId.raw.startsWith("ext-")) {
      GlobalSnackbar.message((_) => GlobalSnackbar.requireL10n.musicAssistantNotInLibrary);
      return;
    }
    try {
      await _service.play(target.id, ids, position);
    } catch (e) {
      _service.log(e);
      GlobalSnackbar.message((_) => GlobalSnackbar.requireL10n.musicAssistantError(e.toString()));
    }
  }

  /// Leaves casting: the player keeps playing, the phone is no longer muted.
  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;
    _service.activePlayer.add(null);
    await GetIt.instance<MusicPlayerBackgroundTask>().setCastMuted(false);
  }

  /// Stops the player and carries on in Finamp at the track and second it had reached.
  Future<void> resumeHere() async {
    final target = player;
    if (target == null) return;
    final now = await _service.nowPlaying(target.id);
    await _service.command(target.id, "stop");
    await _subscription?.cancel();
    _subscription = null;
    final queueService = GetIt.instance<QueueService>();
    final handler = GetIt.instance<MusicPlayerBackgroundTask>();
    final queue = queueService.getQueue();
    final upcoming = [?queue.currentTrack, ...queue.nextUp, ...queue.queue];
    final offset = now?.jellyfinId == null ? -1 : upcoming.indexWhere((item) => item.baseItemId.raw == now!.jellyfinId);
    if (offset > 0) await queueService.skipByOffset(offset);
    if (offset >= 0 && now != null) await handler.seek(now.position);
    _service.activePlayer.add(null);
    await handler.setCastMuted(false);
    await handler.play();
  }
}
