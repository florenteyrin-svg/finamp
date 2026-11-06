import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';
import 'package:rxdart/rxdart.dart';

/// Keeps the Android home screen widgets (android/.../widget/FinampWidgets.kt) in sync with the
/// player: current track, artist, album, album art and play/pause state.
class HomeWidgetUpdater {
  HomeWidgetUpdater({required Stream<MediaItem?> mediaItem, required Stream<PlaybackState> playbackState}) {
    if (!Platform.isAndroid) return;
    _subscription = Rx.combineLatest2<MediaItem?, bool, _WidgetData>(
      mediaItem,
      playbackState.map((s) => s.playing).distinct(),
      (item, playing) => _WidgetData.from(item, playing),
    ).distinct().debounceTime(const Duration(milliseconds: 250)).listen(_push);
  }

  static final _logger = Logger("HomeWidget");
  static const _channel = MethodChannel("com.unicornsonlsd.finamp/home_widget");

  StreamSubscription<_WidgetData>? _subscription;

  Future<void> _push(_WidgetData data) async {
    try {
      await _channel.invokeMethod<void>("update", data.toMap());
    } catch (e) {
      _logger.fine("Could not update home screen widgets: $e");
    }
  }

  void dispose() => _subscription?.cancel();
}

class _WidgetData {
  _WidgetData({this.title, this.artist, this.album, this.artPath, required this.playing});

  factory _WidgetData.from(MediaItem? item, bool playing) {
    final art = item?.artUri;
    // Finamp's art URIs are local files, exposed as content://<package>/<file path> on Android
    final artPath = art == null || (art.scheme != "file" && art.scheme != "content") ? null : art.path;
    return _WidgetData(
      title: item?.title,
      artist: item?.artist,
      album: item?.album,
      artPath: artPath,
      playing: item != null && playing,
    );
  }

  final String? title;
  final String? artist;
  final String? album;
  final String? artPath;
  final bool playing;

  Map<String, Object?> toMap() => {
    "title": title,
    "artist": artist,
    "album": album,
    "artPath": artPath,
    "playing": playing,
  };

  @override
  bool operator ==(Object other) =>
      other is _WidgetData &&
      other.title == title &&
      other.artist == artist &&
      other.album == album &&
      other.artPath == artPath &&
      other.playing == playing;

  @override
  int get hashCode => Object.hash(title, artist, album, artPath, playing);
}
