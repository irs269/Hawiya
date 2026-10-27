import 'package:flutter/material.dart';

import '../api/client_api.dart';
import '../capture/ecran_capture.dart';
import '../theme/couleurs.dart';
import 'communs.dart';
import 'ecran_accueil.dart';

/// Connexion de l'agent (matricule + mot de passe) et adresse du serveur.
class EcranConnexion extends StatefulWidget {
  const EcranConnexion({super.key, this.fabriqueClient = _clientParDefaut});

  /// Remplaçable dans les tests (faux serveur).
  final ClientApi Function(String adresse) fabriqueClient;

  static ClientApi _clientParDefaut(String adresse) => ClientApi(adresse);

  @override
  State<EcranConnexion> createState() => _EcranConnexionState();
}

class _EcranConnexionState extends State<EcranConnexion> {
  // Adresse du PC qui fait tourner docker compose, sur le même Wi-Fi.
  final _adresse = TextEditingController(text: 'http://192.168.1.10:8000');
  final _matricule = TextEditingController();
  final _motDePasse = TextEditingController();
  bool _enCours = false;
  String? _erreur;

  @override
  void dispose() {
    _adresse.dispose();
    _matricule.dispose();
    _motDePasse.dispose();
    super.dispose();
  }

  Future<void> _seConnecter() async {
    if (_matricule.text.trim().isEmpty || _motDePasse.text.isEmpty) {
      setState(() => _erreur = 'Saisissez le matricule et le mot de passe.');
      return;
    }
    setState(() {
      _enCours = true;
      _erreur = null;
    });
    final api = widget.fabriqueClient(_adresse.text);
    try {
      await api.connexion(_matricule.text, _motDePasse.text);
      if (!mounted) return;
      _motDePasse.clear();
      await Navigator.push(context, MaterialPageRoute<void>(builder: (_) => EcranAccueil(api: api)));
    } on ErreurApi catch (e) {
      if (mounted) setState(() => _erreur = e.message);
    } finally {
      if (mounted) setState(() => _enCours = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 32, 20, 24),
            children: [
              const Text('Hawiya',
                  style: TextStyle(fontSize: 36, fontWeight: FontWeight.w700, color: Couleurs.vertProfond)),
              const Text('Votre main suffit.', style: TextStyle(fontSize: 16, color: Couleurs.dore)),
              const SizedBox(height: 28),
              TextField(
                controller: _matricule,
                decoration: const InputDecoration(labelText: 'Matricule agent', border: OutlineInputBorder()),
                textInputAction: TextInputAction.next,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _motDePasse,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'Mot de passe', border: OutlineInputBorder()),
                onSubmitted: (_) => _seConnecter(),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _adresse,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: 'Adresse du serveur',
                  helperText: 'Ex. http://192.168.1.10:8000 (PC sur le même Wi-Fi)',
                  border: OutlineInputBorder(),
                ),
              ),
              if (_erreur != null) ...[
                const SizedBox(height: 12),
                Text(_erreur!, style: const TextStyle(color: Colors.red)),
              ],
              const SizedBox(height: 20),
              BoutonPrincipal(texte: 'Se connecter', icone: Icons.login, enCours: _enCours, onPressed: _seConnecter),
              const SizedBox(height: 8),
              TextButton(
                // Sans serveur : capture seule, pour l'évaluation des images.
                onPressed: () =>
                    Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const EcranCapture())),
                child: const Text('Test de capture (sans serveur)'),
              ),
              const PiedPrototype(),
            ],
          ),
        ),
      );
}
