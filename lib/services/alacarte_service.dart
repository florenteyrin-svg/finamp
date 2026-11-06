import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:get_it/get_it.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/jellyfin_models.dart';
import 'finamp_user_helper.dart';

/// Talks to the user's Alacarte server (the Apple Music downloader behind Allstarr) to show the real
/// download progress of Apple Music albums, as computed by Alacarte itself: finished tracks, the
/// track being downloaded and the FLAC conversion.
///
/// Alacarte's queue API needs a signed-in session, so Finamp signs in with the Alacarte account.
class AlacarteService {
  AlacarteService._();
  static final instance = AlacarteService._();

  static final _logger = Logger("Alacarte");
  static const _urlKey = "alacarte.url"; // address at home
  static const _outsideUrlKey = "alacarte.outsideUrl"; // address from outside, through the reverse proxy
  static const _userKey = "alacarte.username";
  static const _passwordKey = "alacarte.password";

  final _client = http.Client();
  String? _cookie;

  /// The address that answered last; tried first next time.
  String? _activeBase;

  Future<AlacarteConfig?> readConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final config = AlacarteConfig(
      url: prefs.getString(_urlKey) ?? "",
      outsideUrl: prefs.getString(_outsideUrlKey) ?? "",
      username: prefs.getString(_userKey) ?? "",
      password: prefs.getString(_passwordKey) ?? "",
    );
    return config.isComplete ? config : null;
  }

  Future<void> saveConfig(AlacarteConfig? config) async {
    final prefs = await SharedPreferences.getInstance();
    if (config == null) {
      for (final key in [_urlKey, _outsideUrlKey, _userKey, _passwordKey]) {
        await prefs.remove(key);
      }
    } else {
      await prefs.setString(_urlKey, config.url.trim());
      await prefs.setString(_outsideUrlKey, config.outsideUrl.trim());
      await prefs.setString(_userKey, config.username);
      await prefs.setString(_passwordKey, config.password);
    }
    _cookie = null;
    _activeBase = null;
  }

  /// The configured addresses, plus the server's own address with /alacarte when no outside address is set:
  /// the path to add on the reverse proxy (nginx) that already serves Allstarr, so no other domain is needed.
  static List<String> withServerAddress(AlacarteConfig config) {
    if (config.outsideUrl.trim().isNotEmpty) return config.addresses;
    final server = GetIt.instance<FinampUserHelper>().currentUser?.publicAddress;
    final base = server == null ? null : AlacarteConfig.normalize(server);
    return {...config.addresses, if (base != null) "$base/alacarte"}.toList();
  }

  /// Signs in on every configured address. Returns, per address, null when it works or the error.
  Future<Map<String, String?>> testConnection(AlacarteConfig config) async {
    final results = <String, String?>{};
    for (final base in withServerAddress(config)) {
      try {
        _cookie = null;
        await _login(config, base);
        await _getFrom(config, base, "/api/queue");
        results[base] = null;
      } catch (e) {
        results[base] = e.toString();
      }
    }
    _cookie = null;
    _activeBase = null;
    return results;
  }

  Future<void> _login(AlacarteConfig config, String base) async {
    final response = await _client
        .post(
          Uri.parse("$base/api/auth/login"),
          headers: {
            "Content-Type": "application/json",
            // Alacarte refuses state-changing requests from another origin.
            "Origin": Uri.parse(base).origin,
          },
          body: jsonEncode({"username": config.username, "password": config.password}),
        )
        .timeout(const Duration(seconds: 6));
    if (response.statusCode != 200) {
      throw AlacarteException(_errorMessage(response));
    }
    final setCookie = response.headers["set-cookie"];
    if (setCookie == null) throw AlacarteException("no session cookie in the login response");
    // Keep only "name=value" of each cookie (http joins several Set-Cookie headers with commas).
    _cookie = RegExp(r'(?:^|,)\s*([^=;,\s]+=[^;,]*)')
        .allMatches(setCookie)
        .map((m) => m.group(1)!)
        .where((c) => !c.toLowerCase().startsWith("expires=") && !c.toLowerCase().startsWith("max-age="))
        .join("; ");
  }

  /// GET on the address that answered last, falling back to the other one (home / outside).
  Future<Map<String, dynamic>> _get(AlacarteConfig config, String path) async {
    final addresses = withServerAddress(config);
    final ordered = [
      if (_activeBase != null && addresses.contains(_activeBase)) _activeBase!,
      ...addresses.where((a) => a != _activeBase),
    ];
    Object? lastError;
    for (final base in ordered) {
      try {
        if (base != _activeBase) {
          _cookie = null;
          _activeBase = base;
        }
        return await _getFrom(config, base, path);
      } catch (e) {
        lastError = e;
        _activeBase = null;
      }
    }
    throw lastError ?? AlacarteException("no Alacarte address configured");
  }

  Future<Map<String, dynamic>> _getFrom(AlacarteConfig config, String base, String path, {bool retried = false}) async {
    if (_cookie == null) await _login(config, base);
    final response = await _client
        .get(Uri.parse("$base$path"), headers: {"Cookie": _cookie!})
        // Short, so an unreachable home address quickly falls back to the outside one.
        .timeout(const Duration(seconds: 4));
    if (response.statusCode == 401 && !retried) {
      _cookie = null;
      return _getFrom(config, base, path, retried: true);
    }
    if (response.statusCode != 200) throw AlacarteException(_errorMessage(response));
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  String _errorMessage(http.Response response) {
    try {
      final error = (jsonDecode(response.body) as Map<String, dynamic>)["error"];
      if (error is String) return "${response.statusCode}: $error";
    } catch (_) {}
    return "HTTP ${response.statusCode}";
  }

  /// Current and recently finished Alacarte jobs.
  Future<List<AlacarteJob>> jobs(AlacarteConfig config) async {
    final queue = await _get(config, "/api/queue");
    final history = await _get(config, "/api/queue/history?limit=200");
    final byId = <String, AlacarteJob>{};
    for (final raw in [...(history["jobs"] as List? ?? []), ...(queue["jobs"] as List? ?? [])]) {
      if (raw is! Map<String, dynamic>) continue;
      final job = AlacarteJob.fromJson(raw);
      byId[job.id] = job; // queue entries come last and are the freshest
    }
    return byId.values.toList();
  }

  /// The Apple Music album id of an Allstarr album id (`ext-{provider}-album-{id}`), or null.
  static String? appleAlbumId(BaseItemDto item) {
    final match = RegExp(r'^ext-.+-album-(.+)$', caseSensitive: false).firstMatch(item.id.raw);
    return match?.group(1);
  }

  void log(Object e) => _logger.fine("Alacarte progress unavailable: $e");
}

class AlacarteException implements Exception {
  AlacarteException(this.message);
  final String message;
  @override
  String toString() => message;
}

class AlacarteConfig {
  AlacarteConfig({required this.url, this.outsideUrl = "", required this.username, required this.password});

  /// Address at home, e.g. http://192.168.1.10:7373 (optional).
  final String url;

  /// Address from outside, e.g. https://my-domain/alacarte behind the same reverse proxy as Jellyfin (optional).
  final String outsideUrl;
  final String username;
  final String password;

  bool get isComplete => username.isNotEmpty && password.isNotEmpty;

  /// Configured addresses, home first.
  List<String> get addresses => [url, outsideUrl].map(normalize).nonNulls.toSet().toList();

  static String? normalize(String value) {
    var out = value.trim();
    if (out.isEmpty) return null;
    if (!out.startsWith("http://") && !out.startsWith("https://")) out = "http://$out";
    while (out.endsWith("/")) {
      out = out.substring(0, out.length - 1);
    }
    return out;
  }
}

class AlacarteJob {
  AlacarteJob({
    required this.id,
    required this.kind,
    required this.status,
    required this.progress,
    this.albumId,
    this.songId,
    this.updatedAt = 0,
    this.statsTotal,
    this.statsDone,
  });

  factory AlacarteJob.fromJson(Map<String, dynamic> json) {
    final stats = json["stats"];
    return AlacarteJob(
      id: json["id"].toString(),
      kind: json["kind"]?.toString() ?? "",
      status: json["status"]?.toString() ?? "",
      progress: (json["progress"] as num?)?.toDouble() ?? 0,
      albumId: json["albumId"]?.toString(),
      songId: json["songId"]?.toString(),
      updatedAt: (json["updatedAt"] as num?)?.toInt() ?? 0,
      statsTotal: stats is Map ? (stats["total"] as num?)?.toInt() : null,
      statsDone: stats is Map ? (stats["done"] as num?)?.toInt() : null,
    );
  }

  final String id;
  final String kind; // album, song, playlist
  final String status; // queued, running, done, failed
  final double progress; // 0 to 100, computed by Alacarte
  final String? albumId;
  final String? songId;
  final int updatedAt;
  final int? statsTotal;
  final int? statsDone;

  bool get active => status == "queued" || status == "running";
}

/// Server download progress of one Apple Music album, from Alacarte's own numbers.
class AlbumServerProgress {
  const AlbumServerProgress({required this.percent, required this.active, required this.failed});

  /// 0 to 100.
  final int percent;

  /// Something is still queued or downloading.
  final bool active;

  /// Some tracks failed.
  final bool failed;

  bool get finished => !active && percent >= 100;

  /// Combines the Alacarte jobs of the album [appleAlbumId] ([trackCount] tracks), or null if
  /// Alacarte has nothing for it.
  static AlbumServerProgress? from(List<AlacarteJob> jobs, String appleAlbumId, int trackCount) {
    final mine = jobs.where((j) => j.albumId == appleAlbumId && j.kind != "playlist").toList();
    if (mine.isEmpty) return null;

    // A whole-album job already carries the album's percentage.
    final albumJobs = mine.where((j) => j.kind == "album").toList()..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    if (albumJobs.isNotEmpty) {
      final job = albumJobs.first;
      return AlbumServerProgress(
        percent: job.status == "done" ? 100 : job.progress.round().clamp(0, 100),
        active: job.active,
        failed: job.status == "failed",
      );
    }

    // Otherwise one job per track (how Allstarr asks for them): finished tracks plus the
    // progress of the ones in flight, over the album's track count.
    final latestPerSong = <String, AlacarteJob>{};
    for (final job in mine) {
      final key = job.songId ?? job.id;
      final previous = latestPerSong[key];
      if (previous == null || job.updatedAt >= previous.updatedAt) latestPerSong[key] = job;
    }
    final songs = latestPerSong.values;
    final total = trackCount > songs.length ? trackCount : songs.length;
    var units = 0.0;
    for (final job in songs) {
      units += job.status == "done" ? 1 : (job.active ? job.progress.clamp(0, 100) / 100 : 0);
    }
    // Tracks already on the server get no job: once nothing is left in flight, the album is complete.
    // Allstarr may still be asking for the next tracks though, so wait a bit before calling it done.
    final lastUpdate = songs.map((j) => j.updatedAt).fold(0, (a, b) => a > b ? a : b);
    final recentlyBusy = DateTime.now().millisecondsSinceEpoch - lastUpdate < 20000;
    final active = songs.any((j) => j.active) || (songs.length < trackCount && recentlyBusy);
    final percent = active ? (units / total * 100).floor().clamp(0, 99) : 100;
    return AlbumServerProgress(percent: percent, active: active, failed: songs.any((j) => j.status == "failed"));
  }
}

/// Progress read from Allstarr itself, on the address Finamp already uses for the server: no other address or
/// login needed. Allstarr lists the tracks it is fetching (`/api/admin/downloads/queue`) with their real
/// progress, and keeps finished ones for a few minutes.
class AllstarrDownloads {
  AllstarrDownloads._();

  static final _client = http.Client();

  /// Allstarr's download entries, or null if this server has no such list (not Allstarr, or another version).
  static Future<List<Map<String, dynamic>>?> fetch(String serverUrl) async {
    final base = AlacarteConfig.normalize(serverUrl);
    if (base == null) return null;
    final response = await _client
        .get(Uri.parse("$base/api/admin/downloads/queue"))
        .timeout(const Duration(seconds: 6));
    if (response.statusCode != 200) return null;
    final body = jsonDecode(response.body);
    if (body is! List) return null;
    return body.whereType<Map<String, dynamic>>().toList();
  }

  /// Combines the entries of the album's tracks ([trackIds], Allstarr ids `ext-{provider}-song-{id}`).
  static AlbumServerProgress? progress(List<Map<String, dynamic>> entries, List<String> trackIds) {
    if (trackIds.isEmpty) return null;
    final externalIds = {for (final id in trackIds) id.substring(id.lastIndexOf("-") + 1): id};
    final mine = entries.where((e) {
      final songId = e["SongId"]?.toString();
      final externalId = e["ExternalId"]?.toString();
      return trackIds.contains(songId) || (externalId != null && externalIds.containsKey(externalId));
    }).toList();
    if (mine.isEmpty) return null;

    // DownloadStatus: 0 NotStarted, 1 InProgress, 2 Completed, 3 Failed (as numbers or names)
    int status(Map<String, dynamic> e) => switch (e["Status"]) {
      final int n => n,
      "NotStarted" => 0,
      "InProgress" => 1,
      "Completed" => 2,
      "Failed" => 3,
      _ => -1,
    };
    var units = 0.0;
    var lastUpdate = 0;
    for (final e in mine) {
      final s = status(e);
      units += s == 2 ? 1 : (s == 1 ? ((e["Progress"] as num?)?.toDouble() ?? 0).clamp(0, 1) : 0);
      for (final key in ["CompletedAt", "StartedAt"]) {
        final t = DateTime.tryParse(e[key]?.toString() ?? "")?.millisecondsSinceEpoch ?? 0;
        if (t > lastUpdate) lastUpdate = t;
      }
    }
    final recentlyBusy = DateTime.now().millisecondsSinceEpoch - lastUpdate < 20000;
    final active = mine.any((e) => status(e) <= 1) || (mine.length < trackIds.length && recentlyBusy);
    final percent = active ? (units / trackIds.length * 100).floor().clamp(0, 99) : 100;
    return AlbumServerProgress(percent: percent, active: active, failed: mine.any((e) => status(e) == 3));
  }
}

/// Server progress of an Apple Music album: from Alacarte when it is set up in the settings, otherwise from
/// Allstarr on the server address. [trackIdsKey] is the album's track ids joined with commas.
final serverAlbumProgressProvider = StreamProvider.autoDispose.family<AlbumServerProgress?, (String, String)>((
  ref,
  args,
) async* {
  final (appleAlbumId, trackIdsKey) = args;
  final trackIds = trackIdsKey.isEmpty ? <String>[] : trackIdsKey.split(",");
  final alacarte = await AlacarteService.instance.readConfig();
  var stop = false;
  ref.onDispose(() => stop = true);
  while (!stop) {
    AlbumServerProgress? progress;
    try {
      if (alacarte != null) {
        progress = AlbumServerProgress.from(
          await AlacarteService.instance.jobs(alacarte),
          appleAlbumId,
          trackIds.length,
        );
      } else {
        final server = GetIt.instance<FinampUserHelper>().currentUser?.baseURL;
        final entries = server == null ? null : await AllstarrDownloads.fetch(server);
        if (entries == null) {
          // This server does not publish its downloads: nothing to show, stop asking.
          yield null;
          return;
        }
        progress = AllstarrDownloads.progress(entries, trackIds);
      }
    } catch (e) {
      AlacarteService.instance.log(e);
    }
    yield progress;
    await Future<void>.delayed(const Duration(milliseconds: 1500));
  }
});
