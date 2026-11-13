import 'dart:async';
import 'dart:convert';

import 'package:hive_ce/hive.dart';
import 'package:logging/logging.dart';

import '../models/finamp_models.dart';
import '../models/jellyfin_models.dart';

/// Keeps the tracks (and their sources) of the saved queue on the device, so the queue is restored at startup
/// without asking the server for every track first: with a long playlist that took a long time, and nothing
/// could play until it was done. Stored as JSON, one entry per item id.
class QueueItemCache {
  QueueItemCache._();

  static const boxName = "QueueItemCache";
  static final _logger = Logger("QueueItemCache");

  /// Above this, entries that are no longer in the queue are dropped.
  static const _maxEntries = 6000;

  static Box<String>? get _box => Hive.isBoxOpen(boxName) ? Hive.box<String>(boxName) : null;

  /// Stores the items of [queue] that are not cached yet.
  static void remember(FinampQueueInfo queue) {
    final box = _box;
    if (box == null) return;
    try {
      final entries = <String, String>{};
      final keep = <String>{};
      void add(String? id, Object? json) {
        if (id == null || json == null) return;
        keep.add(id);
        if (!box.containsKey(id) && !entries.containsKey(id)) entries[id] = jsonEncode(json);
      }

      for (final queueItem in queue.fullQueue) {
        final json = queueItem.item.extras?["itemJson"];
        if (json is Map) add(json["Id"]?.toString(), json);
        final source = queueItem.source.item;
        if (source != null) add(source.id.raw, source.toJson(setOffline: false));
      }
      if (entries.isNotEmpty) unawaited(box.putAll(entries));
      if (box.length + entries.length > _maxEntries) {
        unawaited(box.deleteAll(box.keys.where((key) => !keep.contains(key)).toList()));
      }
    } catch (e) {
      _logger.warning("Could not cache queue items: $e");
    }
  }

  /// The cached items among [ids].
  static Map<BaseItemId, BaseItemDto> lookup(Iterable<BaseItemId> ids) {
    final box = _box;
    final out = <BaseItemId, BaseItemDto>{};
    if (box == null) return out;
    for (final id in ids) {
      final raw = box.get(id.raw);
      if (raw == null) continue;
      try {
        out[id] = BaseItemDto.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      } catch (e) {
        _logger.fine("Dropping unreadable cached item ${id.raw}: $e");
        unawaited(box.delete(id.raw));
      }
    }
    return out;
  }
}
