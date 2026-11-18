import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/animated_cover_service.dart';
import 'package:flutter/material.dart';
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
      formatHint: VideoFormat.hls,
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
    } catch (_) {
      // no video: the normal cover stays
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
    // Apple Music style: edge to edge, fading out at the bottom into the screen behind the title and controls
    return IgnorePointer(
      child: AnimatedOpacity(
        opacity: _ready ? 1 : 0,
        duration: const Duration(milliseconds: 600),
        child: controller == null || !_ready
            ? const SizedBox.expand()
            : ShaderMask(
                blendMode: BlendMode.dstIn,
                shaderCallback: (bounds) => const LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.white, Colors.white, Colors.transparent],
                  stops: [0, 0.72, 1],
                ).createShader(bounds),
                child: SizedBox.expand(
                  child: FittedBox(
                    fit: BoxFit.cover,
                    clipBehavior: Clip.hardEdge,
                    child: SizedBox(
                      width: controller.value.size.width,
                      height: controller.value.size.height,
                      child: VideoPlayer(controller),
                    ),
                  ),
                ),
              ),
      ),
    );
  }
}
