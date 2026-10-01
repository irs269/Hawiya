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
  // Doigt de 55 px → 343,75 px → ≈ 485 dpi (dans la fenêtre 450-620).
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
    final g = evaluer(EvaluateurCapture(), mainSynthetique(phalange: 55, ecart: 40), t0);
    expect(g.code, CodeGuidage.ecarterDoigts);
  });

  test('hors du cadre', () {
    final g = evaluer(EvaluateurCapture(),
        mainSynthetique(phalange: 55, decalage: const Offset(160, 0)), t0);
    expect(g.code, CodeGuidage.horsCadre);
  });

  test('lumière : sombre et reflet', () {
    expect(evaluer(EvaluateurCapture(), mainSynthetique(phalange: 55, luminance: 20), t0).code,
        CodeGuidage.tropSombre);
    expect(
        evaluer(EvaluateurCapture(), mainSynthetique(phalange: 55, eblouissement: 0.4), t0).code,
        CodeGuidage.reflet);
  });

  test('déclenchement seulement après 0,5 s d\'immobilité', () {
    final e = EvaluateurCapture();
    final main = mainSynthetique(phalange: 55);
    // 1re image : pas encore de preuve d'immobilité.
    expect(evaluer(e, main, t0).code, CodeGuidage.bouger);
    final g1 = evaluer(e, main, t0.add(const Duration(milliseconds: 120)));
    expect(g1.code, CodeGuidage.immobile);
    expect(g1.dpi, closeTo(485, 1));
    expect(g1.doigts.every((d) => d.ok), isTrue);
    expect(evaluer(e, main, t0.add(const Duration(milliseconds: 400))).code,
        CodeGuidage.immobile);
    expect(evaluer(e, main, t0.add(const Duration(milliseconds: 650))).pret, isTrue);
  });

  test('un mouvement remet le compteur à zéro', () {
    final e = EvaluateurCapture();
    evaluer(e, mainSynthetique(phalange: 55), t0);
    evaluer(e, mainSynthetique(phalange: 55), t0.add(const Duration(milliseconds: 100)));
    // La main se déplace de 20 px (> 15 % de la largeur d'un doigt de 55 px).
    final g = evaluer(e, mainSynthetique(phalange: 55, decalage: const Offset(20, 0)),
        t0.add(const Duration(milliseconds: 700)));
    expect(g.code, CodeGuidage.bouger);
    expect(
        evaluer(e, mainSynthetique(phalange: 55, decalage: const Offset(20, 0)),
                t0.add(const Duration(milliseconds: 800)))
            .pret,
        isFalse);
  });

  test('auriculaire plus loin : « tenez la main à plat »', () {
    MainDetectee penchee() {
      final m = mainSynthetique(phalange: 55);
      // Auriculaire (bout 20) 0,2 largeur d'image plus loin que les autres bouts.
      final z = List<double>.filled(21, 0)..[20] = 0.2;
      return MainDetectee(
          cote: m.cote, confiance: m.confiance, points: m.points, paume: m.paume,
          doigts: m.doigts, profondeurs: z);
    }

    final sansControle = evaluer(EvaluateurCapture(seuils: const SeuilsCapture(platitudeMax: 0)), penchee(), t0);
    expect(sansControle.code, isNot(CodeGuidage.aplatir));
    // 0,2 × 480 px = 96 px de profondeur pour des doigts de 55 px → 1,75 largeur.
    expect(sansControle.platitude, closeTo(1.745, 0.01));

    // Contrôle actif par défaut (seuil 1,5).
    final avecControle = EvaluateurCapture();
    expect(evaluer(avecControle, penchee(), t0).code, CodeGuidage.aplatir);
  });

  MainDetectee avecProfondeurs(MainDetectee m, List<double> z) => MainDetectee(
      cote: m.cote, confiance: m.confiance, points: m.points, paume: m.paume,
      doigts: m.doigts, profondeurs: z);

  test('main penchée en avant : « gardez la main parallèle »', () {
    // Les 4 bouts 0,2 largeur d'image plus près que leur base → −1,75 largeur de doigt.
    final z = List<double>.filled(21, 0);
    for (final b in [8, 12, 16, 20]) {
      z[b] = -0.2;
    }
    final g = evaluer(EvaluateurCapture(), avecProfondeurs(mainSynthetique(phalange: 55), z), t0);
    expect(g.inclinaison, closeTo(-1.745, 0.01));
    expect(g.platitude, closeTo(0, 1e-9));
    expect(g.code, CodeGuidage.incliner);
  });

  test('main droite, doigts vers le haut : pas d\'alerte d\'inclinaison ni d\'angle', () {
    final g = evaluer(EvaluateurCapture(), avecProfondeurs(mainSynthetique(phalange: 55), List.filled(21, 0)), t0);
    expect(g.inclinaison, closeTo(0, 1e-9));
    expect(g.angle!.abs(), lessThan(10));
    expect(g.code, isNot(anyOf(CodeGuidage.incliner, CodeGuidage.redresser, CodeGuidage.aplatir)));
  });

  test('main de travers : « doigts vers le haut »', () {
    final m = mainSynthetique(phalange: 55);
    // Base du majeur déplacée : axe base → bout du majeur penché d'environ 40°.
    final points = [...m.points];
    points[9] = Offset((205 - 0.84 * 315) / 480, 560 / 640);
    final g = evaluer(EvaluateurCapture(),
        MainDetectee(cote: m.cote, confiance: m.confiance, points: points, paume: m.paume, doigts: m.doigts), t0);
    expect(g.angle, closeTo(40, 1));
    expect(g.code, CodeGuidage.redresser);
  });

  test('étape pouce : fenêtre de distance plus large', () {
    // Le pouce synthétique mesure √(20² + 40²) ≈ 44,7 px → ≈ 394 dpi :
    // trop loin pour une main (fenêtre 450-620), accepté pour un pouce (380-850).
    final pouce = EvaluateurCapture().evaluer(
        analyseAvec([mainSynthetique(phalange: 55)]), EtapeCapture.sequence[2],
        facteurCapture: facteur, maintenant: t0);
    expect(pouce.dpi, closeTo(394, 1));
    expect(pouce.code, isNot(anyOf(CodeGuidage.rapprocher, CodeGuidage.eloigner)));
    final main = evaluer(EvaluateurCapture(), mainSynthetique(phalange: 44.7), t0);
    expect(main.dpi, closeTo(394, 1));
    expect(main.code, CodeGuidage.rapprocher);
  });

  test('étape pouce : un seul doigt, pas de contrôle de paume ni d\'écartement', () {
    final e = EvaluateurCapture();
    final etape = EtapeCapture.sequence[2];
    expect(etape.doigts, [0]);
    final main = mainSynthetique(paume: false, ecart: 10, phalange: 55);
    final g = e.evaluer(analyseAvec([main]), etape, facteurCapture: facteur, maintenant: t0);
    expect(g.code, isNot(CodeGuidage.tournerPaume));
    expect(g.code, isNot(CodeGuidage.ecarterDoigts));
    expect(g.doigts.single.doigt, 0);
  });
}
