import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/animated_cover_service.dart';
import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:video_player/video_player.dart';

/// The album's animated cover (saved by Alacarte on the server), silent and looping, over the normal cover once
/// it plays (nothing is shown when the album has none).
class AnimatedCover extends StatefulWidget {
  const AnimatedCover({super.key, required this.track});

  final BaseItemDto track;

  @override
  State<AnimatedCover> createState() => _AnimatedCoverState();
}

class _AnimatedCoverState extends State<AnimatedCover> {
  VideoPlayerController? _controller;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final url = await AnimatedCoverService.instance.forTrack(widget.track);
    if (url == null || !mounted) return;
    final controller = VideoPlayerController.networkUrl(
      Uri.parse(url),
      // never take the audio focus from the music
      videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
    );
    _controller = controller;
    try {
      await controller.initialize();
      await controller.setVolume(0);
      await controller.setLooping(true);
      await controller.play();
      if (mounted) setState(() => _ready = true);
    } catch (e) {
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
    final controller = _controller;
    if (controller == null || !_ready) return const SizedBox.shrink();
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
        ],
      ),
    );
  }
}
