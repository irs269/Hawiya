import 'package:flutter/material.dart';

import '../api/client_api.dart';
import '../api/modeles.dart';
import '../capture/guidage.dart';
import '../parcours/parcours.dart';
import '../parcours/source_capture.dart';
import '../theme/couleurs.dart';
import 'communs.dart';

/// Parcours Identification : scan d'une main → réponse du serveur.
///
/// Trois réponses : identifié (fiche), non enregistré, non concluant. En cas de
/// « non concluant », l'agent rescanne (les scans sont combinés, 3 au plus) ;
/// après le 3e, vérification manuelle sur pièce d'identité. Aucune fiche n'est
/// affichée si le serveur ne répond pas « identifié ».
class EcranIdentification extends StatefulWidget {
  const EcranIdentification({super.key, required this.api, this.source = const SourceCapture()});

  final ClientApi api;
  final SourceCapture source;

  /// Il faut au moins 3 doigts nets pour que le serveur puisse conclure.
  static const doigtsNetsMin = 3;

  @override
  State<EcranIdentification> createState() => _EcranIdentificationState();
}

class _EcranIdentificationState extends State<EcranIdentification> {
  final _parcours = ParcoursIdentification();
  String _main = 'droite';
  bool _enCours = false;
  String? _erreur;

  EtapeCapture get _etape => EtapeCapture.sequence.firstWhere(
        (e) => e.main == _main && e.type == TypeEtape.quatreDoigts,
      );

  Future<void> _scanner() async {
    setState(() => _erreur = null);
    final decoupes = await widget.source.capturer(context, [_etape], 'identification');
    if (decoupes == null || !mounted) return;

    List<DoigtEnvoi> doigts;
    try {
      doigts = await doigtsAEnvoyer(decoupes, lire: widget.source.lire);
    } finally {
      await widget.source.nettoyer();
    }
    if (!mounted) return;
    if (doigts.length < EcranIdentification.doigtsNetsMin) {
      setState(() => _erreur = 'Seulement ${doigts.length} doigt(s) net(s) : recommencez le scan '
          '(main à plat, doigts écartés, bien éclairés).');
      return;
    }

    final scans = _parcours.ajouterScan(doigts);
    setState(() => _enCours = true);
    try {
      final reponse = await widget.api.identifier(scans);
      _parcours.enregistrerReponse(reponse);
    } on ErreurApi catch (e) {
      _parcours.annulerDernierScan();
      _erreur = e.message;
    } finally {
      if (mounted) setState(() => _enCours = false);
    }
  }

  void _nouvelleIdentification() => setState(() {
        _parcours.recommencer();
        _erreur = null;
      });

  @override
  Widget build(BuildContext context) {
    final reponse = _parcours.reponse;
    return Scaffold(
      appBar: barreHawiya('Identifier une personne'),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        children: [
          if (reponse == null) ..._avantScan() else ..._resultat(reponse),
          if (_erreur != null) ...[
            const SizedBox(height: 16),
            Encadre(titre: 'Problème', texte: _erreur, couleur: Colors.red.shade700, icone: Icons.error_outline),
          ],
          const PiedPrototype(),
        ],
      ),
    );
  }

  List<Widget> _avantScan() => [
        const Text('Quelle main allez-vous scanner ?',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: Couleurs.texte)),
        const SizedBox(height: 12),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'droite', label: Text('Main droite')),
            ButtonSegment(value: 'gauche', label: Text('Main gauche')),
          ],
          selected: {_main},
          onSelectionChanged: _parcours.nombreScans > 0 ? null : (s) => setState(() => _main = s.first),
        ),
        const SizedBox(height: 12),
        Text(_etape.consigne, style: const TextStyle(color: Colors.black54)),
        const SizedBox(height: 20),
        BoutonPrincipal(
          texte: _enCours ? 'Comparaison en cours…' : 'Scanner la main',
          icone: Icons.camera_alt_outlined,
          enCours: _enCours,
          onPressed: _scanner,
        ),
      ];

  List<Widget> _resultat(ReponseIdentification r) {
    switch (r.verdict) {
      case VerdictIdentification.identifie:
        return [
          Encadre(
            titre: 'Personne identifiée',
            texte: '${r.doigtsConcordants} doigts sur ${r.doigtsCompares} concordent.',
            couleur: Couleurs.vertProfond,
            icone: Icons.verified_user_outlined,
          ),
          const SizedBox(height: 12),
          if (r.citoyen != null) FicheCitoyen(citoyen: r.citoyen!),
          const SizedBox(height: 20),
          BoutonPrincipal(texte: 'Nouvelle identification', icone: Icons.fingerprint, onPressed: _nouvelleIdentification),
        ];
      case VerdictIdentification.nonEnregistre:
        return [
          const Encadre(
            titre: 'Personne non enregistrée',
            texte: 'Aucune fiche de la base ne correspond à cette main.',
            couleur: Couleurs.texte,
            icone: Icons.person_off_outlined,
          ),
          const SizedBox(height: 20),
          BoutonPrincipal(texte: 'Nouvelle identification', icone: Icons.fingerprint, onPressed: _nouvelleIdentification),
        ];
      case VerdictIdentification.nonConcluant:
        if (_parcours.verificationManuelle) {
          return [
            const Encadre(
              titre: 'Vérification manuelle',
              texte: "Après ${ParcoursIdentification.scansMax} scans, le résultat reste incertain. "
                  "Vérifiez l'identité sur une pièce d'identité. Aucune fiche n'est affichée pour éviter "
                  "toute erreur de personne.",
              couleur: Couleurs.dore,
              icone: Icons.badge_outlined,
            ),
            const SizedBox(height: 20),
            BoutonPrincipal(texte: 'Nouvelle identification', icone: Icons.fingerprint, onPressed: _nouvelleIdentification),
          ];
        }
        return [
          Encadre(
            titre: 'Résultat non concluant',
            texte: '${r.motif}\nAucune fiche n\'est affichée tant que le résultat n\'est pas sûr.',
            couleur: Couleurs.dore,
            icone: Icons.help_outline,
          ),
          const SizedBox(height: 20),
          BoutonPrincipal(
            texte: _enCours
                ? 'Comparaison en cours…'
                : 'Rescanner (scan ${_parcours.nombreScans + 1} sur ${ParcoursIdentification.scansMax})',
            icone: Icons.camera_alt_outlined,
            enCours: _enCours,
            onPressed: _scanner,
          ),
          const SizedBox(height: 8),
          BoutonSecondaire(texte: 'Abandonner', icone: Icons.close, onPressed: _nouvelleIdentification),
        ];
    }
  }
}
