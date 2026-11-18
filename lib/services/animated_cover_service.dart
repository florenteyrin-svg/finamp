import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path_helper;
import 'package:path_provider/path_provider.dart';
import 'package:rxdart/rxdart.dart';

import '../models/finamp_models.dart';
import 'current_track_metadata_provider.dart';
import 'metadata_provider.dart';

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
  final current = ValueNotifier<({String folder, String albumId, VideoPlayerController controller})?>(null);

  /// Where the last request stopped (shown by the diagnostic label).
  final status = ValueNotifier<String>("");
  String? _wantedFolder;
  int _generation = 0;
  bool _busy = false;
  int _viewers = 0;
  DateTime _busySince = DateTime.now();
  String? _lastPath;
  String _lastAlbumId = "";
  Timer? _watchdog;

  static String folderOf(String trackFilePath) {
    final normalized = trackFilePath.replaceAll("\\", "/");
    final slash = normalized.lastIndexOf("/");
    return slash <= 0 ? "" : normalized.substring(0, slash);
  }

  /// Follows the playing track from app start, so the video is found and ready before the player is even opened.
  void followCurrentTrack(ProviderContainer container) {
    container.listen<AsyncValue<MetadataProvider?>>(currentTrackMetadataProvider, (_, next) {
      final metadata = next.valueOrNull;
      final path = metadata?.mediaSourceInfo.path;
      if (metadata != null && path != null && path.isNotEmpty) {
        _lastPath = path;
        _lastAlbumId = metadata.item.albumId?.raw ?? "";
        unawaited(showFor(path, albumId: _lastAlbumId));
      }
    }, fireImmediately: true);
    // Safety net: while a cover is on screen without its video, try again (a lookup that got stuck is restarted)
    _watchdog ??= Timer.periodic(const Duration(seconds: 2), (_) => _ensureShown());
  }

  void _ensureShown() {
    final path = _lastPath;
    if (_viewers == 0 || path == null) return;
    final folder = folderOf(path);
    if (current.value?.folder == folder) return;
    if (_busy && DateTime.now().difference(_busySince) < const Duration(seconds: 25)) return;
    final missing = _missingSince[folder];
    if (!_busy && missing != null && DateTime.now().difference(missing) < const Duration(minutes: 2)) return;
    _wantedFolder = null; // start over
    _busy = false;
    unawaited(showFor(path, albumId: _lastAlbumId));
  }

  /// A cover is on screen: the video plays only while one is (no decoding for nothing in the background).
  void attach() {
    _viewers++;
    unawaited(current.value?.controller.play());
    _ensureShown();
  }

  void detach() {
    _viewers = (_viewers - 1).clamp(0, 1 << 30);
    if (_viewers == 0) unawaited(current.value?.controller.pause());
  }

  /// Prepares and starts the video of the album of the track file at [trackFilePath].
  Future<void> showFor(String trackFilePath, {required String albumId}) async {
    final folder = folderOf(trackFilePath);
    if (folder.isEmpty) return;
    // Already shown, or being prepared: nothing to do. A failed attempt is retried.
    if (folder == _wantedFolder && (_busy || current.value?.folder == folder)) {
      final shown = current.value;
      if (shown != null && shown.albumId != albumId && albumId.isNotEmpty) {
        current.value = (folder: folder, albumId: albumId, controller: shown.controller);
      }
      return;
    }
    final generation = ++_generation;
    _wantedFolder = folder;
    _busy = true;
    _busySince = DateTime.now();
    final previous = current.value;
    current.value = null;
    unawaited(previous?.controller.dispose());
    try {
      // 1. Kept on the phone: plays at once, no network at all
      final cached = await _cachedFile(folder);
      if (generation != _generation) return;
      final options = VideoPlayerOptions(mixWithOthers: true); // never take the audio focus from the music
      VideoPlayerController? controller;
      if (cached != null) {
        status.value = "opening (phone)";
        controller = await _open(VideoPlayerController.file(cached, videoPlayerOptions: options));
      }
      // 2. Otherwise straight from the server (no separate lookup round trip): the album folder, then its parent
      //    for CD/Disc folders. Kept on the phone afterwards for next time.
      if (controller == null) {
        final config = await settings();
        if (!config.enabled || config.key.isEmpty) {
          status.value = "off or no key";
          return;
        }
        final parent = folder.contains("/") ? folder.substring(0, folder.lastIndexOf("/")) : "";
        for (final candidate in [
          folder,
          if (RegExp(r'/(cd|disc|disque)\s*\d+$', caseSensitive: false).hasMatch(folder)) parent,
        ]) {
          if (generation != _generation) return;
          final url = _found[candidate] ?? urlFor(candidate, config.base, config.prefix, config.key);
          status.value = "opening (server)";
          controller = await _open(VideoPlayerController.networkUrl(Uri.parse(url), videoPlayerOptions: options));
          if (controller != null) {
            _found[folder] = url;
            _missingSince.remove(folder);
            // kept on the phone a bit later, so it does not slow down the start of the music and the video
            unawaited(Future<void>.delayed(const Duration(seconds: 10), () => _download(folder, url)));
            break;
          }
        }
      }
      if (controller == null) {
        if (generation == _generation) {
          status.value = "no video";
          _missingSince[folder] = DateTime.now();
        }
        return;
      }
      if (generation != _generation) {
        await controller.dispose();
        return;
      }
      if (_viewers > 0) await controller.play();
      status.value = "playing ${controller.value.size.width.round()}";
      current.value = (folder: folder, albumId: albumId, controller: controller);
    } catch (e) {
      if (generation == _generation) status.value = "failed: $e";
    } finally {
      if (generation == _generation) _busy = false;
    }
  }

  /// Albums without a video (or not reachable) and since when: not asked again for a while.
  final _missingSince = <String, DateTime>{};

  /// Opens a video, silent and looping; null when it cannot be opened (missing on the server, network down).
  Future<VideoPlayerController?> _open(VideoPlayerController controller) async {
    try {
      await controller.initialize().timeout(const Duration(seconds: 20));
      await controller.setVolume(0);
      await controller.setLooping(true);
      return controller;
    } catch (e) {
      lastReason = "$e";
      unawaited(controller.dispose());
      return null;
    }
  }

  // ---- videos kept on the phone, and prepared ahead for the next tracks ----

  static const _maxCacheBytes = 600 * 1024 * 1024;
  final _downloading = <String>{};

  /// Stable file name for an album folder (FNV-1a 64-bit of the folder path).
  static String _nameFor(String folder) {
    var hash = 0xcbf29ce484222325;
    for (final unit in folder.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
    }
    return "${hash.toUnsigned(64).toRadixString(16)}.mp4";
  }

  Future<Directory> _cacheDir() async {
    final dir = Directory(path_helper.join((await getApplicationCacheDirectory()).path, "animated_covers"));
    if (!dir.existsSync()) await dir.create(recursive: true);
    return dir;
  }

  Future<File?> _cachedFile(String folder) async {
    final file = File(path_helper.join((await _cacheDir()).path, _nameFor(folder)));
    if (!file.existsSync() || file.lengthSync() == 0) return null;
    unawaited(file.setLastModified(DateTime.now()).catchError((Object _) {})); // most recently used
    return file;
  }

  /// Keeps the video of [folder] on the phone, then trims the oldest ones above [_maxCacheBytes].
  Future<void> _download(String folder, String url) async {
    if (!_downloading.add(folder)) return;
    try {
      final dir = await _cacheDir();
      final file = File(path_helper.join(dir.path, _nameFor(folder)));
      if (file.existsSync()) return;
      final client = http.Client(); // its own connection, never in the way of the lookups
      final http.Response response;
      try {
        response = await client.get(Uri.parse(url)).timeout(const Duration(minutes: 2));
      } finally {
        client.close();
      }
      if (response.statusCode != 200 || response.bodyBytes.isEmpty) return;
      final partial = File("${file.path}.part");
      await partial.writeAsBytes(response.bodyBytes, flush: true);
      await partial.rename(file.path);
      final files = dir.listSync().whereType<File>().where((f) => f.path.endsWith(".mp4")).toList()
        ..sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
      var total = 0;
      for (final f in files) {
        total += f.lengthSync();
        if (total > _maxCacheBytes) await f.delete();
      }
    } catch (e) {
      _logger.fine("Could not keep the animated cover of $folder: $e");
    } finally {
      _downloading.remove(folder);
    }
  }

  /// Prepares (finds and keeps on the phone) the animated cover of an upcoming track's album.
  Future<void> prepare(String trackFilePath) async {
    final folder = folderOf(trackFilePath);
    if (folder.isEmpty || await _cachedFile(folder) != null) return;
    final url = await forTrackFile(trackFilePath);
    if (url != null) await _download(folder, url);
  }

  bool _preparing = false;

  /// Prepares the animated covers of the next tracks whenever the queue changes, so the cover moves as soon as a
  /// new album starts.
  void startPreparing(Stream<FinampQueueInfo?> queue) {
    if (_preparing) return;
    _preparing = true;
    queue
        .map((info) => [...?info?.nextUp, ...?info?.queue].take(3).map((item) => item.baseItem).toList())
        .debounceTime(const Duration(seconds: 15))
        .asyncMap((items) async {
          if (!(await settings()).enabled) return;
          for (final item in items) {
            try {
              final metadata = await GetIt.instance<ProviderContainer>()
                  .read(metadataProvider(item).future)
                  .timeout(const Duration(seconds: 20));
              final path = metadata?.mediaSourceInfo.path;
              if (path != null && path.isNotEmpty) await prepare(path);
            } catch (e) {
              _logger.fine("Could not prepare the animated cover of ${item.name}: $e");
            }
          }
        })
        .listen((_) {});
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

  /// Whether the server has the file: asks for its first 2 bytes on a fresh connection (no reused connection that
  /// could hang), with a firm time limit.
  Future<int> _exists(String url) async {
    final request = http.Request("GET", Uri.parse(url))
      ..headers["Range"] = "bytes=0-1"
      ..persistentConnection = false;
    final client = http.Client();
    try {
      final response = await client.send(request).timeout(const Duration(seconds: 8));
      unawaited(response.stream.drain<void>().catchError((Object _) {}));
      return response.statusCode;
    } finally {
      client.close();
    }
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
        final status = await _exists(url);
        lastReason = "HTTP $status";
        if (status == 200 || status == 206) {
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
