import 'package:finamp/components/finamp_app_bar_back_button.dart';
import 'package:finamp/l10n/app_localizations.dart';
import 'package:finamp/services/alacarte_service.dart';
import 'package:finamp/services/finamp_user_helper.dart';
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';

/// Connection to the Alacarte server, used to show the real download progress of Apple Music albums.
class AlacarteSettingsScreen extends StatefulWidget {
  const AlacarteSettingsScreen({super.key});

  @override
  State<AlacarteSettingsScreen> createState() => _AlacarteSettingsScreenState();
}

class _AlacarteSettingsScreenState extends State<AlacarteSettingsScreen> {
  final _url = TextEditingController();
  final _outsideUrl = TextEditingController();
  final _user = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  String? _result;
  bool _ok = false;

  @override
  void initState() {
    super.initState();
    AlacarteService.instance.readConfig().then((config) {
      if (config == null || !mounted) return;
      setState(() {
        _url.text = config.url;
        _outsideUrl.text = config.outsideUrl;
        _user.text = config.username;
        _password.text = config.password;
      });
    });
  }

  @override
  void dispose() {
    _url.dispose();
    _outsideUrl.dispose();
    _user.dispose();
    _password.dispose();
    super.dispose();
  }

  /// The Jellyfin server's public address with /alacarte, the path to add on the same reverse proxy.
  String? get _suggestedOutsideUrl {
    final address = GetIt.instance<FinampUserHelper>().currentUser?.publicAddress;
    final base = address == null ? null : AlacarteConfig.normalize(address);
    return base == null ? null : "$base/alacarte";
  }

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context)!;
    final config = AlacarteConfig(
      url: _url.text,
      outsideUrl: _outsideUrl.text,
      username: _user.text.trim(),
      password: _password.text,
    );
    if (config.addresses.isEmpty) {
      await AlacarteService.instance.saveConfig(null);
      setState(() {
        _ok = false;
        _result = l10n.alacarteDisconnected;
      });
      return;
    }
    setState(() => _busy = true);
    final results = await AlacarteService.instance.testConnection(config);
    final anyOk = results.values.any((error) => error == null);
    if (anyOk) await AlacarteService.instance.saveConfig(config);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _ok = anyOk;
      _result = results.entries
          .map((e) => e.value == null ? "✓ ${e.key}" : "✗ ${e.key}\n   ${l10n.alacarteConnectionFailed(e.value!)}")
          .join("\n");
      if (anyOk && results.values.any((error) => error != null)) {
        _result = "${_result!}\n\n${l10n.alacartePartlyConnected}";
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(leading: const FinampAppBarBackButton(), title: Text(l10n.alacarteSettingsTitle)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(l10n.alacarteSettingsDescription),
          const SizedBox(height: 16),
          TextField(
            controller: _url,
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: l10n.alacarteUrl,
              hintText: "http://192.168.1.10:7373",
              helperText: l10n.alacarteUrlHelper,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _outsideUrl,
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: l10n.alacarteOutsideUrl,
              hintText: _suggestedOutsideUrl ?? "https://example.com/alacarte",
              helperText: l10n.alacarteOutsideUrlHelper,
              helperMaxLines: 4,
            ),
          ),
          if (_suggestedOutsideUrl != null)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () => setState(() => _outsideUrl.text = _suggestedOutsideUrl!),
                child: Text(l10n.alacarteUseServerAddress(_suggestedOutsideUrl!)),
              ),
            ),
          const SizedBox(height: 12),
          TextField(
            controller: _user,
            autocorrect: false,
            decoration: InputDecoration(labelText: l10n.username),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _password,
            obscureText: true,
            decoration: InputDecoration(labelText: l10n.password),
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: _busy ? null : _save,
            child: _busy
                ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : Text(l10n.alacarteSaveAndTest),
          ),
          if (_result != null) ...[
            const SizedBox(height: 16),
            Text(_result!, style: TextStyle(color: _ok ? Colors.green : Theme.of(context).colorScheme.error)),
          ],
        ],
      ),
    );
  }
}
