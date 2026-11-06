import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/jellyfin_models.dart';

/// Talks to the user's Alacarte server (the Apple Music downloader behind Allstarr) to show the real
/// download progress of Apple Music albums, as computed by Alacarte itself: finished tracks, the
/// track being downloaded and the FLAC conversion.
///
/// Alacarte's queue API needs a signed-in session, so Finamp signs in with the Alacarte account.
class AlacarteService {
  AlacarteService._();
  static final instance = AlacarteService._();

  static final _logger = Logger("Alacarte");
  static const _urlKey = "alacarte.url";
  static const _userKey = "alacarte.username";
  static const _passwordKey = "alacarte.password";

  final _client = http.Client();
  String? _cookie;

  Future<AlacarteConfig?> readConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final url = prefs.getString(_urlKey);
    final user = prefs.getString(_userKey);
    final password = prefs.getString(_passwordKey);
    if (url == null || url.isEmpty || user == null || user.isEmpty || password == null) return null;
    return AlacarteConfig(url: url, username: user, password: password);
  }

  Future<void> saveConfig(AlacarteConfig? config) async {
    final prefs = await SharedPreferences.getInstance();
    if (config == null) {
      await prefs.remove(_urlKey);
      await prefs.remove(_userKey);
      await prefs.remove(_passwordKey);
    } else {
      await prefs.setString(_urlKey, config.normalizedUrl);
      await prefs.setString(_userKey, config.username);
      await prefs.setString(_passwordKey, config.password);
    }
    _cookie = null;
  }

  /// Signs in and returns null, or the error to show.
  Future<String?> testConnection(AlacarteConfig config) async {
    try {
      _cookie = null;
      await _login(config);
      await _get(config, "/api/queue");
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  Future<void> _login(AlacarteConfig config) async {
    final base = Uri.parse(config.normalizedUrl);
    final response = await _client
        .post(
          base.resolve("/api/auth/login"),
          headers: {
            "Content-Type": "application/json",
            // Alacarte refuses state-changing requests from another origin.
            "Origin": base.origin,
          },
          body: jsonEncode({"username": config.username, "password": config.password}),
        )
        .timeout(const Duration(seconds: 15));
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

  Future<Map<String, dynamic>> _get(AlacarteConfig config, String path, {bool retried = false}) async {
    if (_cookie == null) await _login(config);
    final response = await _client
        .get(Uri.parse(config.normalizedUrl).resolve(path), headers: {"Cookie": _cookie!})
        .timeout(const Duration(seconds: 15));
    if (response.statusCode == 401 && !retried) {
      _cookie = null;
      return _get(config, path, retried: true);
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
  AlacarteConfig({required this.url, required this.username, required this.password});
  final String url;
  final String username;
  final String password;

  String get normalizedUrl {
    var value = url.trim();
    if (!value.startsWith("http://") && !value.startsWith("https://")) value = "http://$value";
    while (value.endsWith("/")) {
      value = value.substring(0, value.length - 1);
    }
    return value;
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

/// Polls Alacarte every second and a half while the album screen shows it.
final albumServerProgressProvider = StreamProvider.autoDispose.family<AlbumServerProgress?, (String, int)>((
  ref,
  args,
) async* {
  final (appleAlbumId, trackCount) = args;
  final service = AlacarteService.instance;
  final config = await service.readConfig();
  if (config == null) {
    yield null;
    return;
  }
  var stop = false;
  ref.onDispose(() => stop = true);
  while (!stop) {
    try {
      yield AlbumServerProgress.from(await service.jobs(config), appleAlbumId, trackCount);
    } catch (e) {
      service.log(e);
      yield null;
    }
    await Future<void>.delayed(const Duration(milliseconds: 1500));
  }
});
