import 'package:finamp/components/finamp_app_bar_back_button.dart';
import 'package:finamp/l10n/app_localizations.dart';
import 'package:finamp/services/alacarte_service.dart';
import 'package:flutter/material.dart';

/// Connection to the Alacarte server, used to show the real download progress of Apple Music albums.
class AlacarteSettingsScreen extends StatefulWidget {
  const AlacarteSettingsScreen({super.key});

  @override
  State<AlacarteSettingsScreen> createState() => _AlacarteSettingsScreenState();
}

class _AlacarteSettingsScreenState extends State<AlacarteSettingsScreen> {
  final _url = TextEditingController();
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
        _user.text = config.username;
        _password.text = config.password;
      });
    });
  }

  @override
  void dispose() {
    _url.dispose();
    _user.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context)!;
    if (_url.text.trim().isEmpty) {
      await AlacarteService.instance.saveConfig(null);
      setState(() {
        _ok = false;
        _result = l10n.alacarteDisconnected;
      });
      return;
    }
    final config = AlacarteConfig(url: _url.text, username: _user.text.trim(), password: _password.text);
    setState(() => _busy = true);
    final error = await AlacarteService.instance.testConnection(config);
    if (error == null) await AlacarteService.instance.saveConfig(config);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _ok = error == null;
      _result = error == null ? l10n.alacarteConnected : l10n.alacarteConnectionFailed(error);
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
            decoration: InputDecoration(labelText: l10n.alacarteUrl, hintText: "http://192.168.1.10:3000"),
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
