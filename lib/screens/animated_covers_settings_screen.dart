import 'package:finamp/components/finamp_app_bar_back_button.dart';
import 'package:finamp/l10n/app_localizations.dart';
import 'package:finamp/services/animated_cover_service.dart';
import 'package:finamp/services/queue_service.dart';
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';

/// Animated covers saved by Alacarte next to each album (cover/animated.mp4), served by nginx.
class AnimatedCoversSettingsScreen extends StatefulWidget {
  const AnimatedCoversSettingsScreen({super.key});

  @override
  State<AnimatedCoversSettingsScreen> createState() => _AnimatedCoversSettingsScreenState();
}

class _AnimatedCoversSettingsScreenState extends State<AnimatedCoversSettingsScreen> {
  final _base = TextEditingController();
  final _key = TextEditingController();
  final _prefix = TextEditingController();
  bool _enabled = false;
  bool _testing = false;
  String? _testResult;

  /// Shows the album path from Jellyfin, the address built from it and the server's answer, for the current track.
  Future<void> _test() async {
    final l10n = AppLocalizations.of(context)!;
    final albumId = GetIt.instance<QueueService>().getCurrentTrack()?.baseItem.albumId;
    if (albumId == null) {
      setState(() => _testResult = l10n.animatedCoversTestNoTrack);
      return;
    }
    setState(() => _testing = true);
    await _save();
    String result;
    try {
      final check = await AnimatedCoverService.instance.check(albumId);
      result = [
        "Jellyfin : ${check.path ?? l10n.animatedCoversTestNoPath}",
        if (check.url != null) "URL : ${check.url}",
        if (check.status != null) "HTTP ${check.status} → ${check.found ? "✓" : "✗"}",
      ].join("\n");
    } catch (e) {
      result = "✗ $e";
    }
    if (mounted) {
      setState(() {
        _testing = false;
        _testResult = result;
      });
    }
  }

  @override
  void initState() {
    super.initState();
    AnimatedCoverService.instance.settings().then((config) {
      if (!mounted) return;
      setState(() {
        _enabled = config.enabled;
        _base.text = config.base;
        _key.text = config.key;
        _prefix.text = config.prefix;
      });
    });
  }

  @override
  void dispose() {
    _save();
    _base.dispose();
    _key.dispose();
    _prefix.dispose();
    super.dispose();
  }

  Future<void> _save() =>
      AnimatedCoverService.instance.save(enabled: _enabled, base: _base.text, key: _key.text, prefix: _prefix.text);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(leading: const FinampAppBarBackButton(), title: Text(l10n.animatedCoversTitle)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(l10n.animatedCoversDescription),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(l10n.animatedCoversTitle),
            value: _enabled,
            onChanged: (value) => setState(() => _enabled = value),
          ),
          TextField(
            controller: _base,
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: InputDecoration(labelText: l10n.animatedCoversBase),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _key,
            autocorrect: false,
            decoration: InputDecoration(labelText: l10n.animatedCoversKey, helperText: l10n.animatedCoversKeyHelper),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _prefix,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: l10n.animatedCoversPrefix,
              helperText: l10n.animatedCoversPrefixHelper,
              helperMaxLines: 3,
            ),
          ),
          const SizedBox(height: 20),
          OutlinedButton.icon(
            icon: const Icon(Icons.play_circle_outline),
            label: Text(l10n.animatedCoversTest),
            onPressed: _testing ? null : _test,
          ),
          if (_testResult != null) ...[const SizedBox(height: 12), SelectableText(_testResult!)],
        ],
      ),
    );
  }
}
