import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';
import 'package:rxdart/rxdart.dart';

import '../models/finamp_models.dart';

/// Sends what is playing to the Android home screen widgets
/// (android/app/src/main/kotlin/com/unicornsonlsd/finamp/widgets).
///
/// The widgets themselves are native: they keep the last state they received, so they
/// still show the last track after the app is closed or the phone restarts, and their
/// buttons talk to the audio service directly.
class HomeScreenWidgets {
  HomeScreenWidgets._();

  static const _channel = MethodChannel("com.unicornsonlsd.finamp/home_screen_widgets");
  static final _logger = Logger("HomeScreenWidgets");
  static StreamSubscription<NowPlayingWidgetState>? _subscription;

  static void start({
    required Stream<MediaItem?> mediaItem,
    required Stream<PlaybackState> playbackState,
    required Stream<FinampQueueInfo?> queue,
  }) {
    if (!Platform.isAndroid || _subscription != null) return;
    _subscription =
        Rx.combineLatest3<MediaItem?, bool, FinampQueueItem?, NowPlayingWidgetState>(
              mediaItem,
              playbackState.map((state) => state.playing).distinct(),
              queue.map(_nextTrack).startWith(null),
              NowPlayingWidgetState.from,
            )
            .distinct()
            // Track changes come with several quick updates (item, art, play state): only send the last one.
            .debounceTime(const Duration(milliseconds: 300))
            .listen(_send);
  }

  static FinampQueueItem? _nextTrack(FinampQueueInfo? info) {
    if (info == null) return null;
    if (info.nextUp.isNotEmpty) return info.nextUp.first;
    if (info.queue.isNotEmpty) return info.queue.first;
    return null;
  }

  static Future<void> _send(NowPlayingWidgetState state) async {
    try {
      await _channel.invokeMethod<void>("update", state.toMap());
    } catch (e) {
      _logger.fine("Could not update the home screen widgets: $e");
    }
  }

  static void stop() {
    _subscription?.cancel();
    _subscription = null;
  }
}

class NowPlayingWidgetState {
  const NowPlayingWidgetState({
    this.title,
    this.artist,
    this.album,
    this.artPath,
    this.nextTitle,
    this.nextArtist,
    required this.playing,
  });

  factory NowPlayingWidgetState.from(MediaItem? item, bool playing, FinampQueueItem? next) {
    // Finamp hands out album art as local files (exposed as content://<package>/<path> on Android).
    final art = item?.artUri;
    final artPath = art != null && (art.scheme == "file" || art.scheme == "content") ? art.path : null;
    return NowPlayingWidgetState(
      title: item?.title,
      artist: item?.artist,
      album: item?.album,
      artPath: artPath,
      nextTitle: next?.item.title,
      nextArtist: next?.item.artist,
      playing: item != null && playing,
    );
  }

  final String? title;
  final String? artist;
  final String? album;
  final String? artPath;
  final String? nextTitle;
  final String? nextArtist;
  final bool playing;

  Map<String, Object?> toMap() => {
    "title": title,
    "artist": artist,
    "album": album,
    "artPath": artPath,
    "nextTitle": nextTitle,
    "nextArtist": nextArtist,
    "playing": playing,
  };

  @override
  bool operator ==(Object other) =>
      other is NowPlayingWidgetState &&
      other.title == title &&
      other.artist == artist &&
      other.album == album &&
      other.artPath == artPath &&
      other.nextTitle == nextTitle &&
      other.nextArtist == nextArtist &&
      other.playing == playing;

  @override
  int get hashCode => Object.hash(title, artist, album, artPath, nextTitle, nextArtist, playing);
}
