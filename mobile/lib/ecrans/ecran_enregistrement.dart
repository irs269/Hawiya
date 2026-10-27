import 'package:flutter/material.dart';

import '../api/client_api.dart';
import '../api/modeles.dart';
import '../capture/guidage.dart';
import '../parcours/parcours.dart';
import '../parcours/source_capture.dart';
import '../theme/couleurs.dart';
import 'communs.dart';

/// Parcours Enregistrement des empreintes d'une fiche EXISTANTE (les
/// formulaires de création de fiche arrivent en phase 2) :
/// numéro → vérification de la fiche → 4 étapes de capture → envoi.
/// Le serveur refait le contrôle anti-doublon : en cas de doute, refus, sauf
/// validation par un superviseur.
class EcranEnregistrement extends StatefulWidget {
  const EcranEnregistrement({super.key, required this.api, this.source = const SourceCapture()});

  final ClientApi api;
  final SourceCapture source;

  @override
  State<EcranEnregistrement> createState() => _EcranEnregistrementState();
}

class _EcranEnregistrementState extends State<EcranEnregistrement> {
  final _numero = TextEditingController();
  Citoyen? _citoyen;
  List<DoigtEnvoi>? _doigts; // gardés en mémoire pour une éventuelle validation superviseur
  ResultatEnregistrement? _resultat;
  bool _enCours = false;
  String? _erreur;

  @override
  void dispose() {
    _numero.dispose();
    super.dispose();
  }

  Future<void> _executer(Future<void> Function() action) async {
    setState(() {
      _enCours = true;
      _erreur = null;
    });
    try {
      await action();
    } on ErreurApi catch (e) {
      _erreur = e.message;
    } finally {
      if (mounted) setState(() => _enCours = false);
    }
  }

  Future<void> _rechercher() => _executer(() async {
        final citoyen = await widget.api.lireCitoyen(_numero.text);
        setState(() => _citoyen = citoyen);
      });

  Future<void> _capturer() async {
    final decoupes = await widget.source.capturer(context, EtapeCapture.sequence, 'enregistrement');
    if (decoupes == null || !mounted) return;
    List<DoigtEnvoi> doigts;
    try {
      doigts = await doigtsAEnvoyer(decoupes, lire: widget.source.lire);
    } finally {
      await widget.source.nettoyer();
    }
    if (!mounted) return;
    if (doigts.isEmpty) {
      setState(() => _erreur = 'Aucun doigt net : recommencez la capture.');
      return;
    }
    _doigts = doigts;
    await _envoyer();
  }

  Future<void> _envoyer({bool validationSuperviseur = false}) => _executer(() async {
        final r = await widget.api.enregistrerEmpreintes(
          _citoyen!.numero,
          _doigts!,
          validationSuperviseur: validationSuperviseur,
        );
        setState(() => _resultat = r);
      });

  void _recommencer() => setState(() {
        _citoyen = null;
        _doigts = null;
        _resultat = null;
        _erreur = null;
        _numero.clear();
      });

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: barreHawiya('Enregistrer des empreintes'),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          children: [
            if (_citoyen == null)
              ..._saisieNumero()
            else ...[
              FicheCitoyen(citoyen: _citoyen!),
              const SizedBox(height: 16),
              if (_resultat == null) ..._avantCapture() else ..._apresEnvoi(_resultat!),
            ],
            if (_erreur != null) ...[
              const SizedBox(height: 16),
              Encadre(titre: 'Problème', texte: _erreur, couleur: Colors.red.shade700, icone: Icons.error_outline),
            ],
            const PiedPrototype(),
          ],
        ),
      );

  List<Widget> _saisieNumero() => [
        const Text("Numéro d'identification de la fiche",
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: Couleurs.texte)),
        const SizedBox(height: 12),
        TextField(
          controller: _numero,
          textCapitalization: TextCapitalization.characters,
          decoration: const InputDecoration(hintText: 'KM-2026-000001-X', border: OutlineInputBorder()),
          onSubmitted: (_) => _rechercher(),
        ),
        const SizedBox(height: 16),
        BoutonPrincipal(texte: 'Rechercher la fiche', icone: Icons.search, enCours: _enCours, onPressed: _rechercher),
      ];

  List<Widget> _avantCapture() => [
        const Text(
          'Vérifiez que la fiche est bien celle de la personne présente, puis capturez '
          'ses empreintes : main droite, main gauche, puis les deux pouces.',
          style: TextStyle(color: Colors.black54),
        ),
        const SizedBox(height: 16),
        BoutonPrincipal(
          texte: _enCours ? 'Envoi et contrôle anti-doublon…' : 'Capturer les empreintes',
          icone: Icons.camera_alt_outlined,
          enCours: _enCours,
          onPressed: _capturer,
        ),
        const SizedBox(height: 8),
        BoutonSecondaire(texte: 'Changer de fiche', icone: Icons.swap_horiz, onPressed: _recommencer),
      ];

  List<Widget> _apresEnvoi(ResultatEnregistrement r) {
    if (r.enregistre) {
      return [
        Encadre(
          titre: 'Empreintes enregistrées',
          texte: '${r.doigtsEnregistres.length} doigt(s) enregistré(s)'
              '${r.doigtsIllisibles.isEmpty ? '' : ', ${r.doigtsIllisibles.length} illisible(s)'}.'
              '${r.controle.verdict == VerdictDoublon.aucunDoublon ? '' : '\nDoublon possible validé par un superviseur.'}',
          couleur: Couleurs.vertProfond,
          icone: Icons.check_circle_outline,
        ),
        const SizedBox(height: 20),
        BoutonPrincipal(texte: 'Autre fiche', icone: Icons.person_add_alt, onPressed: _recommencer),
      ];
    }
    final certain = r.controle.verdict == VerdictDoublon.doublonCertain;
    return [
      Encadre(
        titre: certain ? 'Personne déjà enregistrée' : 'Doublon possible',
        texte: '${r.controle.motif}\nFiche(s) à vérifier : ${r.controle.numeros.join(', ')}\n'
            'Les empreintes ne sont PAS enregistrées.',
        couleur: certain ? Colors.red.shade700 : Couleurs.dore,
        icone: certain ? Icons.block : Icons.warning_amber_rounded,
      ),
      const SizedBox(height: 20),
      if (!certain) ...[
        // Le serveur refuse (403) si le compte connecté n'est pas superviseur.
        BoutonPrincipal(
          texte: 'Valider après vérification (superviseur)',
          icone: Icons.admin_panel_settings_outlined,
          enCours: _enCours,
          onPressed: () => _envoyer(validationSuperviseur: true),
        ),
        const SizedBox(height: 8),
      ],
      BoutonSecondaire(texte: 'Abandonner', icone: Icons.close, onPressed: _recommencer),
    ];
  }
}
