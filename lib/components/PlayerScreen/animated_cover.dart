import 'dart:async';

import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/animated_cover_service.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

/// The album's animated cover (saved by Alacarte on the server), silent and looping, edge to edge over the
/// cover area, with a dark gradient at the bottom (Apple Music style). Nothing is shown when the album has none.
///
/// The video itself lives in [AnimatedCoverService.current]; this widget only asks for it (from the track's file
/// path, known once its playback info is loaded) and shows it.
class AnimatedCover extends StatefulWidget {
  const AnimatedCover({super.key, required this.track});

  final BaseItemDto track;

  /// Diagnostic label (where the lookup stopped); off, kept for troubleshooting.
  static const _showDiagnostic = false;

  @override
  State<AnimatedCover> createState() => _AnimatedCoverState();
}

class _AnimatedCoverState extends State<AnimatedCover> {
  final service = AnimatedCoverService.instance;

  /// Bumped shortly after a video arrives while this cover is already on screen, so the video surface is created
  /// again (it may otherwise stay blank until the player is reopened).
  int _surface = 0;
  final _timers = <Timer>[];

  @override
  void initState() {
    super.initState();
    service.attach();
    service.current.addListener(_onVideo);
  }

  void _onVideo() {
    if (service.current.value == null) return;
    for (final delay in const [300, 1200]) {
      _timers.add(
        Timer(Duration(milliseconds: delay), () {
          if (mounted) setState(() => _surface++);
        }),
      );
    }
  }

  @override
  void dispose() {
    for (final timer in _timers) {
      timer.cancel();
    }
    service.current.removeListener(_onVideo);
    service.detach();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const showDiagnostic = AnimatedCover._showDiagnostic;
    final albumId = widget.track.albumId?.raw;
    return IgnorePointer(
      child: Stack(
        fit: StackFit.expand,
        children: [
          ValueListenableBuilder(
            valueListenable: service.current,
            builder: (context, current, _) {
              if (current == null || current.albumId != albumId) return const SizedBox.shrink();
              final controller = current.controller;
              // Fades in over the still cover when the video starts (Apple Music style)
              return TweenAnimationBuilder<double>(
                key: ObjectKey(controller),
                tween: Tween(begin: 0, end: 1),
                duration: const Duration(milliseconds: 900),
                curve: Curves.easeInOut,
                builder: (context, opacity, child) => Opacity(opacity: opacity, child: child),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ClipRect(
                      child: FittedBox(
                        fit: BoxFit.cover,
                        child: SizedBox(
                          width: controller.value.size.width,
                          height: controller.value.size.height,
                          child: VideoPlayer(controller, key: ValueKey(_surface)),
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
            },
          ),
          if (showDiagnostic)
            Align(
              alignment: Alignment.topLeft,
              child: ValueListenableBuilder(
                valueListenable: service.status,
                builder: (context, status, _) => ValueListenableBuilder(
                  valueListenable: service.current,
                  builder: (context, current, _) {
                    final same = current == null ? "-" : (current.albumId == albumId ? "ok" : "≠");
                    final position = current?.controller.value.position.inMilliseconds ?? 0;
                    return Container(
                      margin: const EdgeInsets.all(6),
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      color: Colors.black54,
                      child: Text(
                        "AC: $status/${service.step.value} · album $same · s$_surface · ${current?.controller.value.isPlaying ?? false ? "▶" : "Ⅱ"} $position",
                        style: const TextStyle(color: Colors.white, fontSize: 10),
                      ),
                    );
                  },
                ),
              ),
            ),
        ],
      ),
    );
  }
}
