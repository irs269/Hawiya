import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/couleurs.dart';
import 'capture_native.dart';
import 'geometrie_doigts.dart';
import 'peintre_main.dart';

/// Étape 3a — écran de test : aperçu caméra + flash + détection de la main.
///
/// Sert à valider sur un vrai téléphone que la main est détectée en direct,
/// que les points tombent au bon endroit, et à relever le diagnostic de la
/// caméra (résolutions, distance minimale de mise au point, zoom…).
class EcranTestCamera extends StatefulWidget {
  const EcranTestCamera({super.key});

  @override
  State<EcranTestCamera> createState() => _EcranTestCameraState();
}

class _EcranTestCameraState extends State<EcranTestCamera> {
  /// Intervalle minimal entre deux mises au point automatiques sur les doigts.
  static const _intervalleMiseAuPoint = Duration(milliseconds: 1500);

  bool? _permission;
  Map<String, Object?> _infos = {};
  Analyse? _analyse;
  String? _erreur;
  bool _flash = true;
  double _zoom = 0;
  DateTime _derniereMiseAuPoint = DateTime.fromMillisecondsSinceEpoch(0);

  /// Taille de la zone d'aperçu à l'écran (pour caler les points de l'image).
  Size? _tailleApercu;
  StreamSubscription<Analyse>? _abonnement;

  @override
  void initState() {
    super.initState();
    _demanderPermission();
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

  void _surAnalyse(Analyse analyse) {
    if (!mounted) return;
    setState(() => _analyse = analyse);
    // Mise au point automatique sur le centre des bouts de doigts.
    final maintenant = DateTime.now();
    final zone = _tailleApercu;
    if (zone != null &&
        analyse.mains.isNotEmpty &&
        maintenant.difference(_derniereMiseAuPoint) > _intervalleMiseAuPoint) {
      _derniereMiseAuPoint = maintenant;
      final calage = CalageApercu(
        image: Size(analyse.largeur.toDouble(), analyse.hauteur.toDouble()),
        zone: zone,
      );
      CaptureNative.mettreAuPoint(
          calage.versZoneNormalisee(centreDesBouts(analyse.mains.first.points)));
    }
  }

  @override
  void dispose() {
    _abonnement?.cancel();
    CaptureNative.arreter();
    super.dispose();
  }

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
              "Hawiya a besoin de la caméra pour filmer la main.",
              textAlign: TextAlign.center,
              style: TextStyle(color: Couleurs.texteCamera, fontSize: 16),
            ),
            const SizedBox(height: 16),
            _bouton('Autoriser la caméra', _demanderPermission),
          ],
        ),
      );

  Widget _contenu() {
    final mains = _analyse?.mains ?? const <MainDetectee>[];
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      children: [
        _entete(),
        const SizedBox(height: 16),
        _apercu(mains),
        const SizedBox(height: 12),
        _message(mains),
        const SizedBox(height: 12),
        _reglageZoom(),
        const SizedBox(height: 12),
        _diagnostic(mains),
      ],
    );
  }

  Widget _entete() => Row(
        children: [
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Étape 3a · test caméra',
                    style: TextStyle(
                        color: Couleurs.texteCameraDiscret,
                        fontSize: 12,
                        fontWeight: FontWeight.w600)),
                Text('Détection de la main',
                    style: TextStyle(
                        color: Couleurs.texteCamera,
                        fontSize: 22,
                        fontWeight: FontWeight.w600)),
              ],
            ),
          ),
          // Bouton flash (44 px minimum)
          InkWell(
            borderRadius: BorderRadius.circular(999),
            onTap: () {
              setState(() => _flash = !_flash);
              CaptureNative.flash(_flash);
            },
            child: Container(
              constraints: const BoxConstraints(minHeight: 44),
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(999),
                color: _flash
                    ? Couleurs.alerte.withValues(alpha: 0.16)
                    : Colors.white.withValues(alpha: 0.08),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(_flash ? Icons.flash_on : Icons.flash_off,
                    size: 16,
                    color: _flash ? Couleurs.alerte : Couleurs.texteCameraDiscret),
                const SizedBox(width: 6),
                Text('Flash',
                    style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: _flash ? Couleurs.alerte : Couleurs.texteCameraDiscret)),
              ]),
            ),
          ),
        ],
      );

  Widget _apercu(List<MainDetectee> mains) => ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: AspectRatio(
          // Portrait 3:4, identique à l'image analysée : pas de décalage des points.
          aspectRatio: 3 / 4,
          child: LayoutBuilder(
            builder: (context, contraintes) {
              _tailleApercu = contraintes.biggest;
              return GestureDetector(
              // Toucher l'aperçu = mise au point à cet endroit.
              onTapUp: (d) => CaptureNative.mettreAuPoint(Offset(
                d.localPosition.dx / contraintes.maxWidth,
                d.localPosition.dy / contraintes.maxHeight,
              )),
              child: Stack(fit: StackFit.expand, children: [
                const ColoredBox(color: Couleurs.carteCamera),
                AndroidView(
                  viewType: CaptureNative.vueApercu,
                  onPlatformViewCreated: (_) => _demarrer(),
                ),
                IgnorePointer(child: CustomPaint(painter: PeintreMain(_analyse))),
                Positioned(top: 16, left: 16, child: _badge(mains)),
              ]),
              );
            },
          ),
        ),
      );

  Widget _badge(List<MainDetectee> mains) {
    final texte = mains.isEmpty
        ? 'AUCUNE MAIN'
        : mains.map((m) => 'MAIN ${m.cote.toUpperCase()}').join(' + ');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(8)),
      child: Text(texte,
          style: const TextStyle(
              color: Couleurs.texteCamera,
              fontSize: 12,
              fontWeight: FontWeight.w700)),
    );
  }

  Widget _message(List<MainDetectee> mains) {
    final (texte, ok) = switch (mains) {
      _ when _erreur != null => (_erreur!, false),
      [] => ('Présentez une main, paume vers la caméra, à environ 15 cm.', false),
      [final main, ...] when !main.paume => ('Tournez la paume vers la caméra.', false),
      _ => ('Main détectée — vérifiez que les cadres sont sur les bouts des doigts.', true),
    };
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
          color: Couleurs.carteCamera, borderRadius: BorderRadius.circular(16)),
      child: Row(children: [
        Icon(ok ? Icons.check_circle_outline : Icons.info_outline,
            color: ok ? Couleurs.validationClaire : Couleurs.alerte, size: 20),
        const SizedBox(width: 10),
        Expanded(
          child: Text(texte,
              style: TextStyle(
                  color: ok ? Couleurs.validationClaire : Couleurs.texteCamera,
                  fontSize: 15,
                  fontWeight: FontWeight.w600)),
        ),
      ]),
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
              textAlign: TextAlign.right,
              style: const TextStyle(color: Couleurs.texteCamera)),
        ),
      ]);

  Widget _diagnostic(List<MainDetectee> mains) {
    final a = _analyse;
    final miseAuPoint = _infos['miseAuPointMinCm'] as num?;
    final lignes = <(String, String)>[
      ('Téléphone', '${_infos['modele'] ?? '…'} (Android ${_infos['android'] ?? '…'})'),
      ('Analyse', a == null ? '…' : '${a.ips.toStringAsFixed(1)} img/s · ${a.latenceMs} ms · ${a.largeur}×${a.hauteur}'),
      ('Calcul', '${_infos['delegue'] ?? '…'}'),
      ('Aperçu', '${_infos['resolutionApercu'] ?? '…'}'),
      ('Photo', _infos['captureLiee'] == false ? 'NON DISPONIBLE avec l\'analyse' : '${_infos['resolutionCapture'] ?? '…'}'),
      ('Mise au point min.', switch (miseAuPoint) {
        null => '…',
        < 0 => 'focale fixe',
        _ => '${miseAuPoint.toStringAsFixed(1)} cm (${_infos['calibrationMiseAuPoint'] ?? '?'})',
      }),
      ('Zoom possible', '×${_infos['zoomMin'] ?? '?'} à ×${(_infos['zoomMax'] as num?)?.toStringAsFixed(1) ?? '?'}'),
      ('Flash', _infos['flashDisponible'] == false ? 'absent' : 'présent'),
      ('Température', switch (a?.thermique) {
        null || -1 => 'inconnue',
        0 => 'normale',
        1 || 2 => 'tiède',
        _ => 'CHAUD (${a!.thermique})',
      }),
      for (final m in mains)
        ('Main ${m.cote}',
            '${(m.confiance * 100).round()} % · ${m.paume ? 'paume' : 'dos ?'} · '
                'brut ${m.etiquetteBrute} · produit ${m.produit < 0 ? '−' : '+'}'),
    ];
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(16)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Diagnostic',
              style: TextStyle(
                  color: Couleurs.texteCamera, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          for (final (libelle, valeur) in lignes)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SizedBox(
                  width: 130,
                  child: Text(libelle,
                      style: const TextStyle(
                          color: Couleurs.texteCameraDiscret, fontSize: 13)),
                ),
                Expanded(
                  child: Text(valeur,
                      style: const TextStyle(
                          color: Couleurs.texteCamera, fontSize: 13)),
                ),
              ]),
            ),
        ],
      ),
    );
  }

  Widget _bouton(String texte, VoidCallback action) => SizedBox(
        height: 52,
        child: FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Couleurs.validation,
            foregroundColor: const Color(0xFF0B2A1F),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
          onPressed: action,
          child: Text(texte, style: const TextStyle(fontWeight: FontWeight.w700)),
        ),
      );
}
