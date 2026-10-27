import 'package:flutter/material.dart';

import '../api/client_api.dart';
import '../api/modeles.dart';
import '../capture/ecran_capture.dart';
import '../hors_ligne/services.dart';
import '../theme/couleurs.dart';
import 'communs.dart';
import 'ecran_accueil.dart';

/// Connexion de l'agent (matricule + mot de passe) et adresse du serveur.
///
/// Sans réseau, un agent déjà connecté une fois EN LIGNE sur ce téléphone peut
/// se reconnecter hors ligne : il peut alors enregistrer (mis en attente),
/// mais ni identifier ni synchroniser.
class EcranConnexion extends StatefulWidget {
  const EcranConnexion({super.key, required this.services, this.fabriqueClient = _clientParDefaut});

  final ServicesHorsLigne services;

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
  void initState() {
    super.initState();
    widget.services.identifiants.derniereAdresse().then((a) {
      if (a != null && mounted) _adresse.text = a;
    });
  }

  @override
  void dispose() {
    _adresse.dispose();
    _matricule.dispose();
    _motDePasse.dispose();
    super.dispose();
  }

  Future<void> _seConnecter() async {
    final matricule = _matricule.text.trim();
    final motDePasse = _motDePasse.text;
    if (matricule.isEmpty || motDePasse.isEmpty) {
      setState(() => _erreur = 'Saisissez le matricule et le mot de passe.');
      return;
    }
    setState(() {
      _enCours = true;
      _erreur = null;
    });
    final api = widget.fabriqueClient(_adresse.text);
    try {
      AgentConnecte agent;
      try {
        await api.connexion(matricule, motDePasse);
        agent = await api.moi();
        // Pour pouvoir se reconnecter plus tard sans réseau.
        await widget.services.identifiants.memoriser(matricule, motDePasse, agent: agent, adresse: api.adresse);
      } on ErreurApi catch (e) {
        if (e.code != null) rethrow; // refus du serveur : pas de repli hors ligne
        final connu = await widget.services.identifiants.verifier(matricule, motDePasse);
        if (connu == null) {
          throw const ErreurApi(
            'Serveur injoignable. La connexion hors ligne n\'est possible qu\'après une première '
            'connexion en ligne sur ce téléphone, avec le même matricule et mot de passe.',
          );
        }
        agent = connu;
      }
      if (!mounted) return;
      _motDePasse.clear();
      await Navigator.push(
        context,
        MaterialPageRoute<void>(builder: (_) => EcranAccueil(api: api, services: widget.services, agent: agent)),
      );
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
              Text('Hawiya', style: Theme.of(context).textTheme.headlineMedium?.copyWith(color: Couleurs.vertProfond, fontSize: 36)),
              const Text('Votre main suffit.', style: TextStyle(fontSize: 16, color: Couleurs.dore)),
              const SizedBox(height: 28),
              TextField(
                controller: _matricule,
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(labelText: 'Matricule agent'),
                textInputAction: TextInputAction.next,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _motDePasse,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'Mot de passe'),
                onSubmitted: (_) => _seConnecter(),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _adresse,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: 'Adresse du serveur',
                  helperText: 'Ex. http://192.168.1.10:8000 (PC sur le même Wi-Fi)',
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
