import 'package:finamp/components/finamp_app_bar_back_button.dart';
import 'package:finamp/l10n/app_localizations.dart';
import 'package:finamp/services/music_assistant_service.dart';
import 'package:flutter/material.dart';

/// Connection to Music Assistant, to send the music to its players (Apple TV...) from the output menu.
class MusicAssistantSettingsScreen extends StatefulWidget {
  const MusicAssistantSettingsScreen({super.key});

  @override
  State<MusicAssistantSettingsScreen> createState() => _MusicAssistantSettingsScreenState();
}

class _MusicAssistantSettingsScreenState extends State<MusicAssistantSettingsScreen> {
  final _url = TextEditingController();
  final _user = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  String? _result;
  bool _ok = false;

  @override
  void initState() {
    super.initState();
    MusicAssistantService.instance.savedUrl().then((url) {
      if (mounted) setState(() => _url.text = url ?? "https://music.tazr2.ovh");
    });
  }

  @override
  void dispose() {
    _url.dispose();
    _user.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    final l10n = AppLocalizations.of(context)!;
    setState(() => _busy = true);
    try {
      await MusicAssistantService.instance.signIn(_url.text, _user.text.trim(), _password.text);
      final players = await MusicAssistantService.instance.players();
      _ok = true;
      _result = l10n.musicAssistantConnected(players.map((p) => p.name).join(", "));
      _password.clear();
    } catch (e) {
      _ok = false;
      _result = l10n.musicAssistantError(e.toString());
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(leading: const FinampAppBarBackButton(), title: const Text("Music Assistant")),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(l10n.musicAssistantDescription),
          const SizedBox(height: 16),
          TextField(
            controller: _url,
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: InputDecoration(labelText: l10n.musicAssistantUrl),
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
            onPressed: _busy ? null : _signIn,
            child: _busy
                ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : Text(l10n.musicAssistantSignIn),
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
