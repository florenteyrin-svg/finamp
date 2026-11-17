import 'package:finamp/components/global_snackbar.dart';
import 'package:finamp/l10n/app_localizations.dart';
import 'package:finamp/screens/music_assistant_settings_screen.dart';
import 'package:finamp/services/music_assistant_service.dart';
import 'package:finamp/services/music_player_background_task.dart';
import 'package:finamp/services/queue_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:get_it/get_it.dart';

/// "Send to…" in the output menu: the players of Music Assistant (e.g. the Apple TVs). Tapping one hands the
/// current track (at the same second) and what follows over to it, then pauses Finamp.
class MusicAssistantTargets extends StatefulWidget {
  const MusicAssistantTargets({super.key});

  @override
  State<MusicAssistantTargets> createState() => _MusicAssistantTargetsState();
}

class _MusicAssistantTargetsState extends State<MusicAssistantTargets> {
  late Future<List<MusicAssistantPlayer>?> _players;
  String? _sending;

  @override
  void initState() {
    super.initState();
    _players = _load();
  }

  Future<List<MusicAssistantPlayer>?> _load() async {
    if (await MusicAssistantService.instance.readConfig() == null) return null;
    return MusicAssistantService.instance.players();
  }

  Future<void> _send(MusicAssistantPlayer player) async {
    final l10n = AppLocalizations.of(context)!;
    final queue = GetIt.instance<QueueService>().getQueue();
    final current = queue.currentTrack;
    if (current == null) return;
    // Music Assistant reads the tracks from Jellyfin: Apple Music items not yet added to the library are skipped
    final ids = [
      current,
      ...queue.nextUp,
      ...queue.queue,
    ].map((item) => item.baseItemId.raw).where((id) => !id.startsWith("ext-")).take(300).toList();
    if (ids.isEmpty || current.baseItemId.raw.startsWith("ext-")) {
      GlobalSnackbar.message((_) => l10n.musicAssistantNotInLibrary);
      return;
    }
    setState(() => _sending = player.id);
    final audioHandler = GetIt.instance<MusicPlayerBackgroundTask>();
    try {
      await MusicAssistantService.instance.play(player.id, ids, audioHandler.playbackPosition);
      await audioHandler.pause();
      MusicAssistantService.instance.activePlayer.add(player);
      GlobalSnackbar.message((_) => l10n.musicAssistantSent(player.name));
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      MusicAssistantService.instance.log(e);
      GlobalSnackbar.message((_) => l10n.musicAssistantError(e.toString()));
    } finally {
      if (mounted) setState(() => _sending = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return FutureBuilder<List<MusicAssistantPlayer>?>(
      future: _players,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final players = snapshot.data;
        if (snapshot.hasError || players == null) {
          return ListTile(
            leading: const Icon(TablerIcons.settings),
            title: Text(
              snapshot.hasError ? l10n.musicAssistantError(snapshot.error.toString()) : l10n.musicAssistantSetUp,
            ),
            onTap: () async {
              await Navigator.of(
                context,
              ).push(MaterialPageRoute<void>(builder: (_) => const MusicAssistantSettingsScreen()));
              if (mounted) setState(() => _players = _load());
            },
          );
        }
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final player in players)
              ListTile(
                leading: Icon(
                  player.name.toLowerCase().contains("tv") ? TablerIcons.device_tv : TablerIcons.device_speaker,
                ),
                title: Text(player.name),
                subtitle: player.available ? null : Text(l10n.musicAssistantUnavailable),
                enabled: player.available && _sending == null,
                trailing: _sending == player.id
                    ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(TablerIcons.cast),
                onTap: () => _send(player),
              ),
          ],
        );
      },
    );
  }
}
