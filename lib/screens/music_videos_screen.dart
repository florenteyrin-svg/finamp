import 'dart:async';
import 'dart:math';

import 'package:finamp/components/album_image.dart';
import 'package:finamp/l10n/app_localizations.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/finamp_user_helper.dart';
import 'package:finamp/services/jellyfin_api_helper.dart';
import 'package:finamp/services/music_player_background_task.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';
import 'package:video_player/video_player.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

/// The music videos of the Jellyfin library ("Music videos" libraries), to watch them. Playback only: nothing is
/// downloaded or changed.
class MusicVideosScreen extends StatefulWidget {
  const MusicVideosScreen({super.key});

  @override
  State<MusicVideosScreen> createState() => _MusicVideosScreenState();
}

class _MusicVideosScreenState extends State<MusicVideosScreen> {
  late Future<List<BaseItemDto>> _videos = _load();
  String _filter = "";

  static Future<List<BaseItemDto>> _load() async {
    final items = await GetIt.instance<JellyfinApiHelper>().getItems(
      includeItemTypes: "MusicVideo",
      recursive: true,
      sortBy: "SortName",
      sortOrder: "Ascending",
      fields: "Artists,ParentId",
    );
    return items ?? [];
  }

  static String _artists(BaseItemDto video) =>
      (video.artists?.isNotEmpty ?? false) ? video.artists!.join(", ") : (video.albumArtist ?? "");

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.musicVideos)),
      body: FutureBuilder<List<BaseItemDto>>(
        future: _videos,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: TextButton.icon(
                onPressed: () => setState(() => _videos = _load()),
                icon: const Icon(Icons.refresh),
                label: Text("${snapshot.error}"),
              ),
            );
          }
          if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
          final query = _filter.trim().toLowerCase();
          final videos = snapshot.data!
              .where(
                (v) =>
                    query.isEmpty ||
                    (v.name ?? "").toLowerCase().contains(query) ||
                    _artists(v).toLowerCase().contains(query),
              )
              .toList();
          return RefreshIndicator(
            onRefresh: () async {
              final next = _load();
              setState(() => _videos = next);
              await next;
            },
            child: CustomScrollView(
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                  sliver: SliverToBoxAdapter(
                    child: TextField(
                      decoration: InputDecoration(
                        prefixIcon: const Icon(Icons.search),
                        hintText: l10n.musicVideosSearch,
                        border: const OutlineInputBorder(),
                        isDense: true,
                      ),
                      onChanged: (value) => setState(() => _filter = value),
                    ),
                  ),
                ),
                if (snapshot.data!.isEmpty)
                  SliverFillRemaining(child: Center(child: Text(l10n.musicVideosEmpty)))
                else
                  SliverPadding(
                    padding: const EdgeInsets.all(12),
                    sliver: SliverGrid(
                      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: 260,
                        mainAxisSpacing: 12,
                        crossAxisSpacing: 12,
                        childAspectRatio: 16 / 13,
                      ),
                      delegate: SliverChildBuilderDelegate((context, index) {
                        final video = videos[index];
                        return InkWell(
                          borderRadius: BorderRadius.circular(8),
                          onTap: () => Navigator.of(
                            context,
                          ).push(MaterialPageRoute<void>(builder: (_) => MusicVideoPlayerScreen(video: video))),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    ClipRRect(
                                      borderRadius: BorderRadius.circular(8),
                                      child: AlbumImage(item: video, borderRadius: BorderRadius.circular(8)),
                                    ),
                                    const Center(child: Icon(Icons.play_circle_fill, size: 44, color: Colors.white70)),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(video.name ?? "", maxLines: 1, overflow: TextOverflow.ellipsis),
                              Text(
                                _artists(video),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                          ),
                        );
                      }, childCount: videos.length),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Full screen player for one music video, streamed from Jellyfin: the file as is when the phone can play it,
/// otherwise converted by the server (HLS).
class MusicVideoPlayerScreen extends StatefulWidget {
  const MusicVideoPlayerScreen({super.key, required this.video});

  final BaseItemDto video;

  @override
  State<MusicVideoPlayerScreen> createState() => _MusicVideoPlayerScreenState();
}

class _MusicVideoPlayerScreenState extends State<MusicVideoPlayerScreen> {
  static final _logger = Logger("MusicVideoPlayer");

  VideoPlayerController? _controller;
  bool _failed = false;
  bool _controlsVisible = true;
  Timer? _hideTimer;

  @override
  void initState() {
    super.initState();
    // the music stops while the video plays
    unawaited(GetIt.instance<MusicPlayerBackgroundTask>().pause());
    unawaited(WakelockPlus.enable());
    unawaited(_open());
  }

  Future<void> _open() async {
    final user = GetIt.instance<FinampUserHelper>().currentUser!;
    final base = user.baseURL.replaceAll(RegExp(r'/+$'), "");
    final id = widget.video.id.raw;
    final direct = Uri.parse(
      "$base/Videos/$id/stream",
    ).replace(queryParameters: {"static": "true", "MediaSourceId": id, "ApiKey": user.accessToken});
    final converted = Uri.parse("$base/Videos/$id/master.m3u8").replace(
      queryParameters: {
        "MediaSourceId": id,
        "VideoCodec": "h264",
        "AudioCodec": "aac",
        "PlaySessionId": "finamp-${Random().nextInt(1 << 31)}",
        "DeviceId": "finamp-music-videos",
        "ApiKey": user.accessToken,
      },
    );
    for (final (uri, hint) in [(direct, null), (converted, VideoFormat.hls)]) {
      final controller = VideoPlayerController.networkUrl(uri, formatHint: hint);
      try {
        await controller.initialize().timeout(const Duration(seconds: 30));
        if (!mounted) {
          await controller.dispose();
          return;
        }
        controller.addListener(_onTick);
        await controller.play();
        setState(() => _controller = controller);
        _scheduleHide();
        return;
      } catch (e) {
        _logger.warning("Could not open ${hint == null ? "the file" : "the converted stream"}: $e");
        await controller.dispose();
      }
    }
    if (mounted) setState(() => _failed = true);
  }

  void _onTick() {
    if (mounted) setState(() {});
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && (_controller?.value.isPlaying ?? false)) setState(() => _controlsVisible = false);
    });
  }

  void _toggleControls() {
    setState(() => _controlsVisible = !_controlsVisible);
    if (_controlsVisible) _scheduleHide();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _controller?.removeListener(_onTick);
    unawaited(_controller?.dispose());
    unawaited(WakelockPlus.disable());
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    super.dispose();
  }

  static String _time(Duration d) {
    final minutes = d.inMinutes;
    final seconds = (d.inSeconds % 60).toString().padLeft(2, "0");
    return "$minutes:$seconds";
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final value = controller?.value;
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _toggleControls,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Center(
              child: _failed
                  ? Text(AppLocalizations.of(context)!.musicVideoError, style: const TextStyle(color: Colors.white))
                  : controller == null
                  ? const CircularProgressIndicator(color: Colors.white)
                  : AspectRatio(aspectRatio: value!.aspectRatio, child: VideoPlayer(controller)),
            ),
            AnimatedOpacity(
              opacity: _controlsVisible || _failed ? 1 : 0,
              duration: const Duration(milliseconds: 250),
              child: IgnorePointer(
                ignoring: !(_controlsVisible || _failed),
                child: DecoratedBox(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Color(0x99000000), Colors.transparent, Colors.transparent, Color(0xB3000000)],
                      stops: [0, 0.2, 0.7, 1],
                    ),
                  ),
                  child: SafeArea(
                    child: Column(
                      children: [
                        Row(
                          children: [
                            IconButton(
                              icon: const Icon(Icons.close, color: Colors.white),
                              onPressed: () => Navigator.of(context).pop(),
                            ),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    widget.video.name ?? "",
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(color: Colors.white, fontSize: 16),
                                  ),
                                  Text(
                                    widget.video.artists?.join(", ") ?? "",
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(color: Colors.white70, fontSize: 13),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const Spacer(),
                        if (controller != null && value != null) ...[
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            child: VideoProgressIndicator(
                              controller,
                              allowScrubbing: true,
                              colors: const VideoProgressColors(
                                playedColor: Colors.white,
                                bufferedColor: Colors.white38,
                                backgroundColor: Colors.white12,
                              ),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
                            child: Row(
                              children: [
                                Text(_time(value.position), style: const TextStyle(color: Colors.white70)),
                                const Spacer(),
                                Text(_time(value.duration), style: const TextStyle(color: Colors.white70)),
                              ],
                            ),
                          ),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              IconButton(
                                iconSize: 36,
                                color: Colors.white,
                                icon: const Icon(Icons.replay_10),
                                onPressed: () {
                                  controller.seekTo(value.position - const Duration(seconds: 10));
                                  _scheduleHide();
                                },
                              ),
                              const SizedBox(width: 24),
                              IconButton(
                                iconSize: 56,
                                color: Colors.white,
                                icon: Icon(value.isPlaying ? Icons.pause_circle_filled : Icons.play_circle_filled),
                                onPressed: () {
                                  value.isPlaying ? controller.pause() : controller.play();
                                  _scheduleHide();
                                },
                              ),
                              const SizedBox(width: 24),
                              IconButton(
                                iconSize: 36,
                                color: Colors.white,
                                icon: const Icon(Icons.forward_10),
                                onPressed: () {
                                  controller.seekTo(value.position + const Duration(seconds: 10));
                                  _scheduleHide();
                                },
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
