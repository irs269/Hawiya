import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/couleurs.dart';
import 'capture_native.dart';
import 'ecran_resultat.dart';
import 'geometrie_doigts.dart';
import 'guidage.dart';
import 'peintre_main.dart';

/// Étape 3b — capture automatique des empreintes.
///
/// La personne présente sa main ; l'application guide, puis déclenche seule une
/// rafale de 3 photos pleine résolution et découpe chaque bout de doigt.
/// Enchaînement : main droite → main gauche → pouce droit → pouce gauche.
class EcranCapture extends StatefulWidget {
  const EcranCapture({super.key});

  @override
  State<EcranCapture> createState() => _EcranCaptureState();
}

class _EcranCaptureState extends State<EcranCapture> {
  static const _intervalleMiseAuPoint = Duration(milliseconds: 1500);
  static const _delaiInactivite = Duration(seconds: 60);

  final _evaluateur = EvaluateurCapture();
  bool? _permission;
  Map<String, Object?> _infos = {};
  Analyse? _analyse;
  Guidage? _guidage;
  String? _erreur;

  bool _flash = true;
  double _zoom = 0;
  /// Activé par défaut pendant le test de faisabilité (phases 3-4) : on garde
  /// les images pour les évaluer. À désactiver par défaut avant la démo.
  bool _debogage = true;

  /// Pause : analyse et flash coupés (inactivité, chauffe, écran résultat).
  bool _enPause = false;
  String? _raisonPause;
  bool _captureEnCours = false;

  int _indexEtape = 0;
  final Map<int, ResultatCapture> _resultats = {};
  String _session = _nouvelIdentifiantSession();

  DateTime _derniereMainVue = DateTime.now();
  DateTime _derniereMiseAuPoint = DateTime.fromMillisecondsSinceEpoch(0);
  Size? _tailleApercu;
  Timer? _minuteur;
  StreamSubscription<Analyse>? _abonnement;

  EtapeCapture get _etape => EtapeCapture.sequence[_indexEtape];

  /// Largeur de la photo pleine résolution / largeur de l'image analysée.
  double get _facteurCapture {
    final photo = (_infos['largeurCapturePortrait'] as num?)?.toDouble();
    final analyse = _analyse?.largeur;
    if (photo == null || analyse == null || analyse == 0) return 1;
    return photo / analyse;
  }

  static String _nouvelIdentifiantSession() {
    final t = DateTime.now();
    String d(int n) => n.toString().padLeft(2, '0');
    return 'session_${t.year}${d(t.month)}${d(t.day)}_${d(t.hour)}${d(t.minute)}${d(t.second)}';
  }

  @override
  void initState() {
    super.initState();
    _demanderPermission();
    _minuteur = Timer.periodic(const Duration(seconds: 5), (_) => _verifierInactivite());
  }

  @override
  void dispose() {
    _minuteur?.cancel();
    _abonnement?.cancel();
    CaptureNative.arreter();
    super.dispose();
  }

  Future<void> _demanderPermission() async {
    final accordee = await CaptureNative.demanderPermission();
    if (mounted) setState(() => _permission = accordee);
  }

  /// Appelé quand la vue native d'aperçu est créée.
  Future<void> _demarrer() async {
    _abonnement ??= CaptureNative.analyses.listen(
      _surAnalyse,
      onError: (Object e) => setState(() => _erreur = e.toString()),
    );
    try {
      final infos = await CaptureNative.demarrer();
      if (mounted) setState(() => _infos = infos);
      // Le délégué (GPU/CPU) n'est connu qu'après la première analyse.
      await Future<void>.delayed(const Duration(seconds: 2));
      final aJour = await CaptureNative.infos();
      if (mounted) setState(() => _infos = aJour);
    } catch (e) {
      if (mounted) setState(() => _erreur = 'Caméra : $e');
    }
  }

  // ------------------------------------------------------------- analyse

  void _surAnalyse(Analyse a) {
    if (!mounted || _enPause) return;
    final maintenant = DateTime.now();
    if (a.mains.isNotEmpty) _derniereMainVue = maintenant;
    if (a.thermique >= 3) {
      _mettreEnPause('Le téléphone chauffe : laissez-le refroidir quelques minutes.');
      return;
    }
    if (_captureEnCours) {
      setState(() => _analyse = a);
      return;
    }
    final g = _evaluateur.evaluer(a, _etape, facteurCapture: _facteurCapture, maintenant: maintenant);
    setState(() {
      _analyse = a;
      _guidage = g;
    });
    if (g.pret) {
      _lancerCapture(a, g);
    } else if (g.main != null &&
        maintenant.difference(_derniereMiseAuPoint) > _intervalleMiseAuPoint) {
      final point = _pointMiseAuPoint(a, g.main!);
      if (point != null) {
        _derniereMiseAuPoint = maintenant;
        CaptureNative.mettreAuPoint(point);
      }
    }
  }

  /// Centre des bouts des doigts de l'étape, en coordonnées 0..1 de l'aperçu.
  Offset? _pointMiseAuPoint(Analyse a, MainDetectee main) {
    final zone = _tailleApercu;
    if (zone == null) return null;
    var somme = Offset.zero;
    for (final d in _etape.doigts) {
      somme += main.points[Reperes.bouts[d]];
    }
    final centre = somme / _etape.doigts.length.toDouble();
    return CalageApercu(
      image: Size(a.largeur.toDouble(), a.hauteur.toDouble()),
      zone: zone,
    ).versZoneNormalisee(centre);
  }

  void _verifierInactivite() {
    if (_enPause || _captureEnCours) return;
    if (DateTime.now().difference(_derniereMainVue) > _delaiInactivite) {
      _mettreEnPause('Pause après 60 s sans main. Touchez pour reprendre.');
    }
  }

  void _mettreEnPause(String raison) {
    setState(() {
      _enPause = true;
      _raisonPause = raison;
      _guidage = null;
    });
    CaptureNative.pause();
  }

  void _reprendre() {
    _evaluateur.reinitialiser();
    _derniereMainVue = DateTime.now();
    setState(() {
      _enPause = false;
      _raisonPause = null;
      _guidage = null;
    });
    CaptureNative.reprendre();
  }

  // ------------------------------------------------------------- capture

  Future<void> _lancerCapture(Analyse a, Guidage g) async {
    setState(() => _captureEnCours = true);
    ResultatCapture resultat;
    try {
      resultat = await CaptureNative.capturer(
        main: _etape.main,
        doigts: _etape.doigts,
        session: _session,
        debogage: _debogage,
        miseAuPoint: _pointMiseAuPoint(a, g.main!),
      );
    } catch (e) {
      resultat = ResultatCapture(succes: false, raison: 'Capture impossible : $e');
    }
    await CaptureNative.pause();
    if (!mounted) return;
    setState(() {
      _captureEnCours = false;
      _enPause = true;
      _raisonPause = null;
    });

    final total = EtapeCapture.sequence.length;
    final choix = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => EcranResultatEtape(
          etape: _etape,
          resultat: resultat,
          numero: _indexEtape + 1,
          total: total,
          debogage: _debogage,
        ),
      ),
    );
    if (!mounted) return;

    if (choix == 'suivant' && resultat.succes) {
      _resultats[_indexEtape] = resultat;
      if (_indexEtape + 1 < total) {
        setState(() => _indexEtape++);
      } else {
        await Navigator.push<void>(
          context,
          MaterialPageRoute(
            builder: (_) => EcranFinSession(resultats: Map.of(_resultats), debogage: _debogage),
          ),
        );
        _nouvelleSession();
      }
    }
    if (mounted) _reprendre();
  }

  void _nouvelleSession() {
    // Hors débogage, les découpes ne sont gardées que le temps de la session.
    if (!_debogage) CaptureNative.supprimerTemporaires();
    setState(() {
      _indexEtape = 0;
      _resultats.clear();
      _session = _nouvelIdentifiantSession();
    });
  }

  // ------------------------------------------------------------- affichage

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Couleurs.fondCamera,
      body: SafeArea(
        child: switch (_permission) {
          null => const Center(child: CircularProgressIndicator()),
          false => _refusPermission(),
          true => _contenu(),
        },
      ),
    );
  }

  Widget _refusPermission() => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text(
              'Hawiya a besoin de la caméra pour filmer la main.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Couleurs.texteCamera, fontSize: 16),
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 52,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: Couleurs.validation,
                  foregroundColor: const Color(0xFF0B2A1F),
                ),
                onPressed: _demanderPermission,
                child: const Text('Autoriser la caméra'),
              ),
            ),
          ],
        ),
      );

  Widget _contenu() => ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        children: [
          _entete(),
          const SizedBox(height: 12),
          _barreEtapes(),
          const SizedBox(height: 14),
          _apercu(),
          const SizedBox(height: 12),
          _message(),
          const SizedBox(height: 10),
          _jaugeDistance(),
          if (_debogage) ...[
            const SizedBox(height: 12),
            _reglageZoom(),
            _panneauDebogage(),
          ],
        ],
      );

  Widget _entete() => Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Étape ${_indexEtape + 1} sur ${EtapeCapture.sequence.length} · empreintes',
                    style: const TextStyle(
                        color: Couleurs.texteCameraDiscret,
                        fontSize: 12,
                        fontWeight: FontWeight.w600)),
                Text(_etape.titre,
                    style: const TextStyle(
                        color: Couleurs.texteCamera, fontSize: 22, fontWeight: FontWeight.w600)),
              ],
            ),
          ),
          _boutonRond(
            icone: Icons.bug_report_outlined,
            actif: _debogage,
            couleurActive: Couleurs.validationClaire,
            infobulle: 'Mode débogage',
            onTap: () => setState(() => _debogage = !_debogage),
          ),
          const SizedBox(width: 8),
          _boutonRond(
            icone: _flash ? Icons.flash_on : Icons.flash_off,
            actif: _flash,
            couleurActive: Couleurs.alerte,
            infobulle: 'Flash',
            onTap: () {
              setState(() => _flash = !_flash);
              CaptureNative.flash(_flash);
            },
          ),
        ],
      );

  Widget _boutonRond({
    required IconData icone,
    required bool actif,
    required Color couleurActive,
    required String infobulle,
    required VoidCallback onTap,
  }) =>
      Tooltip(
        message: infobulle,
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: onTap,
          child: Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: actif ? couleurActive.withValues(alpha: 0.16) : Colors.white.withValues(alpha: 0.08),
            ),
            child: Icon(icone, size: 20, color: actif ? couleurActive : Couleurs.texteCameraDiscret),
          ),
        ),
      );

  /// Barre de progression en segments (une par étape), comme le prototype.
  Widget _barreEtapes() => Row(
        children: [
          for (var i = 0; i < EtapeCapture.sequence.length; i++) ...[
            Expanded(
              child: Container(
                height: 6,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(3),
                  color: i < _indexEtape
                      ? Couleurs.validation
                      : i == _indexEtape
                          ? Couleurs.dore
                          : Colors.white.withValues(alpha: 0.12),
                ),
              ),
            ),
            if (i < EtapeCapture.sequence.length - 1) const SizedBox(width: 6),
          ],
        ],
      );

  Widget _apercu() => ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: AspectRatio(
          aspectRatio: 3 / 4,
          child: LayoutBuilder(builder: (context, contraintes) {
            _tailleApercu = contraintes.biggest;
            return GestureDetector(
              onTapUp: (d) {
                if (_enPause && _raisonPause != null) {
                  _reprendre();
                  return;
                }
                CaptureNative.mettreAuPoint(Offset(
                  d.localPosition.dx / contraintes.maxWidth,
                  d.localPosition.dy / contraintes.maxHeight,
                ));
              },
              child: Stack(fit: StackFit.expand, children: [
                const ColoredBox(color: Couleurs.carteCamera),
                AndroidView(
                  viewType: CaptureNative.vueApercu,
                  onPlatformViewCreated: (_) => _demarrer(),
                ),
                IgnorePointer(
                  child: CustomPaint(
                    painter: PeintreMain(_analyse, _guidage, squelette: _debogage),
                  ),
                ),
                const Positioned(top: 16, left: 16, child: _Badge(texte: 'UNE MAIN SUFFIT')),
                if (_captureEnCours) const _Voile(texte: 'Capture en cours…\nNe bougez plus'),
                if (_enPause && _raisonPause != null) _Voile(texte: _raisonPause!),
              ]),
            );
          }),
        ),
      );

  Widget _message() {
    final g = _guidage;
    final texte = _erreur ?? g?.message ?? _etape.consigne;
    final ok = g != null && (g.code == CodeGuidage.immobile || g.code == CodeGuidage.pret);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Couleurs.carteCamera,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(ok ? Icons.check_circle_outline : Icons.info_outline,
                color: ok ? Couleurs.validationClaire : Couleurs.alerte, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(texte,
                  style: TextStyle(
                      color: ok ? Couleurs.validationClaire : Couleurs.texteCamera,
                      fontSize: 16,
                      fontWeight: FontWeight.w700)),
            ),
          ]),
          if (ok) ...[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: g.progression,
                minHeight: 6,
                backgroundColor: Colors.white.withValues(alpha: 0.12),
                color: Couleurs.validation,
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Jauge de distance : position de la résolution estimée entre trop loin et trop près.
  Widget _jaugeDistance() {
    final dpi = _guidage?.dpi;
    final s = _evaluateur.seuils;
    // Échelle affichée : de 60 % du minimum à 130 % du maximum.
    final bas = s.dpiMin * 0.6;
    final haut = s.dpiMax * 1.3;
    double pos(double v) => ((v - bas) / (haut - bas)).clamp(0.0, 1.0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          const Text('Distance',
              style: TextStyle(color: Couleurs.texteCameraDiscret, fontSize: 12)),
          const Spacer(),
          Text(dpi == null ? '—' : '≈ ${dpi.toStringAsFixed(0)} dpi',
              style: const TextStyle(color: Couleurs.texteCamera, fontSize: 12)),
        ]),
        const SizedBox(height: 6),
        LayoutBuilder(builder: (context, c) {
          final w = c.maxWidth;
          return SizedBox(
            height: 14,
            child: Stack(children: [
              Positioned.fill(
                top: 4,
                bottom: 4,
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
              // Zone correcte
              Positioned(
                left: w * pos(s.dpiMin),
                width: w * (pos(s.dpiMax) - pos(s.dpiMin)),
                top: 4,
                bottom: 4,
                child: Container(color: Couleurs.validation.withValues(alpha: 0.45)),
              ),
              if (dpi != null)
                Positioned(
                  left: (w * pos(dpi) - 3).clamp(0.0, w - 6),
                  top: 0,
                  bottom: 0,
                  child: Container(
                    width: 6,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                ),
            ]),
          );
        }),
        const SizedBox(height: 2),
        const Row(children: [
          Text('trop loin', style: TextStyle(color: Couleurs.texteCameraDiscret, fontSize: 11)),
          Spacer(),
          Text('trop près', style: TextStyle(color: Couleurs.texteCameraDiscret, fontSize: 11)),
        ]),
      ],
    );
  }

  Widget _reglageZoom() => Row(children: [
        const Icon(Icons.zoom_in, color: Couleurs.texteCameraDiscret),
        Expanded(
          child: Slider(
            value: _zoom,
            activeColor: Couleurs.validation,
            onChanged: (v) {
              setState(() => _zoom = v);
              CaptureNative.zoom(v);
            },
          ),
        ),
        SizedBox(
          width: 52,
          child: Text('×${(_analyse?.zoom ?? 1).toStringAsFixed(1)}',
              textAlign: TextAlign.right, style: const TextStyle(color: Couleurs.texteCamera)),
        ),
      ]);

  Widget _panneauDebogage() {
    final a = _analyse;
    final g = _guidage;
    final miseAuPoint = _infos['miseAuPointMinCm'] as num?;
    final lignes = <(String, String)>[
      ('Téléphone', '${_infos['modele'] ?? '…'} (Android ${_infos['android'] ?? '…'})'),
      ('Analyse', a == null ? '…' : '${a.ips.toStringAsFixed(1)} img/s · ${a.latenceMs} ms · ${a.largeur}×${a.hauteur}'),
      ('Calcul', '${_infos['delegue'] ?? '…'}'),
      ('Photo', _infos['captureLiee'] == false ? 'NON DISPONIBLE' : '${_infos['resolutionCapture'] ?? '…'} (×${_facteurCapture.toStringAsFixed(2)})'),
      ('Mise au point min.', miseAuPoint == null ? '…' : miseAuPoint < 0 ? 'focale fixe' : '${miseAuPoint.toStringAsFixed(1)} cm (${_infos['calibrationMiseAuPoint'] ?? '?'})'),
      ('Zoom possible', '×${_infos['zoomMin'] ?? '?'} à ×${(_infos['zoomMax'] as num?)?.toStringAsFixed(1) ?? '?'}'),
      ('Température', switch (a?.thermique) {
        null || -1 => 'inconnue',
        0 => 'normale',
        1 || 2 => 'tiède',
        _ => 'CHAUD (${a!.thermique})',
      }),
      ('Guidage', g?.code.name ?? '—'),
      ('Session', _session),
    ];
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Débogage (photos complètes enregistrées)',
              style: TextStyle(color: Couleurs.texteCamera, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          for (final (libelle, valeur) in lignes) _ligne(libelle, valeur),
          if (g != null && g.doigts.isNotEmpty) ...[
            const SizedBox(height: 10),
            _ligne('Doigt', 'dpi · netteté · lum. · reflet'),
            for (final e in g.doigts)
              _ligne(
                '${e.ok ? '✓' : '·'} ${const ['pouce', 'index', 'majeur', 'annulaire', 'auriculaire'][e.doigt]}',
                '${e.dpi.toStringAsFixed(0)} · ${e.mesures?.nettete.toStringAsFixed(0) ?? '?'} · '
                    '${e.mesures?.luminance.toStringAsFixed(0) ?? '?'} · '
                    '${((e.mesures?.eblouissement ?? 0) * 100).toStringAsFixed(1)} %',
              ),
          ],
        ],
      ),
    );
  }

  Widget _ligne(String libelle, String valeur) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
            width: 130,
            child: Text(libelle,
                style: const TextStyle(color: Couleurs.texteCameraDiscret, fontSize: 13)),
          ),
          Expanded(
            child: Text(valeur, style: const TextStyle(color: Couleurs.texteCamera, fontSize: 13)),
          ),
        ]),
      );
}

class _Badge extends StatelessWidget {
  const _Badge({required this.texte});

  final String texte;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(texte,
            style: const TextStyle(
                color: Couleurs.texteCamera, fontSize: 12, fontWeight: FontWeight.w700)),
      );
}

/// Voile sombre avec un message, par-dessus l'aperçu.
class _Voile extends StatelessWidget {
  const _Voile({required this.texte});

  final String texte;

  @override
  Widget build(BuildContext context) => ColoredBox(
        color: const Color(0xCC101915),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(texte,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: Couleurs.texteCamera, fontSize: 18, fontWeight: FontWeight.w700)),
          ),
        ),
      );
}
