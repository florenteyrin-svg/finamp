import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/jellyfin_models.dart';

/// Where a search on the music screen looks, like the "Apple Music" /
/// "Your Library" switch of the Apple Music app.
///
/// The server sits behind Allstarr, which merges catalogue results (served by
/// Alacarte / Apple Music) into every Jellyfin search. Allstarr gives every
/// catalogue item an id starting with `ext-` (`ext-{provider}-{type}-{id}`),
/// so that prefix is what tells the two sources apart.
enum SearchSource {
  jellyfin,
  appleMusic;

  bool accepts(BaseItemDto item) => switch (this) {
    SearchSource.jellyfin => !isCatalogItem(item),
    SearchSource.appleMusic => isCatalogItem(item),
  };
}

/// Whether [item] comes from the Apple Music catalogue (through Allstarr)
/// rather than from the Jellyfin library.
bool isCatalogItem(BaseItemDto item) => item.id.raw.toLowerCase().startsWith("ext-");

/// The source the search bar currently looks in. Defaults to Jellyfin.
final searchSourceProvider = StateProvider<SearchSource>((ref) => SearchSource.jellyfin);
