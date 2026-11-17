import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A player of Music Assistant (e.g. an Apple TV through AirPlay).
class MusicAssistantPlayer {
  MusicAssistantPlayer({required this.id, required this.name, required this.available});

  final String id;
  final String name;
  final bool available;
}

class MusicAssistantException implements Exception {
  MusicAssistantException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Talks to the user's Music Assistant server over its WebSocket API (`/ws`), to send what Finamp plays to one of
/// its players. Music Assistant then reads the tracks from Jellyfin itself and plays them on the device, so the
/// phone is only a remote.
class MusicAssistantService {
  MusicAssistantService._();
  static final instance = MusicAssistantService._();

  static final _logger = Logger("MusicAssistant");
  static const _urlKey = "musicAssistant.url";
  static const _tokenKey = "musicAssistant.token";

  Future<({String url, String token})?> readConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final url = prefs.getString(_urlKey);
    final token = prefs.getString(_tokenKey);
    if (url == null || url.isEmpty || token == null || token.isEmpty) return null;
    return (url: url, token: token);
  }

  Future<String?> savedUrl() async => (await SharedPreferences.getInstance()).getString(_urlKey);

  Future<void> forget() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tokenKey);
  }

  static String normalizeUrl(String value) {
    var url = value.trim();
    if (!url.startsWith("http://") && !url.startsWith("https://")) url = "https://$url";
    while (url.endsWith("/")) {
      url = url.substring(0, url.length - 1);
    }
    return url;
  }

  /// Signs in with the Music Assistant account and keeps a long-lived token named "Finamp" (not the password).
  Future<void> signIn(String url, String username, String password) async {
    final base = normalizeUrl(url);
    final connection = await _Connection.open(base);
    try {
      final login = await connection.call("auth/login", {
        "username": username,
        "password": password,
        "device_name": "Finamp",
      });
      final accessToken = login is Map ? login["access_token"] as String? : null;
      if (accessToken == null) {
        throw MusicAssistantException((login is Map ? login["error"]?.toString() : null) ?? "login failed");
      }
      await connection.call("auth", {"token": accessToken});
      final longLived = await connection.call("auth/token/create", {"name": "Finamp"});
      if (longLived is! String) throw MusicAssistantException("no token returned");
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_urlKey, base);
      await prefs.setString(_tokenKey, longLived);
    } finally {
      await connection.close();
    }
  }

  Future<T> _withConnection<T>(Future<T> Function(_Connection connection) action) async {
    final config = await readConfig();
    if (config == null) throw MusicAssistantException("not configured");
    final connection = await _Connection.open(config.url);
    try {
      await connection.call("auth", {"token": config.token});
      return await action(connection);
    } finally {
      await connection.close();
    }
  }

  Future<List<MusicAssistantPlayer>> players() => _withConnection((connection) async {
    final result = await connection.call("players/all");
    final players = <MusicAssistantPlayer>[];
    for (final raw in (result as List? ?? const [])) {
      if (raw is! Map) continue;
      if (raw["enabled"] == false || raw["hidden"] == true || raw["hide_in_ui"] == true) continue;
      players.add(
        MusicAssistantPlayer(
          id: raw["player_id"].toString(),
          name: (raw["display_name"] ?? raw["name"] ?? raw["player_id"]).toString(),
          available: raw["available"] != false,
        ),
      );
    }
    players.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return players;
  });

  /// Replaces the queue of [playerId] with the Jellyfin tracks [trackIds] (Music Assistant's Jellyfin provider
  /// uses the same ids) and starts the first one at [startPosition].
  Future<void> play(String playerId, List<String> trackIds, Duration startPosition) =>
      _withConnection((connection) async {
        await connection.call("player_queues/play_media", {
          "queue_id": playerId,
          "media": [for (final id in trackIds) "jellyfin://track/$id"],
          "option": "replace",
          "start_position": startPosition.inMilliseconds / 1000.0,
        });
      });

  void log(Object e) => _logger.warning("Music Assistant: $e");
}

/// One WebSocket connection: waits for the server info, then sends commands one at a time.
class _Connection {
  _Connection._(this._socket) {
    _subscription = _socket.listen(
      (data) {
        try {
          final message = jsonDecode(data as String);
          if (message is! Map) return;
          final id = message["message_id"]?.toString();
          if (id == null) {
            if (!_ready.isCompleted) _ready.complete(); // first message: server info
            return;
          }
          final pending = _pending.remove(id);
          if (pending == null) return;
          if (message.containsKey("error_code")) {
            pending.completeError(
              MusicAssistantException(
                (message["details"] ?? message["message"] ?? "error ${message["error_code"]}").toString(),
              ),
            );
          } else {
            pending.complete(message["result"]);
          }
        } catch (_) {}
      },
      onDone: () {
        for (final pending in _pending.values) {
          pending.completeError(MusicAssistantException("connection closed"));
        }
        _pending.clear();
      },
    );
  }

  final WebSocket _socket;
  late final StreamSubscription<dynamic> _subscription;
  final _ready = Completer<void>();
  final _pending = <String, Completer<dynamic>>{};
  int _nextId = 1;

  static Future<_Connection> open(String baseUrl) async {
    final uri = Uri.parse(baseUrl);
    final ws = uri.replace(scheme: uri.scheme == "https" ? "wss" : "ws", path: "${uri.path}/ws");
    final socket = await WebSocket.connect(ws.toString()).timeout(const Duration(seconds: 10));
    final connection = _Connection._(socket);
    await connection._ready.future.timeout(const Duration(seconds: 10), onTimeout: () {});
    return connection;
  }

  Future<dynamic> call(String command, [Map<String, Object?>? args]) {
    final id = "${_nextId++}";
    final completer = Completer<dynamic>();
    _pending[id] = completer;
    _socket.add(jsonEncode({"message_id": id, "command": command, "args": ?args}));
    return completer.future.timeout(const Duration(seconds: 20));
  }

  Future<void> close() async {
    await _subscription.cancel();
    await _socket.close();
  }
}
