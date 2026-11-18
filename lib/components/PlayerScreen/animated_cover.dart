import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/animated_cover_service.dart';
import 'package:finamp/services/current_track_metadata_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

/// The album's animated cover (saved by Alacarte on the server), silent and looping, edge to edge over the
/// cover area, with a dark gradient at the bottom (Apple Music style). Nothing is shown when the album has none.
///
/// The video itself lives in [AnimatedCoverService.current]; this widget only asks for it (from the track's file
/// path, known once its playback info is loaded) and shows it.
class AnimatedCover extends ConsumerWidget {
  const AnimatedCover({super.key, required this.track});

  final BaseItemDto track;

  /// TEMPORARY: shows where the animated cover stops, until it works.
  static const _showDiagnostic = true;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final service = AnimatedCoverService.instance;
    final metadata = ref.watch(currentTrackMetadataProvider).valueOrNull;
    final path = metadata != null && metadata.item.id == track.id ? metadata.mediaSourceInfo.path : null;
    if (path != null && path.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => service.showFor(path));
    }
    final folder = path == null ? null : AnimatedCoverService.folderOf(path);
    return IgnorePointer(
      child: Stack(
        fit: StackFit.expand,
        children: [
          ValueListenableBuilder(
            valueListenable: service.current,
            builder: (context, current, _) {
              if (current == null || current.folder != folder) return const SizedBox.shrink();
              final controller = current.controller;
              return Stack(
                fit: StackFit.expand,
                children: [
                  ClipRect(
                    child: FittedBox(
                      fit: BoxFit.cover,
                      child: SizedBox(
                        width: controller.value.size.width,
                        height: controller.value.size.height,
                        child: VideoPlayer(controller),
                      ),
                    ),
                  ),
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Colors.transparent, Colors.transparent, Color(0xCC000000)],
                        stops: [0, 0.65, 1],
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
          if (_showDiagnostic)
            Align(
              alignment: Alignment.bottomRight,
              child: ValueListenableBuilder(
                valueListenable: service.status,
                builder: (context, status, _) => Container(
                  margin: const EdgeInsets.all(6),
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  color: Colors.black54,
                  child: Text(
                    "AC: ${path == null ? "waiting for track info" : status}",
                    style: const TextStyle(color: Colors.white, fontSize: 10),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
