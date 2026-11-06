import 'package:finamp/components/AlbumScreen/download_button.dart';
import 'package:finamp/components/AlbumScreen/download_dialog.dart';
import 'package:finamp/components/global_snackbar.dart';
import 'package:finamp/l10n/app_localizations.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/downloads_service.dart';
import 'package:finamp/services/favorite_provider.dart';
import 'package:finamp/services/finamp_settings_helper.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:get_it/get_it.dart';

/// Replaces the heart and download buttons on Apple Music items (served by Allstarr):
///
/// * "Add to Jellyfin": favourites the item, which makes Allstarr download it to the server for good.
/// * "Add to Jellyfin and this phone": the same, then downloads it to the phone like any other download.
class CatalogAddButtons extends ConsumerWidget {
  const CatalogAddButtons({super.key, required this.item, required this.downloadStub, this.children});

  final BaseItemDto item;
  final DownloadStub downloadStub;
  final List<BaseItemDto>? children;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final isOffline = ref.watch(finampSettingsProvider.isOffline);
    final added = ref.watch(isFavoriteProvider(item));
    final status = ref.watch(GetIt.instance<DownloadsService>().statusProvider((downloadStub, children?.length)));
    final onPhone = status.isRequired;

    final addButton = IconButton(
      icon: Icon(added ? TablerIcons.circle_check : TablerIcons.library_plus),
      tooltip: added ? l10n.catalogAddedToJellyfin : l10n.catalogAddToJellyfin,
      onPressed: isOffline || added ? null : () => _addToJellyfin(ref, showMessage: true),
    );

    // Once on the phone, show the usual buttons (sync, delete from the phone...).
    if (onPhone) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          addButton,
          DownloadButton(item: downloadStub, children: children, allowServerDelete: false),
        ],
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        addButton,
        IconButton(
          icon: const Icon(TablerIcons.device_mobile_down),
          tooltip: l10n.catalogAddToJellyfinAndPhone,
          onPressed: isOffline
              ? null
              : () async {
                  if (!added) _addToJellyfin(ref, showMessage: false);
                  await DownloadDialog.show(context, downloadStub, null, trackCount: children?.length);
                },
        ),
      ],
    );
  }

  void _addToJellyfin(WidgetRef ref, {required bool showMessage}) {
    ref.read(isFavoriteProvider(item).notifier).updateFavorite(true);
    if (showMessage) {
      GlobalSnackbar.message((context) => AppLocalizations.of(context)!.catalogAddedToJellyfinMessage);
    }
  }
}
