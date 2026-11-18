import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

import '../models/jellyfin_models.dart';
import 'jellyfin_api_helper.dart';

/// Animated album covers saved on the server next to each album (`<album folder>/cover/animated.mp4`, done by
/// Alacarte) and served by nginx at `<base>/<path of the album inside the library>/cover/animated.mp4?k=<key>`.
///
/// The album's folder comes from Jellyfin (its Path, e.g. `/Flac/Drake - Views`); the library prefix (`/Flac`)
/// is removed to get its place under the nginx address. Whether a video exists is checked once (HEAD) and kept.
class AnimatedCoverService {
  AnimatedCoverService._();
  static final instance = AnimatedCoverService._();

  static final _logger = Logger("AnimatedCover");
  static const _enabledKey = "animatedCovers.enabled";
  static const _baseKey = "animatedCovers.base";
  static const _secretKey = "animatedCovers.key";
  static const _prefixKey = "animatedCovers.prefix";

  static const defaultBase = "https://download.tazr2.ovh/covers";
  static const defaultPrefix = "/Flac";

  final _client = http.Client();

  /// Why the last lookup found no video (diagnostic).
  String lastReason = "";

  /// Current step of the lookup (diagnostic, shown on the cover while testing).
  final step = ValueNotifier<String>("");
  final _found = <String, String?>{};
  final _inFlight = <String, Future<String?>>{};

  Future<({bool enabled, String base, String key, String prefix})> settings() async {
    final prefs = await SharedPreferences.getInstance();
    return (
      enabled: prefs.getBool(_enabledKey) ?? false,
      base: prefs.getString(_baseKey) ?? defaultBase,
      key: prefs.getString(_secretKey) ?? "",
      prefix: prefs.getString(_prefixKey) ?? defaultPrefix,
    );
  }

  Future<void> save({required bool enabled, required String base, required String key, required String prefix}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledKey, enabled);
    await prefs.setString(_baseKey, base.trim().replaceAll(RegExp(r'/+$'), ""));
    await prefs.setString(_secretKey, key.trim());
    await prefs.setString(_prefixKey, prefix.trim());
    _found.clear();
  }

  /// The video playing for the current album, kept here (not in the cover widget, which the player screen may
  /// rebuild or recreate at any time) so it survives those rebuilds.
  final current = ValueNotifier<({String folder, VideoPlayerController controller})?>(null);

  /// Diagnostic status of [showFor] (shown on the cover while testing).
  final status = ValueNotifier<String>("");
  String? _wantedFolder;

  static String folderOf(String trackFilePath) {
    final normalized = trackFilePath.replaceAll("\\", "/");
    final slash = normalized.lastIndexOf("/");
    return slash <= 0 ? "" : normalized.substring(0, slash);
  }

  /// Loads and plays (silent, looping) the animated cover of the album of [trackFilePath], once per album.
  Future<void> showFor(String trackFilePath) async {
    final folder = folderOf(trackFilePath);
    if (folder.isEmpty || folder == _wantedFolder) return;
    _wantedFolder = folder;
    final previous = current.value;
    current.value = null;
    unawaited(previous?.controller.dispose());
    status.value = "lookup";
    final url = await forTrackFile(trackFilePath);
    if (_wantedFolder != folder) return;
    if (url == null) {
      status.value = "no video ($lastReason)";
      return;
    }
    status.value = "opening";
    final controller = VideoPlayerController.networkUrl(
      Uri.parse(url),
      // never take the audio focus from the music
      videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
    );
    try {
      await controller.initialize();
      await controller.setVolume(0);
      await controller.setLooping(true);
      await controller.play();
      if (_wantedFolder != folder) {
        await controller.dispose();
        return;
      }
      status.value = "playing ${controller.value.size.width.round()}";
      current.value = (folder: folder, controller: controller);
    } catch (e) {
      status.value = "error: $e";
      await controller.dispose();
    }
  }

  /// The video for the album folder of the track file at [trackFilePath] (from the playback info Finamp already
  /// has), or null. No call to Jellyfin: its folder is the album's, its parent too for "CD 1" style folders.
  Future<String?> forTrackFile(String trackFilePath) async {
    final normalized = trackFilePath.replaceAll("\\", "/");
    final folder = normalized.substring(0, normalized.lastIndexOf("/").clamp(0, normalized.length));
    if (folder.isEmpty) return null;
    if (_found.containsKey(folder)) return _found[folder];
    return _inFlight[folder] ??= _lookupFolder(folder).whenComplete(() => _inFlight.remove(folder));
  }

  Future<String?> _lookupFolder(String folder) async {
    final config = await settings();
    if (!config.enabled || config.key.isEmpty) {
      lastReason = "off or no key";
      return null;
    }
    final parent = folder.contains("/") ? folder.substring(0, folder.lastIndexOf("/")) : "";
    try {
      for (final candidate in [
        folder,
        if (RegExp(r'/(cd|disc|disque)\s*\d+$', caseSensitive: false).hasMatch(folder)) parent,
      ]) {
        final url = urlFor(candidate, config.base, config.prefix, config.key);
        step.value = "server";
        final response = await _client.head(Uri.parse(url)).timeout(const Duration(seconds: 10));
        lastReason = "HTTP ${response.statusCode}";
        if (response.statusCode == 200) {
          step.value = "done";
          _found[folder] = url;
          return url;
        }
      }
      step.value = "done";
      _found[folder] = null;
      return null;
    } catch (e) {
      lastReason = "$e";
      return null; // try again next time
    }
  }

  /// The video of [track]'s album, or null when there is none (or the feature is off).
  Future<String?> forTrack(BaseItemDto track) async {
    final albumId = track.albumId;
    if (albumId == null || albumId.raw.startsWith("ext-")) {
      lastReason = "no library album";
      return null;
    }
    if (_found.containsKey(albumId.raw)) return _found[albumId.raw];
    return _inFlight[albumId.raw] ??= _lookup(albumId).whenComplete(() => _inFlight.remove(albumId.raw));
  }

  Future<String?> _lookup(BaseItemId albumId) async {
    step.value = "settings";
    final config = await settings();
    if (!config.enabled || config.key.isEmpty) {
      lastReason = "off or no key";
      return null;
    }
    try {
      final result = await check(albumId);
      lastReason = "HTTP ${result.status}";
      return _remember(albumId, result.found ? result.url : null);
    } catch (e) {
      _logger.fine("No animated cover for $albumId: $e");
      lastReason = "$e";
      return null; // try again next time
    }
  }

  /// Builds the address of [albumId]'s video and asks the server for it: for the settings' test button too.
  Future<({String? path, String? url, int? status, bool found})> check(BaseItemId albumId) async {
    final config = await settings();
    step.value = "jellyfin";
    final album = await GetIt.instance<JellyfinApiHelper>().getItemById(albumId).timeout(const Duration(seconds: 10));
    final path = album.path;
    if (path == null) return (path: null, url: null, status: null, found: false);
    final url = urlFor(path, config.base, config.prefix, config.key);
    step.value = "server";
    final response = await _client.head(Uri.parse(url)).timeout(const Duration(seconds: 10));
    step.value = "done";
    return (path: path, url: url, status: response.statusCode, found: response.statusCode == 200);
  }

  static String urlFor(String albumPath, String base, String prefix, String key) {
    var relative = albumPath.replaceAll("\\", "/");
    final cleanPrefix = prefix.replaceAll(RegExp(r'/+$'), "");
    if (cleanPrefix.isNotEmpty && relative.startsWith(cleanPrefix)) relative = relative.substring(cleanPrefix.length);
    final segments = [...relative.split("/").where((s) => s.isNotEmpty), "cover", "animated.mp4"];
    final baseUri = Uri.parse(base);
    return baseUri
        .replace(
          pathSegments: [...baseUri.pathSegments.where((s) => s.isNotEmpty), ...segments],
          queryParameters: {"k": key},
        )
        .toString();
  }

  String? _remember(BaseItemId albumId, String? url) {
    _found[albumId.raw] = url;
    return url;
  }
}
