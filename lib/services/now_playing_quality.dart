import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:collection/collection.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../components/PlayerScreen/quality_badge.dart';
import 'current_track_metadata_provider.dart';
import 'finamp_settings_helper.dart';
import 'metadata_provider.dart';
import 'music_player_background_task.dart';

/// Shows the Hi-Res / CD / MP3 quality next to the title and artist in Android Auto: as a logo where Android Auto
/// supports it, and always as a label after the artist ("Rohff · Hi-Res").
///
/// The playing track's metadata gets the content-format icon extras of androidx.car.app.mediaextensions
/// (MetadataExtras.KEY_CONTENT_FORMAT_TINTABLE_*_ICON_URI), pointing at one-colour vector drawables
/// (android/app/src/main/res/drawable/quality_*.xml). The quality is known once the track's playback info
/// arrives, so the current media item is updated then, and again if something else replaces it later.
class NowPlayingQuality {
  NowPlayingQuality._();

  static const _largeIconKey = "androidx.car.app.mediaextensions.KEY_CONTENT_FORMAT_TINTABLE_LARGE_ICON_URI";
  static const _smallIconKey = "androidx.car.app.mediaextensions.KEY_CONTENT_FORMAT_TINTABLE_SMALL_ICON_URI";
  static final _logger = Logger("NowPlayingQuality");

  /// Icon URI and label per track id, for the tracks whose quality is known.
  static final Map<String, ({String icon, String label})> _qualityByTrack = {};

  /// Labels added after the artist ("Rohff · Hi-Res"): Android Auto versions that ignore the icon still show it.
  static const _labels = ["Hi-Res", "CD", "MP3"];
  static const _separator = " · ";
  static String? _packageName;
  static bool _started = false;

  static Future<void> start(MusicPlayerBackgroundTask handler) async {
    if (!Platform.isAndroid || _started) return;
    _started = true;
    _packageName = (await PackageInfo.fromPlatform()).packageName;

    GetIt.instance<ProviderContainer>().listen<AsyncValue<MetadataProvider?>>(currentTrackMetadataProvider, (_, next) {
      final metadata = next.valueOrNull;
      if (metadata == null) return;
      final quality = _qualityFor(metadata, handler.mediaItem.valueOrNull);
      if (quality == null) return;
      _qualityByTrack[metadata.item.id.raw] = quality;
      _apply(handler);
    }, fireImmediately: true);

    // Other updates of the media item (album art, favourite...) start from a copy without the icon.
    handler.mediaItem.listen((_) => _apply(handler));
  }

  static String? _trackId(MediaItem? item) => (item?.extras?["itemJson"] as Map?)?["Id"]?.toString();

  static void _apply(MusicPlayerBackgroundTask handler) {
    final current = handler.mediaItem.valueOrNull;
    final quality = _qualityByTrack[_trackId(current)];
    if (current == null || quality == null) return;
    final subtitle = "${_withoutLabel(current.displaySubtitle ?? current.artist ?? "")}$_separator${quality.label}";
    if (current.extras?[_largeIconKey] == quality.icon && current.displaySubtitle == subtitle) return;
    handler.mediaItem.add(
      current.copyWith(
        displaySubtitle: subtitle,
        extras: {...?current.extras, _largeIconKey: quality.icon, _smallIconKey: quality.icon},
      ),
    );
  }

  static String _withoutLabel(String subtitle) {
    for (final label in _labels) {
      if (subtitle.endsWith("$_separator$label")) {
        return subtitle.substring(0, subtitle.length - _separator.length - label.length);
      }
    }
    return subtitle;
  }

  /// Same rules as the logo on the player screen: what is actually played, after any transcoding.
  static ({String icon, String label})? _qualityFor(MetadataProvider metadata, MediaItem? current) {
    try {
      final settings = FinampSettingsHelper.finampSettings;
      final transcoding =
          !metadata.isDownloaded &&
          _trackId(current) == metadata.item.id.raw &&
          (current?.extras?["shouldTranscode"] as bool? ?? false);
      final stream =
          metadata.mediaSourceInfo.mediaStreams.firstWhereOrNull((s) => s.type == "Audio") ??
          metadata.mediaSourceInfo.mediaStreams.firstOrNull;
      final format = settings.transcodingStreamingFormat;
      final quality = ListeningQuality.of(
        codec: transcoding ? format.codec : stream?.codec,
        bitDepth: transcoding ? (format.lossless ? stream?.bitDepth : null) : stream?.bitDepth,
        sampleRate: transcoding ? format.sampleRate : stream?.sampleRate,
      );
      final (name, label) = switch (quality) {
        ListeningQuality.hiRes => ("quality_hires", "Hi-Res"),
        ListeningQuality.cd => ("quality_cd", "CD"),
        ListeningQuality.lossy => ("quality_mp3", "MP3"),
        null => (null, null),
      };
      if (name == null || label == null) return null;
      return (icon: "android.resource://$_packageName/drawable/$name", label: label);
    } catch (e) {
      _logger.fine("No quality for ${metadata.item.name}: $e");
      return null;
    }
  }
}
