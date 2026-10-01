import 'package:flutter_test/flutter_test.dart';
import 'package:hawiya/capture/capture_native.dart';
import 'package:hawiya/capture/guidage.dart';

/// Main droite FICTIVE (géométrie synthétique), paume vers la caméra, doigts
/// verticaux, dans une image d'analyse 480×640. [ecart] = distance entre les
/// doigts (px), [phalange] = longueur bout → articulation (px).
MainDetectee mainSynthetique({
  String cote = 'droite',
  bool paume = true,
  double ecart = 70,
  double phalange = 40,
  Offset decalage = Offset.zero,
  double luminance = 140,
  double eblouissement = 0,
}) {
  final pts = List<Offset>.filled(21, const Offset(240, 560));
  // Pouce
  pts[3] = const Offset(140, 420);
  pts[4] = const Offset(120, 380);
  // Index, majeur, annulaire, auriculaire
  for (var d = 1; d <= 4; d++) {
    final x = 240.0 + (d - 2.5) * ecart;
    pts[4 * d + 3] = Offset(x, 300); // articulation
    pts[4 * d + 4] = Offset(x, 300 - phalange); // bout
  }
  return MainDetectee(
    cote: cote,
    confiance: 0.95,
    paume: paume,
    points: [for (final p in pts) Offset((p.dx + decalage.dx) / 480, (p.dy + decalage.dy) / 640)],
    doigts: List.filled(
      5,
      MesuresDoigt(visible: true, nettete: 50, luminance: luminance, eblouissement: eblouissement),
    ),
  );
}

Analyse analyseAvec(List<MainDetectee> mains) => Analyse(
      ips: 8,
      latenceMs: 30,
      largeur: 480,
      hauteur: 640,
      thermique: 0,
      zoom: 1,
      mains: mains,
    );

void main() {
  final etapeDroite = EtapeCapture.sequence[0];
  final t0 = DateTime(2026, 10, 1, 12);
  // Photo 3000 px de large pour 480 analysés : facteur 6,25.
  // Doigt de 40 px analysés → 250 px de photo → ≈ 353 dpi (trop loin).
  // Doigt de 50 px → 312,5 px → ≈ 441 dpi (bon).
  const facteur = 6.25;

  Guidage evaluer(EvaluateurCapture e, MainDetectee? main, DateTime t) => e.evaluer(
        analyseAvec([?main]),
        etapeDroite,
        facteurCapture: facteur,
        maintenant: t,
      );

  test('aucune main : consigne de l\'étape', () {
    final g = evaluer(EvaluateurCapture(), null, t0);
    expect(g.code, CodeGuidage.aucuneMain);
    expect(g.message, contains('main droite'));
  });

  test('mauvaise main', () {
    final g = evaluer(EvaluateurCapture(), mainSynthetique(cote: 'gauche'), t0);
    expect(g.code, CodeGuidage.mauvaiseMain);
  });

  test('dos de la main', () {
    final g = evaluer(EvaluateurCapture(), mainSynthetique(paume: false), t0);
    expect(g.code, CodeGuidage.tournerPaume);
  });

  test('trop loin puis trop près', () {
    expect(evaluer(EvaluateurCapture(), mainSynthetique(phalange: 40), t0).code,
        CodeGuidage.rapprocher);
    expect(evaluer(EvaluateurCapture(), mainSynthetique(phalange: 95, ecart: 110), t0).code,
        CodeGuidage.eloigner);
  });

  test('doigts serrés', () {
    final g = evaluer(EvaluateurCapture(), mainSynthetique(phalange: 50, ecart: 40), t0);
    expect(g.code, CodeGuidage.ecarterDoigts);
  });

  test('hors du cadre', () {
    final g = evaluer(EvaluateurCapture(),
        mainSynthetique(phalange: 50, decalage: const Offset(160, 0)), t0);
    expect(g.code, CodeGuidage.horsCadre);
  });

  test('lumière : sombre et reflet', () {
    expect(evaluer(EvaluateurCapture(), mainSynthetique(phalange: 50, luminance: 20), t0).code,
        CodeGuidage.tropSombre);
    expect(
        evaluer(EvaluateurCapture(), mainSynthetique(phalange: 50, eblouissement: 0.4), t0).code,
        CodeGuidage.reflet);
  });

  test('déclenchement seulement après 0,5 s d\'immobilité', () {
    final e = EvaluateurCapture();
    final main = mainSynthetique(phalange: 50);
    // 1re image : pas encore de preuve d'immobilité.
    expect(evaluer(e, main, t0).code, CodeGuidage.bouger);
    final g1 = evaluer(e, main, t0.add(const Duration(milliseconds: 120)));
    expect(g1.code, CodeGuidage.immobile);
    expect(g1.dpi, closeTo(441, 1));
    expect(g1.doigts.every((d) => d.ok), isTrue);
    expect(evaluer(e, main, t0.add(const Duration(milliseconds: 400))).code,
        CodeGuidage.immobile);
    expect(evaluer(e, main, t0.add(const Duration(milliseconds: 650))).pret, isTrue);
  });

  test('un mouvement remet le compteur à zéro', () {
    final e = EvaluateurCapture();
    evaluer(e, mainSynthetique(phalange: 50), t0);
    evaluer(e, mainSynthetique(phalange: 50), t0.add(const Duration(milliseconds: 100)));
    // La main se déplace de 20 px (> 15 % de la largeur d'un doigt de 50 px).
    final g = evaluer(e, mainSynthetique(phalange: 50, decalage: const Offset(20, 0)),
        t0.add(const Duration(milliseconds: 700)));
    expect(g.code, CodeGuidage.bouger);
    expect(
        evaluer(e, mainSynthetique(phalange: 50, decalage: const Offset(20, 0)),
                t0.add(const Duration(milliseconds: 800)))
            .pret,
        isFalse);
  });

  test('main penchée : « tenez la main à plat » (si le contrôle est activé)', () {
    MainDetectee penchee() {
      final m = mainSynthetique(phalange: 50);
      // Auriculaire (bout 20) 0,2 largeur d'image plus loin que les autres bouts.
      final z = List<double>.filled(21, 0)..[20] = 0.2;
      return MainDetectee(
          cote: m.cote, confiance: m.confiance, points: m.points, paume: m.paume,
          doigts: m.doigts, profondeurs: z);
    }

    final sansControle = evaluer(EvaluateurCapture(), penchee(), t0);
    expect(sansControle.code, isNot(CodeGuidage.aplatir));
    // 0,2 × 480 px = 96 px de profondeur pour des doigts de 50 px → 1,9 largeur.
    expect(sansControle.platitude, closeTo(1.92, 0.01));

    final avecControle = EvaluateurCapture(seuils: const SeuilsCapture(platitudeMax: 1.0));
    expect(evaluer(avecControle, penchee(), t0).code, CodeGuidage.aplatir);
  });

  test('étape pouce : un seul doigt, pas de contrôle de paume ni d\'écartement', () {
    final e = EvaluateurCapture();
    final etape = EtapeCapture.sequence[2];
    expect(etape.doigts, [0]);
    final main = mainSynthetique(paume: false, ecart: 10, phalange: 50);
    final g = e.evaluer(analyseAvec([main]), etape, facteurCapture: facteur, maintenant: t0);
    expect(g.code, isNot(CodeGuidage.tournerPaume));
    expect(g.code, isNot(CodeGuidage.ecarterDoigts));
    expect(g.doigts.single.doigt, 0);
  });
}
