import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/animated_cover_service.dart';
import 'package:finamp/services/current_track_metadata_provider.dart';
import 'package:finamp/services/metadata_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:video_player/video_player.dart';

/// The album's animated cover (saved by Alacarte on the server), silent and looping, over the normal cover once
/// it plays (nothing is shown when the album has none).
class AnimatedCover extends ConsumerStatefulWidget {
  const AnimatedCover({super.key, required this.track});

  final BaseItemDto track;

  @override
  ConsumerState<AnimatedCover> createState() => _AnimatedCoverState();
}

class _AnimatedCoverState extends ConsumerState<AnimatedCover> {
  VideoPlayerController? _controller;
  bool _ready = false;

  /// TEMPORARY diagnostic shown in a corner, to see where the animated cover stops.
  String _status = "waiting for track info";

  void _setStatus(String status) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _status = status);
    });
  }

  bool _started = false;

  /// Starts once the playback info of this track (with its file path) is known.
  void _maybeStart(MetadataProvider? metadata) {
    if (_started || metadata == null || metadata.item.id != widget.track.id) return;
    final path = metadata.mediaSourceInfo.path;
    if (path == null || path.isEmpty) {
      _setStatus("no file path");
      return;
    }
    _started = true;
    _load(path);
  }

  Future<void> _load(String trackFilePath) async {
    _setStatus("lookup");
    final url = await AnimatedCoverService.instance.forTrackFile(trackFilePath);
    if (!mounted) return;
    if (url == null) {
      _setStatus("no video (${AnimatedCoverService.instance.lastReason})");
      return;
    }
    _setStatus("found, opening");
    final controller = VideoPlayerController.networkUrl(
      Uri.parse(url),
      // never take the audio focus from the music
      videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
    );
    _controller = controller;
    try {
      await controller.initialize();
      _setStatus("opened ${controller.value.size.width.round()}");
      await controller.setVolume(0);
      await controller.setLooping(true);
      await controller.play();
      _setStatus("playing");
      if (mounted) setState(() => _ready = true);
    } catch (e) {
      _setStatus("error: $e");
      // the normal cover stays
      Logger("AnimatedCover").warning("Could not play the animated cover $url: $e");
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _maybeStart(ref.watch(currentTrackMetadataProvider).valueOrNull);
    final controller = _controller;
    final debug = Align(
      alignment: Alignment.bottomRight,
      child: Container(
        margin: const EdgeInsets.all(6),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        color: Colors.black54,
        child: ValueListenableBuilder<String>(
          valueListenable: AnimatedCoverService.instance.step,
          builder: (context, step, _) =>
              Text("AC: $_status [$step]", style: const TextStyle(color: Colors.white, fontSize: 10)),
        ),
      ),
    );
    if (controller == null || !_ready) return IgnorePointer(child: debug);
    // Apple Music style: edge to edge, with a dark gradient at the bottom towards the title and controls.
    // (No ShaderMask / Opacity over the video: with some renderers they leave the video texture invisible.)
    return IgnorePointer(
      child: Stack(
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
          debug,
        ],
      ),
    );
  }
}
