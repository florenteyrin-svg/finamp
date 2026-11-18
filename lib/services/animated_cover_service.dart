import 'dart:async';

import 'package:get_it/get_it.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  /// The video of [track]'s album, or null when there is none (or the feature is off).
  Future<String?> forTrack(BaseItemDto track) async {
    final albumId = track.albumId;
    if (albumId == null || albumId.raw.startsWith("ext-")) return null;
    if (_found.containsKey(albumId.raw)) return _found[albumId.raw];
    return _inFlight[albumId.raw] ??= _lookup(albumId).whenComplete(() => _inFlight.remove(albumId.raw));
  }

  Future<String?> _lookup(BaseItemId albumId) async {
    final config = await settings();
    if (!config.enabled || config.key.isEmpty) return null;
    try {
      final album = await GetIt.instance<JellyfinApiHelper>().getItemById(albumId);
      final path = album.path;
      if (path == null) return _remember(albumId, null);
      var relative = path.replaceAll("\\", "/");
      final prefix = config.prefix.replaceAll(RegExp(r'/+$'), "");
      if (prefix.isNotEmpty && relative.startsWith(prefix)) relative = relative.substring(prefix.length);
      relative = relative.replaceAll(RegExp(r'^/+'), "");
      final segments = [...relative.split("/").where((s) => s.isNotEmpty), "cover", "animated.mp4"];
      final url = Uri.parse(config.base).replace(
        pathSegments: [...Uri.parse(config.base).pathSegments.where((s) => s.isNotEmpty), ...segments],
        queryParameters: {"k": config.key},
      );
      final response = await _client.head(url).timeout(const Duration(seconds: 8));
      return _remember(albumId, response.statusCode == 200 ? url.toString() : null);
    } catch (e) {
      _logger.fine("No animated cover for $albumId: $e");
      return null; // try again next time
    }
  }

  String? _remember(BaseItemId albumId, String? url) {
    _found[albumId.raw] = url;
    return url;
  }
}
