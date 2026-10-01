import 'package:flutter/material.dart';

import '../theme/couleurs.dart';
import 'capture_native.dart';
import 'geometrie_doigts.dart';
import 'guidage.dart';

/// Dessine, par-dessus l'aperçu, le squelette de la main et les zones
/// d'empreintes : vert = doigt prêt, blanc = pas encore, orange = paume non visible.
class PeintreMain extends CustomPainter {
  PeintreMain(this.analyse, this.guidage, {this.squelette = false});

  final Analyse? analyse;
  final Guidage? guidage;

  /// Afficher le squelette (mode débogage).
  final bool squelette;

  @override
  void paint(Canvas canvas, Size taille) {
    final a = analyse;
    final main = guidage?.main;
    if (a == null || main == null || main.points.length < 21) return;
    final calage = CalageApercu(
      image: Size(a.largeur.toDouble(), a.hauteur.toDouble()),
      zone: taille,
    );
    final points = main.points.map(calage.versZone).toList();

    if (squelette) {
      final trait = Paint()
        ..color = Colors.white.withValues(alpha: 0.45)
        ..strokeWidth = 1.5;
      for (final liaison in Reperes.liaisons) {
        canvas.drawLine(points[liaison[0]], points[liaison[1]], trait);
      }
    }

    final etats = {for (final e in guidage!.doigts) e.doigt: e};
    final paumeAttendueAbsente = guidage!.code == CodeGuidage.tournerPaume;
    final doigtsAffiches = etats.isEmpty ? [1, 2, 3, 4] : etats.keys;
    for (final d in doigtsAffiches) {
      final zone = zoneDuDoigt(points, d);
      final couleur = paumeAttendueAbsente
          ? Couleurs.alerte
          : (etats[d]?.ok ?? false)
              ? Couleurs.validation
              : Colors.white.withValues(alpha: 0.8);
      final cadre = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = couleur;
      final chemin = Path()..addPolygon(zone.coins, true);
      canvas.drawPath(chemin, cadre);
    }
  }

  @override
  bool shouldRepaint(PeintreMain ancien) =>
      ancien.analyse != analyse || ancien.guidage != guidage || ancien.squelette != squelette;
}
