import 'dart:async';

import 'package:finamp/components/global_snackbar.dart';
import 'package:finamp/l10n/app_localizations.dart';
import 'package:finamp/services/music_assistant_service.dart';
import 'package:finamp/services/music_assistant_cast.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

/// While the music plays on a Music Assistant player (Apple TV...): which player and what it plays (Finamp's own
/// controls drive it), its volume, "Resume on this phone" (stops it and carries on in Finamp at the same track and second) and leaving
/// casting. Kept to one compact row so the rest of the player screen stays visible.
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

  Future<void> _resumeHere() async {
    setState(() => _busy = true);
    try {
      await MusicAssistantCast.instance.resumeHere();
    } catch (e) {
      GlobalSnackbar.message((context) => AppLocalizations.of(context)!.musicAssistantError(e.toString()));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _showVolume() async {
    final start = (_now?.volume ?? 50).toDouble();
    await showModalBottomSheet<void>(
      context: context,
      builder: (context) {
        var value = start;
        return StatefulBuilder(
          builder: (context, setSheetState) => Padding(
            padding: const EdgeInsets.fromLTRB(16, 24, 16, 32),
            child: Row(
              children: [
                const Icon(TablerIcons.volume),
                Expanded(
                  child: Slider(
                    value: value.clamp(0, 100),
                    max: 100,
                    onChanged: (v) => setSheetState(() => value = v),
                    onChangeEnd: (v) => _command("volume_set", {"volume_level": v.round()}),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final now = _now;
    // One compact row, so the progress bar and Finamp's own buttons stay on screen
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 2),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 2, 0, 2),
        decoration: BoxDecoration(
          color: (IconTheme.of(context).color ?? Colors.white).withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            Icon(
              widget.player.name.toLowerCase().contains("tv") ? TablerIcons.device_tv : TablerIcons.device_speaker,
              size: 18,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.musicAssistantPlayingOn(widget.player.name),
                    style: theme.textTheme.labelSmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (now?.title != null)
                    Text(
                      [now!.title, now.artist].nonNulls.join(" · "),
                      style: theme.textTheme.bodySmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
            PopupMenuButton<String>(
              icon: const Icon(TablerIcons.dots_vertical, size: 20),
              onSelected: (choice) {
                switch (choice) {
                  case "volume":
                    _showVolume();
                  case "resume":
                    _resumeHere();
                  case "stop":
                    MusicAssistantCast.instance.stop();
                }
              },
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: "resume",
                  enabled: !_busy,
                  child: ListTile(
                    leading: const Icon(TablerIcons.device_mobile),
                    title: Text(l10n.musicAssistantResumeHere),
                  ),
                ),
                PopupMenuItem(
                  value: "volume",
                  child: ListTile(
                    leading: const Icon(TablerIcons.volume),
                    title: Text(l10n.outputMenuVolumeSectionTitle),
                  ),
                ),
                PopupMenuItem(
                  value: "stop",
                  child: ListTile(leading: const Icon(TablerIcons.x), title: Text(l10n.musicAssistantForget)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
