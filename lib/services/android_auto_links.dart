import 'package:audio_service/audio_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';

import '../components/global_snackbar.dart';
import '../models/finamp_models.dart';
import '../models/jellyfin_models.dart';
import 'android_auto_helper.dart';
import 'artist_content_provider.dart';
import 'queue_service.dart';

final _logger = Logger("AndroidAutoLinks");

/// Tappable album and artist names on Android Auto's "now playing" screen.
///
/// The current track's metadata carries the ids below (KEY_SUBTITLE_LINK_MEDIA_ID / KEY_DESCRIPTION_LINK_MEDIA_ID
/// from androidx.car.app.mediaextensions). Tapping the artist or the album opens that id in the browse view:
/// * album: "Play album" then its tracks,
/// * artist: "Play all" / "Shuffle" then every track of the artist.
class AndroidAutoLinks {
  AndroidAutoLinks._();

  static const subtitleLinkKey = "androidx.car.app.mediaextensions.KEY_SUBTITLE_LINK_MEDIA_ID";
  static const descriptionLinkKey = "androidx.car.app.mediaextensions.KEY_DESCRIPTION_LINK_MEDIA_ID";

  static const _prefix = "finamp-link:";

  static String albumId(BaseItemId id) => "${_prefix}album:${id.raw}";
  static String artistId(BaseItemId id) => "${_prefix}artist:${id.raw}";

  /// "Now playing" tab of the browse view: the album and the artist of the current track.
  static const nowPlayingId = "${_prefix}now-playing";

  static bool handles(String mediaId) => mediaId.startsWith(_prefix);

  /// Children of [nowPlayingId] for the track [current] (from the player's current media item).
  static List<MediaItem> nowPlayingChildren(MediaItem? current) {
    final json = current?.extras?["itemJson"];
    if (json is! Map) return [];
    final item = BaseItemDto.fromJson(Map<String, dynamic>.from(json));
    final l10n = GlobalSnackbar.requireL10n;
    final artist = item.artistItems?.firstOrNull ?? item.albumArtists?.firstOrNull;
    return [
      if (item.albumId != null)
        MediaItem(
          id: albumId(item.albumId!),
          title: l10n.androidAutoCurrentAlbum(item.album ?? ""),
          artUri: current?.artUri,
          playable: false,
        ),
      if (artist != null)
        MediaItem(
          id: artistId(artist.id),
          title: l10n.androidAutoCurrentArtist(artist.name ?? item.albumArtist ?? ""),
          playable: false,
        ),
    ];
  }

  /// Display fields and link extras for the now-playing metadata of [item] (a track).
  /// Subtitle = artist (opens the artist), description = album (opens the album).
  static ({String? subtitle, String? description, Map<String, String> extras}) forTrack(BaseItemDto item) {
    if (item.type != "Audio") return (subtitle: null, description: null, extras: const {});
    final artist = item.artistItems?.firstOrNull ?? item.albumArtists?.firstOrNull;
    final artistNames = item.artists?.join(", ") ?? item.albumArtist;
    final extras = <String, String>{};
    if (artist != null && (artistNames?.isNotEmpty ?? false)) extras[subtitleLinkKey] = artistId(artist.id);
    if (item.albumId != null && (item.album?.isNotEmpty ?? false)) extras[descriptionLinkKey] = albumId(item.albumId!);
    return (subtitle: artistNames, description: item.album, extras: extras);
  }

  static ({String kind, BaseItemId id, String? action})? _parse(String mediaId) {
    final parts = mediaId.substring(_prefix.length).split(":");
    if (parts.length < 2) return null;
    return (kind: parts[0], id: BaseItemId(parts[1]), action: parts.length > 2 ? parts.sublist(2).join(":") : null);
  }

  /// The browsable node itself (Android Auto asks for it before opening it).
  static Future<MediaItem?> getItem(String mediaId) async {
    if (mediaId == nowPlayingId) {
      return MediaItem(id: mediaId, title: GlobalSnackbar.requireL10n.androidAutoNowPlaying, playable: false);
    }
    final link = _parse(mediaId);
    if (link == null || link.action != null) return null;
    final item = await GetIt.instance<AndroidAutoHelper>().getParentFromId(link.id);
    return MediaItem(id: mediaId, title: item?.name ?? "", playable: false);
  }

  static Future<List<BaseItemDto>> _tracks(String kind, BaseItemId id) async {
    final helper = GetIt.instance<AndroidAutoHelper>();
    if (kind == "album") {
      return helper.getBaseItems(
        MediaItemId(contentType: ContentType.albums, parentType: MediaItemParentType.collection, itemId: id),
      );
    }
    final artist = await helper.getParentFromId(id);
    if (artist == null) return [];
    return GetIt.instance<ProviderContainer>().read(getArtistTracksProvider(artist: artist).future);
  }

  static Future<List<MediaItem>> getChildren(String mediaId) async {
    final link = _parse(mediaId);
    if (link == null) return [];
    final queueService = GetIt.instance<QueueService>();
    final l10n = GlobalSnackbar.requireL10n;
    final tracks = await _tracks(link.kind, link.id);
    final out = <MediaItem>[
      MediaItem(id: "$mediaId:play", title: l10n.playButtonLabel, playable: true),
      if (link.kind == "artist") MediaItem(id: "$mediaId:shuffle", title: l10n.shuffleButtonLabel, playable: true),
    ];
    // Long artists: list the first ones ("Play" and "Shuffle" still play everything).
    for (var i = 0; i < tracks.length && i < 300; i++) {
      final generated = await queueService.generateMediaItem(
        tracks[i],
        parentType: MediaItemParentType.collection,
        parentId: link.id,
      );
      out.add(generated.copyWith(id: "$mediaId:track:$i", playable: true));
    }
    return out;
  }

  /// "Play", "Shuffle" or a track: plays the whole album / artist, starting at that track.
  static Future<void> play(String mediaId) async {
    final link = _parse(mediaId);
    if (link == null || link.action == null) return;
    final tracks = await _tracks(link.kind, link.id);
    if (tracks.isEmpty) return;
    final parent = await GetIt.instance<AndroidAutoHelper>().getParentFromId(link.id);
    final action = link.action!;
    final startingIndex = action.startsWith("track:") ? int.tryParse(action.substring(6)) ?? 0 : 0;
    try {
      await GetIt.instance<QueueService>().startPlayback(
        items: tracks,
        startingIndex: startingIndex.clamp(0, tracks.length - 1),
        order: action == "shuffle" ? FinampPlaybackOrder.shuffled : FinampPlaybackOrder.linear,
        source: QueueItemSource(
          type: link.kind == "album" ? QueueItemSourceType.album : QueueItemSourceType.artist,
          name: QueueItemSourceName(type: QueueItemSourceNameType.preTranslated, pretranslatedName: parent?.name),
          id: link.id,
          item: parent,
        ),
      );
    } catch (e) {
      _logger.severe("Could not play $mediaId", e);
    }
  }

  /// Player buttons (they work while driving, unlike browsing): replace the queue with the whole album of the
  /// current track, in order from its first track, or with every track of its artist, shuffled.
  static Future<void> playFromCurrent(MediaItem? current, {required bool album}) async {
    final json = current?.extras?["itemJson"];
    if (json is! Map) return;
    final item = BaseItemDto.fromJson(Map<String, dynamic>.from(json));
    final artist = item.artistItems?.firstOrNull ?? item.albumArtists?.firstOrNull;
    final BaseItemId? parentId = album ? item.albumId : artist?.id;
    if (parentId == null) return;
    final kind = album ? "album" : "artist";
    final tracks = await _tracks(kind, parentId);
    if (tracks.isEmpty) return;
    final parent = await GetIt.instance<AndroidAutoHelper>().getParentFromId(parentId);
    await GetIt.instance<QueueService>().startPlayback(
      items: tracks,
      startingIndex: album ? 0 : null,
      order: album ? FinampPlaybackOrder.linear : FinampPlaybackOrder.shuffled,
      source: QueueItemSource(
        type: album ? QueueItemSourceType.album : QueueItemSourceType.artist,
        name: QueueItemSourceName(type: QueueItemSourceNameType.preTranslated, pretranslatedName: parent?.name),
        id: parentId,
        item: parent,
      ),
    );
  }
}
