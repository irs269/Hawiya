import 'package:flutter/material.dart';

import '../api/client_api.dart';
import '../api/modeles.dart';
import '../capture/guidage.dart';
import '../ecrans/communs.dart';
import '../hors_ligne/file_attente.dart';
import '../hors_ligne/services.dart';
import '../hors_ligne/synchronisation.dart';
import '../parcours/parcours.dart';
import '../parcours/source_capture.dart';
import '../theme/couleurs.dart';
import 'envoi.dart';
import 'etapes_formulaire.dart';
import 'fiche.dart';
import 'signature.dart';
import 'source_photo.dart';

/// Doigts (ISO 19794) capturés à chaque étape de capture.
List<int> isoDeLEtape(EtapeCapture e) {
  final base = e.main == 'droite' ? 0 : 5;
  return e.type == TypeEtape.pouce ? [base + 1] : [base + 2, base + 3, base + 4, base + 5];
}

/// Parcours Enregistrement complet (phase 2) :
/// Identité → Domicile et signalement → Photo et signature → Empreintes →
/// Récapitulatif → contrôle anti-doublon → numéro → confirmation.
///
/// « Enregistrer » écrit d'abord l'enregistrement CHIFFRÉ dans la file
/// d'attente du téléphone, puis tente l'envoi : sans réseau, il reste en
/// attente et partira à la synchronisation (le numéro est attribué à ce moment).
class EcranNouvelleFiche extends StatefulWidget {
  const EcranNouvelleFiche({
    super.key,
    required this.api,
    required this.services,
    required this.agent,
    this.source = const SourceCapture(),
    this.sourcePhoto = const SourcePhoto(),
    this.brouillon,
  });

  /// Fiche déjà remplie (tests ; plus tard, reprise d'un brouillon hors ligne).
  final BrouillonFiche? brouillon;
  final ClientApi api;
  final ServicesHorsLigne services;
  final AgentConnecte agent;
  final SourceCapture source;
  final SourcePhoto sourcePhoto;

  static const titres = ['Identité', 'Domicile et signalement', 'Photo et signature', 'Empreintes', 'Récapitulatif'];

  /// En dessous, l'enregistrement est refusé : trop peu de doigts pour un
  /// contrôle anti-doublon et une identification fiables.
  static const doigtsMin = 8;

  @override
  State<EcranNouvelleFiche> createState() => _EcranNouvelleFicheState();
}

class _EcranNouvelleFicheState extends State<EcranNouvelleFiche> {
  late final _fiche = widget.brouillon ?? BrouillonFiche();
  final _signature = ControleurSignature();
  final _cleCadreSignature = GlobalKey();
  final Map<int, DoigtEnvoi> _doigts = {};

  int _etape = 0;
  bool _afficherErreurs = false;
  bool _enCours = false;
  String? _erreur;

  late final _synchroniseur = Synchroniseur(widget.services.file, widget.api);

  /// Écrit dans la file d'attente dès le premier « Enregistrer ».
  ElementAttente? _element;
  ResultatSync? _resultat;
  EtapeEnvoi? _etapeEnvoi;

  @override
  void dispose() {
    _signature.dispose();
    super.dispose();
  }

  Map<String, String> get _erreursEtape => switch (_etape) {
        0 => erreursIdentite(_fiche),
        1 => erreursDomicile(_fiche),
        2 => erreursMedias(_fiche),
        3 => _doigts.length < EcranNouvelleFiche.doigtsMin
            ? {'doigts': 'Au moins ${EcranNouvelleFiche.doigtsMin} doigts nets sur 10 (${_doigts.length} pour l\'instant)'}
            : {},
        _ => {},
      };

  void _suivant() {
    if (_erreursEtape.isNotEmpty) {
      setState(() => _afficherErreurs = true);
      return;
    }
    setState(() {
      _etape++;
      _afficherErreurs = false;
      _erreur = null;
    });
  }

  void _precedent() => setState(() {
        _etape--;
        _afficherErreurs = false;
        _erreur = null;
      });

  void _allerA(int etape) => setState(() {
        _etape = etape;
        _afficherErreurs = false;
      });

  // ----------------------------------------------------------- photo, signature

  Future<void> _prendrePhoto() async {
    try {
      final photo = await widget.sourcePhoto.prendre();
      if (photo != null) setState(() => _fiche.photo = photo);
    } catch (e) {
      setState(() => _erreur = 'Appareil photo indisponible : $e');
    }
  }

  Future<void> _validerSignature() async {
    final taille = _cleCadreSignature.currentContext?.size;
    if (_signature.vide || taille == null) return;
    final png = await exporterSignature(_signature.traits, taille);
    setState(() => _fiche.signature = png);
  }

  void _refaireSignature() => setState(() {
        _fiche.signature = null;
        _signature.effacer();
      });

  // ------------------------------------------------------------------ empreintes

  List<EtapeCapture> get _etapesManquantes => [
        for (final e in EtapeCapture.sequence)
          if (isoDeLEtape(e).any((iso) => !_doigts.containsKey(iso))) e,
      ];

  Future<void> _capturer({bool seulementManquants = false}) async {
    final etapes = seulementManquants ? _etapesManquantes : EtapeCapture.sequence;
    final decoupes = await widget.source.capturer(context, etapes, 'enregistrement');
    if (decoupes == null || !mounted) return;
    try {
      final doigts = await doigtsAEnvoyer(decoupes, lire: widget.source.lire);
      setState(() {
        if (!seulementManquants) _doigts.clear();
        for (final d in doigts) {
          _doigts[d.iso] = d;
        }
      });
    } finally {
      await widget.source.nettoyer();
    }
  }

  // ------------------------------------------------------------------- envoi

  /// Premier appel : écrit l'enregistrement (chiffré) dans la file, puis
  /// l'envoie. Appels suivants : reprise (réessai, validation superviseur).
  Future<void> _envoyer({bool validationSuperviseur = false}) async {
    setState(() {
      _enCours = true;
      _erreur = null;
    });
    try {
      var element = _element;
      if (element == null) {
        element = ElementAttente.nouveau(
          agent: widget.agent.matricule,
          fiche: _fiche,
          doigts: [for (final iso in _doigts.keys.toList()..sort()) _doigts[iso]!],
        );
        await widget.services.file.enregistrer(element);
        _element = element;
      }
      void progression(EtapeEnvoi e) => setState(() => _etapeEnvoi = e);
      final r = validationSuperviseur
          ? await _synchroniseur.validerEtEnvoyer(element)
          : element.statut == StatutAttente.erreur
              ? await _synchroniseur.reessayer(element)
              : await _synchroniseur.envoyer(element, progression: progression);
      setState(() => _resultat = r);
    } on Exception catch (e) {
      // Écriture impossible sur le téléphone (stockage plein…).
      setState(() => _erreur = 'Enregistrement impossible sur le téléphone : $e');
    } finally {
      if (mounted) setState(() => _enCours = false);
    }
  }

  // ---------------------------------------------------------------- affichage

  /// Quitter avant « Enregistrer » fait perdre la saisie (elle n'est écrite
  /// dans la file qu'à ce moment). Après, l'enregistrement est conservé.
  Future<bool> _confirmerSortie() async {
    if (_element != null) return true;
    final quitter = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Abandonner cet enregistrement ?'),
        content: const Text('Les informations saisies seront perdues.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Continuer la saisie')),
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Abandonner')),
        ],
      ),
    );
    return quitter ?? false;
  }

  @override
  Widget build(BuildContext context) {
    switch (_resultat?.issue) {
      case IssueSync.envoye:
        return _confirmation();
      case IssueSync.horsLigne || IssueSync.reconnexion:
        return _confirmationAttente();
      default:
    }
    final erreurs = _afficherErreurs ? _erreursEtape : const <String, String>{};
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (aQuitte, _) async {
        if (aQuitte) return;
        if (await _confirmerSortie() && context.mounted) Navigator.pop(context);
      },
      child: Scaffold(
        appBar: barreHawiya('Enregistrer une personne'),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
          children: [
            _progression(),
            const SizedBox(height: 16),
            Text(EcranNouvelleFiche.titres[_etape], style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 14),
            switch (_etape) {
              0 => EtapeIdentite(fiche: _fiche, erreurs: erreurs, onChanged: () => setState(() {})),
              1 => EtapeDomicile(fiche: _fiche, erreurs: erreurs, onChanged: () => setState(() {})),
              2 => _etapeMedias(erreurs),
              3 => _etapeEmpreintes(erreurs),
              _ => _recapitulatif(),
            },
            if (_erreur != null) ...[
              const SizedBox(height: 12),
              Encadre(titre: 'Problème', texte: _erreur, couleur: Colors.red.shade700, icone: Icons.error_outline),
            ],
            const SizedBox(height: 20),
            if (_etape < 4)
              Row(children: [
                if (_etape > 0) ...[
                  Expanded(child: BoutonSecondaire(texte: 'Précédent', icone: Icons.arrow_back, onPressed: _precedent)),
                  const SizedBox(width: 12),
                ],
                Expanded(child: BoutonPrincipal(texte: 'Suivant', onPressed: _suivant)),
              ])
            else if (_resultat == null || _resultat!.issue == IssueSync.erreur)
              BoutonPrincipal(
                texte: _enCours
                    ? EnvoiEnregistrement.libelles[_etapeEnvoi] ?? 'Envoi…'
                    : (_element != null ? 'Réessayer l\'envoi' : 'Enregistrer'),
                icone: Icons.cloud_upload_outlined,
                enCours: _enCours,
                onPressed: _envoyer,
              ),
            const PiedPrototype(),
          ],
        ),
      ),
    );
  }

  Widget _progression() => Row(children: [
        for (var i = 0; i < EcranNouvelleFiche.titres.length; i++) ...[
          Expanded(
            child: Container(
              height: 6,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(3),
                color: i < _etape
                    ? Couleurs.vertProfond
                    : i == _etape
                        ? Couleurs.dore
                        : Colors.black12,
              ),
            ),
          ),
          if (i < EcranNouvelleFiche.titres.length - 1) const SizedBox(width: 6),
        ],
      ]);

  Widget _messageErreur(String? texte) => texte == null
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(texte, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        );

  Widget _etapeMedias(Map<String, String> erreurs) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Photo du visage', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        const Text('De face, visage dégagé, sur un fond clair.', style: TextStyle(color: Colors.black54)),
        const SizedBox(height: 10),
        if (_fiche.photo != null)
          Center(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.memory(_fiche.photo!, height: 220, fit: BoxFit.cover),
            ),
          ),
        const SizedBox(height: 10),
        BoutonSecondaire(
          texte: _fiche.photo == null ? 'Prendre la photo' : 'Reprendre la photo',
          icone: Icons.photo_camera_outlined,
          onPressed: _prendrePhoto,
        ),
        _messageErreur(erreurs['photo']),
        const SizedBox(height: 24),
        Text('Signature', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        if (_fiche.signature != null) ...[
          Container(
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
            child: Image.memory(_fiche.signature!, height: 140),
          ),
          const SizedBox(height: 10),
          BoutonSecondaire(texte: 'Refaire la signature', icone: Icons.refresh, onPressed: _refaireSignature),
        ] else ...[
          const Text('La personne signe avec le doigt dans le cadre.', style: TextStyle(color: Colors.black54)),
          const SizedBox(height: 8),
          PadSignature(key: _cleCadreSignature, controleur: _signature),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(child: BoutonSecondaire(texte: 'Effacer', icone: Icons.clear, onPressed: _signature.effacer)),
            const SizedBox(width: 12),
            Expanded(
              child: ListenableBuilder(
                listenable: _signature,
                builder: (_, _) => BoutonPrincipal(
                  texte: 'Valider',
                  icone: Icons.check,
                  onPressed: _signature.vide ? null : _validerSignature,
                ),
              ),
            ),
          ]),
        ],
        _messageErreur(erreurs['signature']),
      ]);

  Widget _etapeEmpreintes(Map<String, String> erreurs) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text(
          'Main droite (4 doigts), main gauche (4 doigts), puis chaque pouce. '
          'La capture se déclenche seule quand la main est bien placée.',
          style: TextStyle(color: Colors.black54),
        ),
        const SizedBox(height: 14),
        for (final e in EtapeCapture.sequence)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(children: [
              Icon(
                isoDeLEtape(e).every(_doigts.containsKey) ? Icons.check_circle : Icons.radio_button_unchecked,
                color: isoDeLEtape(e).every(_doigts.containsKey) ? Couleurs.vertProfond : Colors.black38,
              ),
              const SizedBox(width: 10),
              Expanded(child: Text(e.titre)),
              Text('${isoDeLEtape(e).where(_doigts.containsKey).length}/${isoDeLEtape(e).length}',
                  style: const TextStyle(color: Colors.black54)),
            ]),
          ),
        const SizedBox(height: 6),
        Text('${_doigts.length} doigt(s) net(s) sur 10', style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 12),
        BoutonSecondaire(
          texte: _doigts.isEmpty ? 'Capturer les empreintes' : 'Tout recapturer',
          icone: Icons.fingerprint,
          onPressed: () => _capturer(),
        ),
        if (_doigts.isNotEmpty && _etapesManquantes.isNotEmpty) ...[
          const SizedBox(height: 8),
          BoutonSecondaire(
            texte: 'Compléter les doigts manquants',
            icone: Icons.add,
            onPressed: () => _capturer(seulementManquants: true),
          ),
        ],
        _messageErreur(erreurs['doigts']),
      ]);

  Widget _recapitulatif() {
    final f = _fiche;
    // Déjà écrite dans la file d'attente : plus de modification.
    final verrouille = _element != null;
    final controle = _element?.controle;
    final aVerifier = _resultat?.issue == IssueSync.aVerifier;
    Widget section(String titre, int etape, List<(String, String)> lignes) => Card(
          color: Colors.white,
          elevation: 0,
          margin: const EdgeInsets.only(bottom: 12),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(child: Text(titre, style: Theme.of(context).textTheme.titleLarge)),
                if (!verrouille && !_enCours) TextButton(onPressed: () => _allerA(etape), child: const Text('Modifier')),
              ]),
              for (final (l, v) in lignes)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    SizedBox(width: 130, child: Text(l, style: const TextStyle(color: Colors.black54))),
                    Expanded(child: Text(v)),
                  ]),
                ),
            ]),
          ),
        );

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      section('Identité', 0, [
        ('Nom', f.nom.trim().toUpperCase()),
        ('Prénom(s)', f.prenoms.trim()),
        ('Sexe', sexes[f.sexe] ?? ''),
        ('Naissance', '${f.dateNaissance == null ? '' : formaterDate(f.dateNaissance!)} à ${f.lieuNaissance.trim()}'),
        ('Nationalité', f.nationalite.trim()),
        ("N° d'acte", f.numeroActeNaissance.trim()),
        ('Téléphone', normaliserTelephone(f.telephone) ?? '—'),
      ]),
      section('Domicile et signalement', 1, [
        ('Domicile', '${f.quartier.trim()}, ${f.ville.trim()} (${f.ile ?? ''})'),
        ('Adresse', f.adresse.trim()),
        ('Taille', '${f.taille.trim()} cm'),
        ('Yeux', couleursYeux[f.couleurYeux] ?? ''),
        ('Cheveux', couleursCheveux[f.couleurCheveux] ?? ''),
      ]),
      section('Photo, signature, empreintes', 2, [
        ('Photo', f.photo == null ? 'manquante' : 'prise'),
        ('Signature', f.signature == null ? 'manquante' : 'faite'),
        ('Empreintes', '${_doigts.length} doigt(s) sur 10'),
      ]),
      if (_resultat?.issue == IssueSync.erreur)
        Encadre(
          titre: 'Refusé par le serveur',
          texte: _resultat!.message,
          couleur: Colors.red.shade700,
          icone: Icons.error_outline,
        ),
      if (aVerifier && controle?.verdict == VerdictDoublon.doublonCertain)
        Encadre(
          titre: 'Personne déjà enregistrée',
          texte: '${controle!.motif}\nFiche(s) : ${controle.numeros.join(', ')}\n'
              "L'enregistrement est arrêté et conservé dans « En attente » pour vérification.",
          couleur: Colors.red.shade700,
          icone: Icons.block,
        ),
      if (aVerifier && controle?.verdict != VerdictDoublon.doublonCertain) ...[
        Encadre(
          titre: 'Doublon possible',
          texte: '${controle?.motif ?? ''}\nFiche(s) à vérifier : ${controle?.numeros.join(', ') ?? ''}',
          couleur: Couleurs.dore,
          icone: Icons.warning_amber_rounded,
        ),
        const SizedBox(height: 12),
        if (widget.agent.peutValiderDoublon && widget.api.connecte)
          BoutonPrincipal(
            texte: 'Valider après vérification (superviseur)',
            icone: Icons.admin_panel_settings_outlined,
            enCours: _enCours,
            onPressed: () => _envoyer(validationSuperviseur: true),
          )
        else
          const Text(
            "Un superviseur doit vérifier les fiches ci-dessus puis valider l'enregistrement "
            'depuis « En attente », avec son propre compte.',
            style: TextStyle(color: Colors.black54),
          ),
      ],
    ]);
  }

  void _autrePersonne() => Navigator.pushReplacement(
        context,
        MaterialPageRoute<void>(
          builder: (_) => EcranNouvelleFiche(
            api: widget.api,
            services: widget.services,
            agent: widget.agent,
            source: widget.source,
            sourcePhoto: widget.sourcePhoto,
          ),
        ),
      );

  /// Envoi impossible pour l'instant : enregistrement gardé sur le téléphone.
  Widget _confirmationAttente() => Scaffold(
        appBar: barreHawiya('Enregistrement en attente'),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          children: [
            const Icon(Icons.cloud_off_outlined, color: Couleurs.dore, size: 72),
            const SizedBox(height: 12),
            Text('Enregistré sur le téléphone',
                textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 8),
            Text(
              '${_element!.nomComplet} · référence provisoire ${_element!.reference}\n\n'
              '${_resultat!.issue == IssueSync.reconnexion ? 'Connexion en ligne nécessaire' : 'Serveur injoignable'} : '
              "l'enregistrement est gardé, chiffré, et sera envoyé à la synchronisation. "
              "Le contrôle anti-doublon et le numéro d'identification se feront à ce moment.",
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            BoutonPrincipal(texte: 'Enregistrer une autre personne', icone: Icons.person_add_alt, onPressed: _autrePersonne),
            const SizedBox(height: 8),
            BoutonSecondaire(texte: "Retour à l'accueil", icone: Icons.home_outlined, onPressed: () => Navigator.pop(context)),
            const PiedPrototype(),
          ],
        ),
      );

  Widget _confirmation() {
    final c = _resultat!.citoyen;
    final numero = _resultat!.element.numero ?? c?.numero ?? '';
    return Scaffold(
      appBar: barreHawiya('Enregistrement terminé'),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        children: [
          const Icon(Icons.check_circle, color: Couleurs.validation, size: 72),
          const SizedBox(height: 12),
          const Text("Numéro d'identification", textAlign: TextAlign.center, style: TextStyle(color: Colors.black54)),
          SelectableText(numero,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(color: Couleurs.vertProfond)),
          const SizedBox(height: 16),
          if (c != null) FicheCitoyen(citoyen: c),
          const SizedBox(height: 20),
          BoutonPrincipal(
            texte: 'Enregistrer une autre personne',
            icone: Icons.person_add_alt,
            onPressed: _autrePersonne,
          ),
          const SizedBox(height: 8),
          BoutonSecondaire(texte: "Retour à l'accueil", icone: Icons.home_outlined, onPressed: () => Navigator.pop(context)),
          const PiedPrototype(),
        ],
      ),
    );
  }
}
