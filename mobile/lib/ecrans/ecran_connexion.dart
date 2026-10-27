import 'package:flutter/material.dart';

import '../api/client_api.dart';
import '../api/modeles.dart';
import '../capture/ecran_capture.dart';
import '../hors_ligne/appareil.dart';
import '../hors_ligne/services.dart';
import '../theme/couleurs.dart';
import 'communs.dart';
import 'ecran_accueil.dart';
import 'ecran_mot_de_passe.dart';

/// Crée le client de l'API (remplaçable dans les tests).
typedef FabriqueClient = ClientApi Function(
  String adresse, {
  required String identifiantAppareil,
  Future<void> Function(String? jeton)? surRenouvellement,
});

ClientApi _clientParDefaut(String adresse, {required String identifiantAppareil, Future<void> Function(String?)? surRenouvellement}) =>
    ClientApi(adresse, identifiantAppareil: identifiantAppareil, nomAppareil: 'Téléphone Hawiya', surRenouvellement: surRenouvellement);

/// Connexion de l'agent : matricule, mot de passe, adresse du serveur.
///
/// - Ce téléphone doit être approuvé par un superviseur (code affiché).
/// - Mot de passe provisoire : changement obligatoire avant de continuer.
/// - Au démarrage, la session précédente reprend sans mot de passe si elle est encore valable.
/// - Sans réseau, un agent déjà connecté EN LIGNE sur ce téléphone depuis
///   moins de 7 jours peut se connecter pour enregistrer (mis en attente).
class EcranConnexion extends StatefulWidget {
  const EcranConnexion({super.key, required this.services, this.fabriqueClient = _clientParDefaut});

  final ServicesHorsLigne services;
  final FabriqueClient fabriqueClient;

  @override
  State<EcranConnexion> createState() => _EcranConnexionState();
}

class _EcranConnexionState extends State<EcranConnexion> {
  // Adresse du PC qui fait tourner docker compose, sur le même Wi-Fi.
  final _adresse = TextEditingController(text: 'http://192.168.1.10:8000');
  final _matricule = TextEditingController();
  final _motDePasse = TextEditingController();
  bool _enCours = false;
  bool _reprise = true;
  String? _erreur;
  String? _codeAttente;

  ServicesHorsLigne get _services => widget.services;

  @override
  void initState() {
    super.initState();
    _demarrer();
  }

  @override
  void dispose() {
    _adresse.dispose();
    _matricule.dispose();
    _motDePasse.dispose();
    super.dispose();
  }

  Future<ClientApi> _client(String adresse) async {
    final normalisee = ClientApi.normaliserAdresse(adresse);
    return widget.fabriqueClient(
      normalisee,
      identifiantAppareil: await _services.appareil.identifiant(),
      surRenouvellement: (jeton) => _services.appareil.memoriserSession(adresse: normalisee, jeton: jeton),
    );
  }

  /// Adresse mémorisée, puis reprise de la session précédente si possible.
  Future<void> _demarrer() async {
    final adresse = await _services.identifiants.derniereAdresse();
    if (adresse != null && mounted) _adresse.text = adresse;
    final session = await _services.appareil.sessionMemorisee();
    if (session != null) {
      final api = await _client(session.adresse);
      if (await api.reprendre(session.jeton)) {
        try {
          final agent = await api.moi();
          if (mounted && !agent.doitChangerMotDePasse) {
            setState(() => _reprise = false);
            await _ouvrirAccueil(api, agent);
            return;
          }
        } on ErreurApi {
          // Session inutilisable : connexion normale.
        }
      }
    }
    if (mounted) setState(() => _reprise = false);
  }

  Future<void> _ouvrirAccueil(ClientApi api, AgentConnecte agent) async {
    _motDePasse.clear();
    await Navigator.push(
      context,
      MaterialPageRoute<void>(builder: (_) => EcranAccueil(api: api, services: _services, agent: agent)),
    );
  }

  Future<void> _seConnecter() async {
    final matricule = _matricule.text.trim().toUpperCase();
    var motDePasse = _motDePasse.text;
    if (matricule.isEmpty || motDePasse.isEmpty) {
      setState(() => _erreur = 'Saisissez le matricule et le mot de passe.');
      return;
    }
    setState(() {
      _enCours = true;
      _erreur = null;
      _codeAttente = null;
    });
    final api = await _client(_adresse.text);
    try {
      final provisoire = await api.connexion(matricule, motDePasse);
      if (provisoire) {
        if (!mounted) return;
        final nouveau = await Navigator.push<String>(
          context,
          MaterialPageRoute(builder: (_) => EcranMotDePasse(api: api, matricule: matricule, ancien: motDePasse, obligatoire: true)),
        );
        if (nouveau == null) {
          await api.deconnexion();
          return;
        }
        motDePasse = nouveau;
      }
      final agent = await api.moi();
      // Pour pouvoir se reconnecter plus tard sans réseau (7 jours).
      await _services.identifiants.memoriser(matricule, motDePasse, agent: agent, adresse: api.adresse);
      if (mounted) await _ouvrirAccueil(api, agent);
    } on ErreurApi catch (e) {
      await _traiterErreur(e, matricule, motDePasse);
    } finally {
      if (mounted) setState(() => _enCours = false);
    }
  }

  Future<void> _traiterErreur(ErreurApi e, String matricule, String motDePasse) async {
    switch (e.raison) {
      case 'appareil_en_attente':
        setState(() => _codeAttente = e.codeAppareil);
      case 'appareil_revoque':
        // Téléphone déclaré perdu ou volé : plus aucune connexion hors ligne.
        await _services.identifiants.oublierTout();
        await _services.appareil.reinitialiser();
        setState(() => _erreur = '${e.message}\nUn nouveau code sera demandé à la prochaine connexion.');
      default:
        if (e.code != null) {
          setState(() => _erreur = e.message);
          return;
        }
        // Serveur injoignable : connexion hors ligne.
        final r = await _services.identifiants.verifier(matricule, motDePasse);
        if (r.agent != null && mounted) {
          await _ouvrirAccueil(await _client(_adresse.text), r.agent!);
        } else {
          setState(() => _erreur = r.message);
        }
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
              if (_reprise)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Center(child: Text('Reprise de la session…')),
                )
              else ...[
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
                if (_codeAttente != null) ...[
                  const SizedBox(height: 16),
                  Encadre(
                    titre: 'Téléphone à faire approuver',
                    texte: 'Donnez ce code à votre superviseur, puis reconnectez-vous une fois '
                        "qu'il l'a approuvé :\n$_codeAttente",
                    couleur: Couleurs.dore,
                    icone: Icons.phonelink_lock,
                  ),
                ],
                if (_erreur != null) ...[
                  const SizedBox(height: 12),
                  Text(_erreur!, style: const TextStyle(color: Colors.red)),
                ],
                const SizedBox(height: 20),
                BoutonPrincipal(texte: 'Se connecter', icone: Icons.login, enCours: _enCours, onPressed: _seConnecter),
                const SizedBox(height: 8),
                FutureBuilder<String>(
                  future: _services.appareil.identifiant(),
                  builder: (_, s) => Text(
                    s.hasData ? 'Code de ce téléphone : ${IdentiteAppareil.code(s.data!)}' : '',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.black45, fontSize: 12),
                  ),
                ),
                TextButton(
                  // Sans serveur : capture seule, pour l'évaluation des images.
                  onPressed: () =>
                      Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const EcranCapture())),
                  child: const Text('Test de capture (sans serveur)'),
                ),
              ],
              const PiedPrototype(),
            ],
          ),
        ),
      );
}
