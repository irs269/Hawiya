import 'dart:math' as math;
import 'dart:ui';

/// Indices MediaPipe des points de la main.
abstract final class Reperes {
  static const poignet = 0;

  /// Bout de chaque doigt : pouce, index, majeur, annulaire, auriculaire.
  static const bouts = [4, 8, 12, 16, 20];

  /// Articulation juste avant le bout (pour le pouce : l'articulation IP).
  static const articulations = [3, 7, 11, 15, 19];

  static const nomsDoigts = ['pouce', 'index', 'majeur', 'annulaire', 'auriculaire'];

  /// Segments du squelette de la main, pour l'affichage.
  static const liaisons = [
    [0, 1], [1, 2], [2, 3], [3, 4], // pouce
    [0, 5], [5, 6], [6, 7], [7, 8], // index
    [5, 9], [9, 10], [10, 11], [11, 12], // majeur
    [9, 13], [13, 14], [14, 15], [15, 16], // annulaire
    [13, 17], [0, 17], [17, 18], [18, 19], [19, 20], // auriculaire + paume
  ];
}

/// Zone (rectangle orienté) qui contient l'empreinte d'un bout de doigt.
class ZoneDoigt {
  const ZoneDoigt({
    required this.centre,
    required this.longueur,
    required this.largeur,
    required this.angle,
  });

  final Offset centre;

  /// Le long du doigt.
  final double longueur;

  /// En travers du doigt.
  final double largeur;

  /// Angle (radians) de l'axe du doigt, de l'articulation vers le bout.
  final double angle;

  /// Les 4 coins, dans l'ordre, pour dessiner ou découper.
  List<Offset> get coins {
    final axe = Offset(math.cos(angle), math.sin(angle));
    final travers = Offset(-axe.dy, axe.dx);
    final l = axe * (longueur / 2);
    final w = travers * (largeur / 2);
    return [centre - l - w, centre + l - w, centre + l + w, centre - l + w];
  }
}

/// Zone de l'empreinte, entre le [bout] (point MediaPipe) et l'[articulation].
///
/// ⚠️ Les points doivent être en PIXELS (pas en coordonnées normalisées 0..1,
/// dont l'échelle diffère en x et en y sur une image 3:4).
///
/// Le point « bout » de MediaPipe est un peu en retrait de la pointe réelle :
/// on prolonge donc la zone de 35 % du segment au-delà du bout. La largeur
/// d'un doigt est proche de la longueur de sa dernière phalange.
/// Ces proportions sont une première estimation, à ajuster à l'étape 3b.
ZoneDoigt zoneEmpreinte(Offset bout, Offset articulation) {
  final segment = bout - articulation;
  final longueurSegment = segment.distance;
  final angle = math.atan2(segment.dy, segment.dx);
  final debut = articulation;
  final fin = bout + segment * 0.35;
  return ZoneDoigt(
    centre: (debut + fin) / 2,
    longueur: longueurSegment * 1.35,
    largeur: longueurSegment * 1.0,
    angle: angle,
  );
}

/// Les 5 zones d'empreintes d'une main (pouce en premier).
List<ZoneDoigt> zonesEmpreintes(List<Offset> points) => [
      for (var i = 0; i < Reperes.bouts.length; i++)
        zoneEmpreinte(points[Reperes.bouts[i]], points[Reperes.articulations[i]]),
    ];

/// Passage des coordonnées de l'image analysée à celles de l'aperçu affiché.
///
/// L'aperçu est en mode « image entière » (FIT_CENTER) : si l'image n'a pas
/// le même format que la zone d'affichage, elle est centrée avec des bandes
/// noires. On applique exactement la même transformation aux points.
class CalageApercu {
  CalageApercu({required Size image, required Size zone})
      : echelle = math.min(zone.width / image.width, zone.height / image.height),
        _zone = zone,
        _image = image;

  final double echelle;
  final Size _zone;
  final Size _image;

  Offset get _decalage => Offset(
        (_zone.width - _image.width * echelle) / 2,
        (_zone.height - _image.height * echelle) / 2,
      );

  /// Point normalisé (0..1) de l'image → pixel de la zone d'affichage.
  Offset versZone(Offset normalise) =>
      _decalage +
      Offset(normalise.dx * _image.width, normalise.dy * _image.height) * echelle;

  /// Point normalisé de l'image → point normalisé de la zone d'affichage.
  Offset versZoneNormalisee(Offset normalise) {
    final p = versZone(normalise);
    return Offset(p.dx / _zone.width, p.dy / _zone.height);
  }
}

/// Centre des 4 bouts de doigts (sans le pouce) : point de mise au point.
Offset centreDesBouts(List<Offset> points) {
  var somme = Offset.zero;
  for (final i in Reperes.bouts.skip(1)) {
    somme += points[i];
  }
  return somme / 4;
}
