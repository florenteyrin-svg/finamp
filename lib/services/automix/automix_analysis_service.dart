import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'automix_models.dart';

/// Runs the native analyzer and caches results (memory + disk), keyed by Jellyfin item id.
class AutoMixAnalysisService {
  static final _logger = Logger("AutoMixAnalysis");
  static const _channel = MethodChannel("com.unicornsonlsd.finamp/automix_analyzer");

  final _memory = <String, AutoMixAnalysis>{};
  final _inFlight = <String, Future<AutoMixAnalysis?>>{};
  final _failed = <String, DateTime>{};

  /// Last analysis error, for diagnostics.
  String? lastError;
  Directory? _cacheDir;

  static const _memoryEntries = 64;

  AutoMixAnalysis? cached(String itemId) => _memory[itemId];

  Future<Directory> _dir() async {
    if (_cacheDir != null) return _cacheDir!;
    final base = await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, "automix_cache"));
    if (!await dir.exists()) await dir.create(recursive: true);
    return _cacheDir = dir;
  }

  /// Returns the analysis of [itemId], decoding [uri] if needed. Never throws.
  Future<AutoMixAnalysis?> analyze(String itemId, Uri uri) {
    final hit = _memory[itemId];
    if (hit != null) return Future.value(hit);
    final pending = _inFlight[itemId];
    if (pending != null) return pending;
    final failedAt = _failed[itemId];
    if (failedAt != null && DateTime.now().difference(failedAt) < const Duration(minutes: 10)) {
      return Future.value(null);
    }
    final future = _analyze(itemId, uri).whenComplete(() => _inFlight.remove(itemId));
    _inFlight[itemId] = future;
    return future;
  }

  Future<AutoMixAnalysis?> _analyze(String itemId, Uri uri) async {
    // disk cache
    File? file;
    try {
      file = File(p.join((await _dir()).path, "${_safe(itemId)}.json"));
      if (await file.exists()) {
        final map = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        if (map["version"] == AutoMixAnalysis.formatVersion) {
          final analysis = AutoMixAnalysis.fromMap(map);
          _remember(itemId, analysis);
          return analysis;
        }
      }
    } catch (e) {
      _logger.warning("Could not read cached analysis for $itemId: $e");
    }

    final stopwatch = Stopwatch()..start();
    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>("analyze", {
        "uri": uri.isScheme("file") ? uri.toFilePath() : uri.toString(),
        "headMs": 30000,
        "tailMs": 45000,
      }).timeout(const Duration(seconds: 90));
      if (result == null) return null;
      final analysis = AutoMixAnalysis.fromMap(result);
      _logger.info(
        "Analyzed $itemId in ${stopwatch.elapsedMilliseconds}ms: "
        "head ${analysis.head.bpm.toStringAsFixed(1)} BPM (conf ${analysis.head.confidence.toStringAsFixed(2)}), "
        "tail ${analysis.tail?.bpm.toStringAsFixed(1)} BPM (conf ${analysis.tail?.confidence.toStringAsFixed(2)})",
      );
      _remember(itemId, analysis);
      try {
        await file?.writeAsString(jsonEncode(analysis.toMap()));
      } catch (e) {
        _logger.warning("Could not cache analysis: $e");
      }
      return analysis;
    } catch (e) {
      _logger.warning("Analysis of $itemId failed: $e");
      lastError = e is PlatformException
          ? (e.message ?? e.code)
          : e is TimeoutException
          ? "délai dépassé (90 s)"
          : e.toString();
      _failed[itemId] = DateTime.now();
      return null;
    }
  }

  void _remember(String itemId, AutoMixAnalysis analysis) {
    _memory.remove(itemId);
    _memory[itemId] = analysis;
    while (_memory.length > _memoryEntries) {
      _memory.remove(_memory.keys.first);
    }
  }

  static String _safe(String id) => id.replaceAll(RegExp(r"[^A-Za-z0-9_-]"), "_");
}
