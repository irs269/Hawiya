import 'dart:async';

import 'package:flutter/material.dart';

import '../api/client_api.dart';
import '../api/modeles.dart';
import '../capture/ecran_capture.dart';
import '../fiche/ecran_nouvelle_fiche.dart';
import '../hors_ligne/ecran_attente.dart';
import '../hors_ligne/reconnexion.dart';
import '../hors_ligne/services.dart';
import '../hors_ligne/synchronisation.dart';
import '../theme/couleurs.dart';
import 'communs.dart';
import 'ecran_enregistrement.dart';
import 'ecran_identification.dart';
import 'ecran_mot_de_passe.dart';

/// Accueil de l'agent connecté : parcours, enregistrements en attente,
/// synchronisation automatique au retour du réseau.
class EcranAccueil extends StatefulWidget {
  const EcranAccueil({super.key, required this.api, required this.services, required this.agent});

  final ClientApi api;
  final ServicesHorsLigne services;
  final AgentConnecte agent;

  @override
  State<EcranAccueil> createState() => _EcranAccueilState();
}

class _EcranAccueilState extends State<EcranAccueil> {
  late final _synchroniseur = Synchroniseur(widget.services.file, widget.api);
  StreamSubscription<bool>? _abonnementReseau;
  int _enAttente = 0;
  bool _synchronisation = false;

  bool get _enLigne => widget.api.connecte;

  @override
  void initState() {
    super.initState();
    _abonnementReseau = widget.services.reseau.listen((reseau) {
      if (reseau) _synchroniser(silencieux: true);
    });
    _synchroniser(silencieux: true);
  }

  @override
  void dispose() {
    _abonnementReseau?.cancel();
    super.dispose();
  }

  Future<void> _compter() async {
    final n = await widget.services.file.nombre();
    if (mounted) setState(() => _enAttente = n);
  }

  /// Envoie la file d'attente si l'agent est connecté en ligne.
  Future<void> _synchroniser({bool silencieux = false}) async {
    await _compter();
    if (!_enLigne || _enAttente == 0 || _synchronisation) return;
    setState(() => _synchronisation = true);
    final bilan = await _synchroniseur.synchroniserTout();
    if (!mounted) return;
    setState(() => _synchronisation = false);
    await _compter();
    if (!mounted || (silencieux && bilan.traites == 0)) return;
    final morceaux = [
      if (bilan.envoyes.isNotEmpty) '${bilan.envoyes.length} enregistrement(s) envoyé(s)',
      if (bilan.aVerifier.isNotEmpty) '${bilan.aVerifier.length} à vérifier',
      if (bilan.erreurs.isNotEmpty) '${bilan.erreurs.length} en erreur',
      if (bilan.arret == IssueSync.horsLigne) 'serveur injoignable',
      if (bilan.arret == IssueSync.reconnexion) 'reconnexion nécessaire',
    ];
    if (morceaux.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Synchronisation : ${morceaux.join(' · ')}')));
    }
  }

  Future<void> _reconnecter() async {
    final ok = await demanderReconnexion(context, api: widget.api, services: widget.services, agent: widget.agent);
    if (ok && mounted) {
      setState(() {});
      await _synchroniser();
    }
  }

  Future<void> _changerMotDePasse() async {
    final nouveau = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => EcranMotDePasse(api: widget.api, matricule: widget.agent.matricule)),
    );
    if (nouveau == null || !mounted) return;
    // La connexion hors ligne suit le nouveau mot de passe.
    await widget.services.identifiants.memoriser(widget.agent.matricule, nouveau, agent: widget.agent, adresse: widget.api.adresse);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Mot de passe changé.')));
    }
  }

  Future<void> _ouvrir(Widget ecran) async {
    await Navigator.push(context, MaterialPageRoute<void>(builder: (_) => ecran));
    if (mounted) await _synchroniser(silencieux: true);
  }

  void _enLigneSeulement() => ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Disponible seulement en ligne : la comparaison se fait avec toute la base, sur le serveur.'),
      ));

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: barreHawiya('Hawiya', actions: [
          if (_enLigne)
            IconButton(
              tooltip: 'Changer mon mot de passe',
              icon: const Icon(Icons.key_outlined),
              onPressed: _changerMotDePasse,
            ),
          IconButton(
            tooltip: 'Se déconnecter',
            icon: const Icon(Icons.logout),
            onPressed: () async {
              // Révoque la session sur le serveur (les enregistrements en attente restent).
              await widget.api.deconnexion();
              if (context.mounted) Navigator.pop(context);
            },
          ),
        ]),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          children: [
            Text('${widget.agent.nom} · ${widget.agent.matricule}', style: const TextStyle(color: Colors.black54)),
            const SizedBox(height: 12),
            if (!_enLigne) ...[
              Encadre(
                titre: 'Mode hors ligne',
                texte: 'Vous pouvez enregistrer des personnes : elles seront envoyées au serveur '
                    'à la reconnexion. Identification indisponible.',
                couleur: Couleurs.dore,
                icone: Icons.cloud_off_outlined,
              ),
              const SizedBox(height: 8),
              BoutonSecondaire(texte: 'Se connecter en ligne', icone: Icons.cloud_sync_outlined, onPressed: _reconnecter),
              const SizedBox(height: 16),
            ],
            _Tuile(
              icone: Icons.person_add_alt_1_outlined,
              titre: 'Enregistrer une personne',
              texte: 'Identité, domicile, photo, signature et 10 empreintes.',
              onTap: () => _ouvrir(EcranNouvelleFiche(api: widget.api, services: widget.services, agent: widget.agent)),
            ),
            const SizedBox(height: 12),
            _Tuile(
              icone: Icons.fingerprint,
              titre: 'Identifier une personne',
              texte: _enLigne ? 'Scanner une main et retrouver la fiche.' : 'En ligne seulement.',
              discret: !_enLigne,
              onTap: _enLigne ? () => _ouvrir(EcranIdentification(api: widget.api)) : _enLigneSeulement,
            ),
            const SizedBox(height: 12),
            _Tuile(
              icone: Icons.cloud_upload_outlined,
              titre: 'En attente d\'envoi${_enAttente > 0 ? ' ($_enAttente)' : ''}',
              texte: _synchronisation
                  ? 'Synchronisation en cours…'
                  : _enAttente == 0
                      ? 'Tout est envoyé.'
                      : 'Enregistrements gardés (chiffrés) sur le téléphone.',
              onTap: () => _ouvrir(EcranAttente(api: widget.api, services: widget.services, agent: widget.agent)),
            ),
            const SizedBox(height: 12),
            _Tuile(
              icone: Icons.how_to_reg_outlined,
              titre: "Compléter les empreintes d'une fiche",
              texte: _enLigne ? 'Ajouter ou refaire les empreintes d\'une fiche existante.' : 'En ligne seulement.',
              discret: !_enLigne,
              onTap: _enLigne ? () => _ouvrir(EcranEnregistrement(api: widget.api)) : _enLigneSeulement,
            ),
            const SizedBox(height: 12),
            _Tuile(
              icone: Icons.bug_report_outlined,
              titre: 'Test de capture (débogage)',
              texte: 'Capture seule, images gardées pour évaluation.',
              discret: true,
              onTap: () => _ouvrir(const EcranCapture()),
            ),
            const PiedPrototype(),
          ],
        ),
      );
}

class _Tuile extends StatelessWidget {
  const _Tuile({required this.icone, required this.titre, required this.texte, required this.onTap, this.discret = false});

  final IconData icone;
  final String titre;
  final String texte;
  final VoidCallback onTap;
  final bool discret;

  @override
  Widget build(BuildContext context) => Material(
        color: discret ? Colors.white.withValues(alpha: 0.6) : Colors.white,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Row(children: [
              Icon(icone, size: 36, color: discret ? Colors.black45 : Couleurs.vertProfond),
              const SizedBox(width: 16),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(titre, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: Couleurs.texte)),
                  const SizedBox(height: 2),
                  Text(texte, style: const TextStyle(color: Colors.black54)),
                ]),
              ),
              const Icon(Icons.chevron_right, color: Colors.black38),
            ]),
          ),
        ),
      );
}
