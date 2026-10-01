import 'dart:math' as math;
import 'dart:ui' show Offset;

import 'capture_native.dart';
import 'geometrie_doigts.dart';

/// Ce que l'on capture à une étape : 4 doigts d'une main, ou un pouce.
enum TypeEtape { quatreDoigts, pouce }

class EtapeCapture {
  const EtapeCapture({
    required this.main,
    required this.type,
    required this.titre,
    required this.consigne,
  });

  /// « droite » ou « gauche ».
  final String main;
  final TypeEtape type;
  final String titre;
  final String consigne;

  /// Doigts MediaPipe concernés (0 = pouce … 4 = auriculaire).
  List<int> get doigts => type == TypeEtape.pouce ? const [0] : const [1, 2, 3, 4];

  /// Ordre du document : main droite, main gauche, puis les pouces.
  static const sequence = [
    EtapeCapture(
      main: 'droite',
      type: TypeEtape.quatreDoigts,
      titre: 'Main droite · 4 doigts',
      consigne: 'Présentez la main droite, paume vers la caméra, doigts écartés.',
    ),
    EtapeCapture(
      main: 'gauche',
      type: TypeEtape.quatreDoigts,
      titre: 'Main gauche · 4 doigts',
      consigne: 'Présentez la main gauche, paume vers la caméra, doigts écartés.',
    ),
    EtapeCapture(
      main: 'droite',
      type: TypeEtape.pouce,
      titre: 'Pouce droit',
      consigne: "Poing droit fermé, pouce levé : l'intérieur du pouce face à la caméra.",
    ),
    EtapeCapture(
      main: 'gauche',
      type: TypeEtape.pouce,
      titre: 'Pouce gauche',
      consigne: "Poing gauche fermé, pouce levé : l'intérieur du pouce face à la caméra.",
    ),
  ];
}

/// Seuils de qualité. Valeurs de départ, à ajuster avec le mode débogage.
class SeuilsCapture {
  const SeuilsCapture({
    this.dpiMin = 450,
    this.dpiMax = 620,
    this.dpiMinPouce = 380,
    this.dpiMaxPouce = 850,
    this.inclinaisonMax = 1.5,
    this.angleMaxDegres = 25,
    this.largeurDoigtMm = 18,
    this.margeCadre = 0.03,
    this.ecartementMin = 0.9,
    this.mouvementMax = 0.15,
    this.luminanceMin = 50,
    this.luminanceMax = 235,
    this.eblouissementMax = 0.10,
    this.netteteApercuMin = 0,
    this.dureeStabilite = const Duration(milliseconds: 500),
    this.seuilNettete = 0.04,
    this.platitudeMax = 1.5,
  });

  /// Pouces : fenêtre large. Un pouce est plus large que les 18 mm supposés,
  /// d'où une résolution estimée plus haute (constaté : 600 à 810 dpi).
  final double dpiMinPouce;
  final double dpiMaxPouce;

  /// Main penchée en avant ou en arrière : écart de profondeur entre les bouts
  /// des doigts et leur base, en largeurs de doigt. Valeur de départ tolérante,
  /// à calibrer avec les mesures enregistrées dans le JSON des captures.
  final double inclinaisonMax;

  /// Doigts vers le haut : écart maximal de l'axe du majeur avec la verticale.
  final double angleMaxDegres;

  /// Netteté des crêtes minimale (0..1) d'une découpe pleine résolution pour
  /// l'accepter. Calibrage du 01/10/2026 (S23 Ultra, 28 découpes, 9 examinées
  /// à l'œil) : la pire découpe acceptable vaut 0,040, la meilleure refusée
  /// 0,024 → seuil 0,03. Validation (2 sessions) : un auriculaire à 0,032
  /// accepté était presque flou → seuil remonté à 0,04. À revoir avec les
  /// volontaires (phase 4) : la zone 0,03-0,04 mélange médiocre et flou.
  final double seuilNettete;

  /// Écart de profondeur maximal entre les bouts des 4 doigts, en largeurs de
  /// doigt (« main bien à plat »). Valeur de départ tolérante, à calibrer.
  /// 0 = contrôle désactivé.
  final double platitudeMax;

  /// Résolution estimée de la future photo (doigt supposé large de [largeurDoigtMm]).
  /// Fenêtre resserrée (levier 2, phase 4) : SourceAFIS perd la correspondance
  /// dès ~10 % d'écart d'échelle ; 450-620 ≈ ±15 % autour de 530, ce que
  /// couvre la comparaison multi-échelle.
  final double dpiMin;
  final double dpiMax;
  final double largeurDoigtMm;

  /// Marge minimale entre une zone de doigt et le bord de l'image (fraction).
  final double margeCadre;

  /// Distance minimale entre deux bouts de doigts voisins, en largeurs de doigt.
  final double ecartementMin;

  /// Déplacement maximal d'un bout de doigt entre deux analyses, en largeurs de doigt.
  final double mouvementMax;

  final double luminanceMin;
  final double luminanceMax;
  final double eblouissementMax;

  /// Netteté minimale sur l'image d'analyse. 0 = désactivé tant qu'il n'est pas
  /// calibré (l'échelle dépend du téléphone) ; la vraie netteté des crêtes est
  /// mesurée sur les photos pleine résolution.
  final double netteteApercuMin;

  /// Durée pendant laquelle tout doit rester bon avant de déclencher.
  final Duration dureeStabilite;
}

/// Raison du message affiché, par ordre de priorité.
enum CodeGuidage {
  aucuneMain,
  mauvaiseMain,
  tournerPaume,
  aplatir,
  incliner,
  redresser,
  horsCadre,
  rapprocher,
  eloigner,
  ecarterDoigts,
  tropSombre,
  tropClair,
  reflet,
  flou,
  bouger,
  immobile,
  pret,
}

/// État d'un doigt, pour colorer son cadre.
class EtatDoigt {
  const EtatDoigt({required this.doigt, required this.ok, required this.dpi, this.mesures});

  final int doigt;
  final bool ok;
  final double dpi;
  final MesuresDoigt? mesures;
}

class Guidage {
  const Guidage({
    required this.code,
    required this.message,
    this.main,
    this.doigts = const [],
    this.dpi,
    this.progression = 0,
    this.platitude,
    this.inclinaison,
    this.angle,
  });

  /// Écart de profondeur entre les bouts des doigts, en largeurs de doigt
  /// (0 = main parfaitement à plat). Null si non mesurable.
  final double? platitude;

  /// Profondeur des bouts des doigts moins celle de leur base, en largeurs de
  /// doigt (négatif = bouts plus proches du téléphone). Null si non mesurable.
  final double? inclinaison;

  /// Angle de l'axe du majeur avec la verticale, en degrés.
  final double? angle;

  /// Mesures de pose au moment du déclenchement, enregistrées dans le JSON
  /// de débogage pour calibrer les seuils.
  Map<String, Object?> versContexte() => {
        'code': code.name,
        'dpi': dpi,
        'platitude': platitude,
        'inclinaison': inclinaison,
        'angle': angle,
      };

  final CodeGuidage code;
  final String message;

  /// Main retenue pour l'étape (null si aucune).
  final MainDetectee? main;
  final List<EtatDoigt> doigts;

  /// Résolution moyenne estimée des doigts de l'étape.
  final double? dpi;

  /// 0..1 : temps de stabilité écoulé avant le déclenchement.
  final double progression;

  bool get pret => code == CodeGuidage.pret;
}

/// Décide, image après image, du message à afficher et du moment de déclencher.
///
/// Logique pure (aucun accès caméra) : testée dans test/guidage_test.dart.
class EvaluateurCapture {
  EvaluateurCapture({this.seuils = const SeuilsCapture()});

  final SeuilsCapture seuils;
  List<Offset>? _boutsPrecedents;
  DateTime? _debutStable;

  void reinitialiser() {
    _boutsPrecedents = null;
    _debutStable = null;
  }

  /// [facteurCapture] = largeur de la photo pleine résolution / largeur de l'image
  /// d'analyse (portrait). Sert à estimer la résolution des futures découpes.
  Guidage evaluer(
    Analyse a,
    EtapeCapture etape, {
    required double facteurCapture,
    required DateTime maintenant,
  }) {
    final main = _choisirMain(a, etape);
    if (main == null) {
      return _echec(a.mains.isEmpty ? CodeGuidage.aucuneMain : CodeGuidage.mauvaiseMain,
          etape: etape);
    }
    if (etape.type == TypeEtape.quatreDoigts && !main.paume) {
      return _echec(CodeGuidage.tournerPaume, etape: etape, main: main);
    }

    // Géométrie en pixels de l'image d'analyse.
    final points = [
      for (final p in main.points) Offset(p.dx * a.largeur, p.dy * a.hauteur),
    ];
    // dpi = largeur du doigt sur la photo (px) / largeur du doigt (pouces).
    final pxParMm = 25.4 / seuils.largeurDoigtMm; // facteur : px de photo → dpi
    final pouce = etape.type == TypeEtape.pouce;
    final dpiMin = pouce ? seuils.dpiMinPouce : seuils.dpiMin;
    final dpiMax = pouce ? seuils.dpiMaxPouce : seuils.dpiMax;
    final etats = <EtatDoigt>[];
    var horsCadre = false;
    for (final d in etape.doigts) {
      final zone = zoneDuDoigt(points, d);
      final dansCadre = _dansCadre(zone, a.largeur.toDouble(), a.hauteur.toDouble());
      horsCadre |= !dansCadre;
      final dpi = zone.largeur * facteurCapture * pxParMm;
      final mesures = d < main.doigts.length ? main.doigts[d] : null;
      etats.add(EtatDoigt(
        doigt: d,
        dpi: dpi,
        mesures: mesures,
        ok: dansCadre &&
            dpi >= dpiMin &&
            dpi <= dpiMax &&
            (mesures == null || _lumiereOk(mesures)),
      ));
    }
    final dpiMoyen = etats.map((e) => e.dpi).reduce((x, y) => x + y) / etats.length;
    final bouts = [for (final d in etape.doigts) points[Reperes.bouts[d]]];
    final largeurMoyenne = dpiMoyen / (facteurCapture * pxParMm);

    // Immobilité : comparée à l'analyse précédente (toujours mise à jour).
    final mouvement = _mouvement(bouts, largeurMoyenne);
    _boutsPrecedents = bouts;
    final platitude = _platitude(main, etape, a.largeur.toDouble(), largeurMoyenne);
    final inclinaison = _inclinaison(main, etape, a.largeur.toDouble(), largeurMoyenne);
    final angle = etape.type == TypeEtape.quatreDoigts ? _angle(points) : null;

    CodeGuidage? probleme;
    if (seuils.platitudeMax > 0 && platitude != null && platitude > seuils.platitudeMax) {
      probleme = CodeGuidage.aplatir;
    } else if (seuils.inclinaisonMax > 0 && inclinaison != null && inclinaison.abs() > seuils.inclinaisonMax) {
      probleme = CodeGuidage.incliner;
    } else if (angle != null && angle.abs() > seuils.angleMaxDegres) {
      probleme = CodeGuidage.redresser;
    } else if (horsCadre) {
      probleme = CodeGuidage.horsCadre;
    } else if (dpiMoyen < dpiMin) {
      probleme = CodeGuidage.rapprocher;
    } else if (dpiMoyen > dpiMax) {
      probleme = CodeGuidage.eloigner;
    } else if (etape.type == TypeEtape.quatreDoigts && !_ecartes(bouts, largeurMoyenne)) {
      probleme = CodeGuidage.ecarterDoigts;
    } else {
      probleme = _problemeLumiere(etats) ?? _problemeNettete(etats);
    }
    if (probleme == null && mouvement > seuils.mouvementMax) probleme = CodeGuidage.bouger;

    if (probleme != null) {
      _debutStable = null;
      return Guidage(
        code: probleme,
        message: messages[probleme]!,
        main: main,
        doigts: etats,
        dpi: dpiMoyen,
        platitude: platitude,
        inclinaison: inclinaison,
        angle: angle,
      );
    }

    // Tout est bon : il faut que ça dure [dureeStabilite].
    _debutStable ??= maintenant;
    final ecoule = maintenant.difference(_debutStable!);
    final progression =
        (ecoule.inMilliseconds / seuils.dureeStabilite.inMilliseconds).clamp(0.0, 1.0);
    final pret = ecoule >= seuils.dureeStabilite;
    final code = pret ? CodeGuidage.pret : CodeGuidage.immobile;
    return Guidage(
      code: code,
      message: messages[code]!,
      main: main,
      doigts: etats,
      dpi: dpiMoyen,
      progression: progression,
      platitude: platitude,
      inclinaison: inclinaison,
      angle: angle,
    );
  }

  /// Profondeur moyenne des 4 bouts moins celle des 4 bases (MediaPipe z,
  /// échelle ≈ largeur de l'image), en largeurs de doigt.
  double? _inclinaison(MainDetectee main, EtapeCapture etape, double largeurImage, double largeurDoigt) {
    if (etape.type != TypeEtape.quatreDoigts || main.profondeurs.length < 21 || largeurDoigt <= 0) {
      return null;
    }
    double moyenne(List<int> indices) =>
        indices.map((i) => main.profondeurs[i]).reduce((x, y) => x + y) / indices.length;
    const bases = [5, 9, 13, 17];
    final bouts = [for (final d in etape.doigts) Reperes.bouts[d]];
    return (moyenne(bouts) - moyenne(bases)) * largeurImage / largeurDoigt;
  }

  /// Angle (degrés) de l'axe base du majeur → bout du majeur avec la verticale
  /// (0 = doigts vers le haut ; positif = penchés vers la droite de l'image).
  double _angle(List<Offset> points) {
    final axe = points[12] - points[9];
    return math.atan2(axe.dx, -axe.dy) * 180 / math.pi;
  }

  /// Écart de profondeur (MediaPipe z, échelle ≈ largeur de l'image) entre le
  /// bout le plus proche et le plus éloigné, en largeurs de doigt. 4 doigts seulement.
  double? _platitude(MainDetectee main, EtapeCapture etape, double largeurImage, double largeurDoigt) {
    if (etape.type != TypeEtape.quatreDoigts || main.profondeurs.length < 21 || largeurDoigt <= 0) {
      return null;
    }
    final z = [for (final d in etape.doigts) main.profondeurs[Reperes.bouts[d]] * largeurImage];
    return (z.reduce(math.max) - z.reduce(math.min)) / largeurDoigt;
  }

  Guidage _echec(CodeGuidage code, {required EtapeCapture etape, MainDetectee? main}) {
    reinitialiser();
    final message = switch (code) {
      CodeGuidage.aucuneMain => etape.consigne,
      CodeGuidage.mauvaiseMain => 'Présentez la main ${etape.main}.',
      _ => messages[code]!,
    };
    return Guidage(code: code, message: message, main: main);
  }

  /// Main attendue ; pour les pouces, la pose « poing fermé » rend le côté
  /// moins fiable : on accepte la plus grande main si le côté ne correspond pas.
  MainDetectee? _choisirMain(Analyse a, EtapeCapture etape) {
    final bonnes = a.mains.where((m) => m.cote == etape.main).toList();
    if (bonnes.isNotEmpty) return bonnes.first;
    if (etape.type == TypeEtape.pouce && a.mains.isNotEmpty) return a.mains.first;
    return null;
  }

  bool _dansCadre(ZoneDoigt zone, double largeur, double hauteur) {
    final mx = largeur * seuils.margeCadre;
    final my = hauteur * seuils.margeCadre;
    return zone.coins.every((c) =>
        c.dx >= mx && c.dy >= my && c.dx <= largeur - mx && c.dy <= hauteur - my);
  }

  bool _ecartes(List<Offset> bouts, double largeurDoigt) {
    for (var i = 0; i + 1 < bouts.length; i++) {
      if ((bouts[i] - bouts[i + 1]).distance < seuils.ecartementMin * largeurDoigt) {
        return false;
      }
    }
    return true;
  }

  double _mouvement(List<Offset> bouts, double largeurDoigt) {
    final precedents = _boutsPrecedents;
    if (precedents == null || precedents.length != bouts.length || largeurDoigt <= 0) {
      return double.infinity; // première image : pas encore de preuve d'immobilité
    }
    var maximum = 0.0;
    for (var i = 0; i < bouts.length; i++) {
      maximum = math.max(maximum, (bouts[i] - precedents[i]).distance);
    }
    return maximum / largeurDoigt;
  }

  bool _lumiereOk(MesuresDoigt m) =>
      m.luminance >= seuils.luminanceMin &&
      m.luminance <= seuils.luminanceMax &&
      m.eblouissement <= seuils.eblouissementMax;

  CodeGuidage? _problemeLumiere(List<EtatDoigt> etats) {
    for (final e in etats) {
      final m = e.mesures;
      if (m == null) continue;
      if (m.luminance < seuils.luminanceMin) return CodeGuidage.tropSombre;
      if (m.eblouissement > seuils.eblouissementMax) return CodeGuidage.reflet;
      if (m.luminance > seuils.luminanceMax) return CodeGuidage.tropClair;
    }
    return null;
  }

  CodeGuidage? _problemeNettete(List<EtatDoigt> etats) {
    if (seuils.netteteApercuMin <= 0) return null;
    for (final e in etats) {
      final m = e.mesures;
      if (m != null && m.nettete < seuils.netteteApercuMin) return CodeGuidage.flou;
    }
    return null;
  }

  static const messages = {
    CodeGuidage.aucuneMain: 'Présentez la main devant la caméra.',
    CodeGuidage.mauvaiseMain: "Ce n'est pas la bonne main.",
    CodeGuidage.tournerPaume: 'Tournez la paume vers la caméra.',
    CodeGuidage.aplatir: 'Tenez la main bien à plat, face au téléphone.',
    CodeGuidage.incliner: 'Gardez la main parallèle au téléphone, ni penchée en avant ni en arrière.',
    CodeGuidage.redresser: 'Doigts vers le haut, main bien droite.',
    CodeGuidage.horsCadre: 'Gardez les doigts dans le cadre.',
    CodeGuidage.rapprocher: 'Rapprochez la main.',
    CodeGuidage.eloigner: 'Éloignez un peu la main.',
    CodeGuidage.ecarterDoigts: 'Écartez les doigts.',
    CodeGuidage.tropSombre: 'Trop sombre : vérifiez le flash.',
    CodeGuidage.tropClair: 'Trop de lumière : éloignez un peu la main.',
    CodeGuidage.reflet: 'Reflet du flash : inclinez légèrement la main.',
    CodeGuidage.flou: 'Image floue : ne bougez pas, mise au point…',
    CodeGuidage.bouger: 'Ne bougez plus.',
    CodeGuidage.immobile: 'Ne bougez plus…',
    CodeGuidage.pret: 'Capture !',
  };
}
