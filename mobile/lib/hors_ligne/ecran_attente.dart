import 'package:flutter/material.dart';

import '../api/client_api.dart';
import '../api/modeles.dart';
import '../ecrans/communs.dart';
import '../theme/couleurs.dart';
import 'file_attente.dart';
import 'reconnexion.dart';
import 'services.dart';
import 'synchronisation.dart';

/// Enregistrements gardés sur le téléphone (chiffrés) en attente d'envoi.
class EcranAttente extends StatefulWidget {
  const EcranAttente({super.key, required this.api, required this.services, required this.agent});

  final ClientApi api;
  final ServicesHorsLigne services;
  final AgentConnecte agent;

  @override
  State<EcranAttente> createState() => _EcranAttenteState();
}

class _EcranAttenteState extends State<EcranAttente> {
  late final _synchroniseur = Synchroniseur(widget.services.file, widget.api);
  List<ElementAttente> _elements = [];
  final List<String> _illisibles = [];
  bool _enCours = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    _charger();
  }

  Future<void> _charger() async {
    _illisibles.clear();
    final elements = await widget.services.file.lister(illisibles: _illisibles);
    if (mounted) setState(() => _elements = elements);
  }

  Future<void> _action(Future<String?> Function() action) async {
    setState(() {
      _enCours = true;
      _message = null;
    });
    try {
      _message = await action();
    } finally {
      await _charger();
      if (mounted) setState(() => _enCours = false);
    }
  }

  static String _texteIssue(ResultatSync r) => switch (r.issue) {
        IssueSync.envoye => 'Envoyé : numéro ${r.element.numero}.',
        IssueSync.horsLigne => 'Serveur injoignable : réessayez plus tard.',
        IssueSync.reconnexion => 'Connectez-vous en ligne pour envoyer.',
        IssueSync.aVerifier => 'Doublon signalé : vérification nécessaire.',
        IssueSync.erreur => 'Refusé par le serveur : ${r.message}',
      };

  Future<void> _synchroniser() => _action(() async {
        if (!widget.api.connecte) {
          final ok = await demanderReconnexion(context, api: widget.api, services: widget.services, agent: widget.agent);
          if (!ok) return null;
        }
        final b = await _synchroniseur.synchroniserTout();
        return [
          '${b.envoyes.length} envoyé(s)',
          if (b.aVerifier.isNotEmpty) '${b.aVerifier.length} à vérifier',
          if (b.erreurs.isNotEmpty) '${b.erreurs.length} en erreur',
          if (b.arret == IssueSync.horsLigne) 'serveur injoignable',
          if (b.arret == IssueSync.reconnexion) 'reconnexion nécessaire',
        ].join(' · ');
      });

  Future<void> _supprimer(ElementAttente e) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Supprimer cet enregistrement ?'),
        content: Text('${e.nomComplet} (${e.numero ?? e.reference}).\n'
            '${e.numero == null ? "Il n'a jamais été envoyé : toutes ses données seront perdues." : 'La fiche existe déjà sur le serveur ; seules les données restant sur le téléphone seront effacées.'}'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Garder')),
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Supprimer')),
        ],
      ),
    );
    if (ok ?? false) {
      await _action(() async {
        await widget.services.file.supprimer(e.id);
        return 'Enregistrement supprimé du téléphone.';
      });
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: barreHawiya("En attente d'envoi"),
        body: RefreshIndicator(
          onRefresh: _charger,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
            children: [
              const Text(
                'Ces enregistrements sont chiffrés sur le téléphone. Ils sont effacés dès que '
                "l'envoi au serveur a réussi. Le numéro d'identification est attribué à l'envoi.",
                style: TextStyle(color: Colors.black54),
              ),
              const SizedBox(height: 14),
              BoutonPrincipal(
                texte: widget.api.connecte ? 'Synchroniser maintenant' : 'Se connecter et synchroniser',
                icone: Icons.cloud_sync_outlined,
                enCours: _enCours,
                onPressed: _elements.isEmpty ? null : _synchroniser,
              ),
              if (_message != null && _message!.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(_message!, style: const TextStyle(fontWeight: FontWeight.w600)),
              ],
              if (_illisibles.isNotEmpty) ...[
                const SizedBox(height: 12),
                Encadre(
                  titre: '${_illisibles.length} fichier(s) illisible(s)',
                  texte: 'Fichier modifié ou clé de chiffrement perdue : ces données ne peuvent pas être lues.',
                  couleur: Colors.red.shade700,
                  icone: Icons.lock_outline,
                ),
              ],
              const SizedBox(height: 16),
              if (_elements.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Text('Aucun enregistrement en attente.', textAlign: TextAlign.center),
                ),
              for (final e in _elements) _carte(e),
              const PiedPrototype(),
            ],
          ),
        ),
      );

  Widget _carte(ElementAttente e) {
    final (libelle, couleur) = switch (e.statut) {
      StatutAttente.enAttente => (e.numero == null ? 'En attente' : 'Envoi à terminer', Couleurs.vertProfond),
      StatutAttente.aVerifier => ('À vérifier', Couleurs.dore),
      StatutAttente.erreur => ('Erreur', Colors.red.shade700),
    };
    final possible = e.controle?.verdict == VerdictDoublon.doublonPossible;
    return Card(
      color: Colors.white,
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(e.nomComplet, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600))),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(color: couleur.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(99)),
              child: Text(libelle, style: TextStyle(color: couleur, fontWeight: FontWeight.w600)),
            ),
          ]),
          const SizedBox(height: 4),
          Text('${e.numero ?? e.reference} · ${formaterDate(e.creeLe)} · agent ${e.agent} · ${e.doigts.length} doigts',
              style: const TextStyle(color: Colors.black54)),
          if (e.message != null) ...[
            const SizedBox(height: 6),
            Text(e.message!),
          ],
          if (e.controle != null && e.controle!.numeros.isNotEmpty)
            Text('Fiche(s) à vérifier : ${e.controle!.numeros.join(', ')}'),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            if (e.statut == StatutAttente.aVerifier && possible && widget.agent.peutValiderDoublon && widget.api.connecte)
              FilledButton.icon(
                onPressed: _enCours ? null : () => _action(() async => _texteIssue(await _synchroniseur.validerEtEnvoyer(e))),
                icon: const Icon(Icons.admin_panel_settings_outlined),
                label: const Text('Valider (superviseur)'),
              ),
            if (e.statut == StatutAttente.erreur && widget.api.connecte)
              OutlinedButton.icon(
                onPressed: _enCours ? null : () => _action(() async => _texteIssue(await _synchroniseur.reessayer(e))),
                icon: const Icon(Icons.refresh),
                label: const Text('Réessayer'),
              ),
            OutlinedButton.icon(
              onPressed: _enCours ? null : () => _supprimer(e),
              icon: const Icon(Icons.delete_outline),
              label: const Text('Supprimer'),
            ),
          ]),
        ]),
      ),
    );
  }
}
