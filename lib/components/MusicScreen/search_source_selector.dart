import 'package:finamp/l10n/app_localizations.dart';
import 'package:finamp/services/search_source_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

/// "Jellyfin | Apple Music" switch shown under the search bar, like the
/// "Apple Music | Your Library" switch of the Apple Music app.
class SearchSourceSelector extends ConsumerWidget {
  const SearchSourceSelector({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final source = ref.watch(searchSourceProvider);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: SizedBox(
        width: double.infinity,
        child: SegmentedButton<SearchSource>(
          showSelectedIcon: false,
          style: SegmentedButton.styleFrom(visualDensity: VisualDensity.compact),
          segments: [
            ButtonSegment(
              value: SearchSource.jellyfin,
              icon: const Icon(TablerIcons.books),
              label: Text(l10n.searchSourceJellyfin),
            ),
            ButtonSegment(
              value: SearchSource.appleMusic,
              icon: const Icon(TablerIcons.brand_apple),
              label: Text(l10n.searchSourceAppleMusic),
            ),
          ],
          selected: {source},
          onSelectionChanged: (selection) => ref.read(searchSourceProvider.notifier).state = selection.first,
        ),
      ),
    );
  }
}
