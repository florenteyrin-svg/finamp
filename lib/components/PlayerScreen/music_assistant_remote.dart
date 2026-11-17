import 'dart:async';

import 'package:finamp/components/global_snackbar.dart';
import 'package:finamp/l10n/app_localizations.dart';
import 'package:finamp/services/music_assistant_service.dart';
import 'package:finamp/services/music_player_background_task.dart';
import 'package:finamp/services/queue_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:get_it/get_it.dart';

/// While the music plays on a Music Assistant player (Apple TV...): what it plays, previous / play-pause / next,
/// its volume, and "Resume on this phone", which stops it and carries on in Finamp at the same track and second.
class MusicAssistantRemote extends StatelessWidget {
  const MusicAssistantRemote({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<MusicAssistantPlayer?>(
      stream: MusicAssistantService.instance.activePlayer,
      builder: (context, snapshot) {
        final player = snapshot.data;
        if (player == null) return const SizedBox.shrink();
        return _Remote(key: ValueKey(player.id), player: player);
      },
    );
  }
}

class _Remote extends StatefulWidget {
  const _Remote({super.key, required this.player});

  final MusicAssistantPlayer player;

  @override
  State<_Remote> createState() => _RemoteState();
}

class _RemoteState extends State<_Remote> {
  final _service = MusicAssistantService.instance;
  MusicAssistantNowPlaying? _now;
  Timer? _timer;
  bool _busy = false;
  double? _volume;

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final now = await _service.nowPlaying(widget.player.id);
      if (mounted) setState(() => _now = now);
    } catch (e) {
      _service.log(e);
    }
  }

  Future<void> _command(String name, [Map<String, Object?> args = const {}]) async {
    try {
      await _service.command(widget.player.id, name, args);
      await Future<void>.delayed(const Duration(milliseconds: 600));
      await _refresh();
    } catch (e) {
      GlobalSnackbar.message((context) => AppLocalizations.of(context)!.musicAssistantError(e.toString()));
    }
  }

  /// Stops the player and carries on in Finamp at the track and second it had reached.
  Future<void> _resumeHere() async {
    setState(() => _busy = true);
    try {
      final now = await _service.nowPlaying(widget.player.id);
      await _service.command(widget.player.id, "stop");
      final queueService = GetIt.instance<QueueService>();
      final audioHandler = GetIt.instance<MusicPlayerBackgroundTask>();
      final queue = queueService.getQueue();
      final upcoming = [?queue.currentTrack, ...queue.nextUp, ...queue.queue];
      final offset = now?.jellyfinId == null
          ? -1
          : upcoming.indexWhere((item) => item.baseItemId.raw == now!.jellyfinId);
      if (offset > 0) await queueService.skipByOffset(offset);
      if (offset >= 0 && now != null) await audioHandler.seek(now.position);
      await audioHandler.play();
      _service.activePlayer.add(null);
    } catch (e) {
      GlobalSnackbar.message((context) => AppLocalizations.of(context)!.musicAssistantError(e.toString()));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final now = _now;
    final volume = _volume ?? now?.volume?.toDouble();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 6),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 10, 8, 6),
        decoration: BoxDecoration(
          color: (IconTheme.of(context).color ?? Colors.white).withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(
                  widget.player.name.toLowerCase().contains("tv") ? TablerIcons.device_tv : TablerIcons.device_speaker,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.musicAssistantPlayingOn(widget.player.name),
                        style: theme.textTheme.labelMedium,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (now?.title != null)
                        Text(
                          [now!.title, now.artist].nonNulls.join(" · "),
                          style: theme.textTheme.bodySmall,
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: l10n.musicAssistantForget,
                  icon: const Icon(TablerIcons.x, size: 18),
                  onPressed: () => _service.activePlayer.add(null),
                ),
              ],
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                IconButton(icon: const Icon(TablerIcons.player_skip_back), onPressed: () => _command("previous")),
                IconButton.filledTonal(
                  icon: Icon(now?.playing ?? true ? TablerIcons.player_pause : TablerIcons.player_play),
                  onPressed: () => _command("play_pause"),
                ),
                IconButton(icon: const Icon(TablerIcons.player_skip_forward), onPressed: () => _command("next")),
              ],
            ),
            if (volume != null)
              Row(
                children: [
                  const Icon(TablerIcons.volume, size: 18),
                  Expanded(
                    child: Slider(
                      value: volume.clamp(0, 100),
                      max: 100,
                      onChanged: (value) => setState(() => _volume = value),
                      onChangeEnd: (value) async {
                        await _command("volume_set", {"volume_level": value.round()});
                        if (mounted) setState(() => _volume = null);
                      },
                    ),
                  ),
                ],
              ),
            SizedBox(
              width: double.infinity,
              child: TextButton.icon(
                icon: _busy
                    ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(TablerIcons.device_mobile),
                label: Text(l10n.musicAssistantResumeHere),
                onPressed: _busy ? null : _resumeHere,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
