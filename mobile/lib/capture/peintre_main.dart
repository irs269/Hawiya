import 'package:flutter/material.dart';

import '../theme/couleurs.dart';
import 'capture_native.dart';
import 'geometrie_doigts.dart';

/// Dessine, par-dessus l'aperçu, le squelette de chaque main et les zones
/// d'empreintes (cadres verts du prototype).
class PeintreMain extends CustomPainter {
  PeintreMain(this.analyse);

  final Analyse? analyse;

  @override
  void paint(Canvas canvas, Size taille) {
    final a = analyse;
    if (a == null || a.mains.isEmpty) return;
    final calage = CalageApercu(
      image: Size(a.largeur.toDouble(), a.hauteur.toDouble()),
      zone: taille,
    );

    final traitSquelette = Paint()
      ..color = Colors.white.withValues(alpha: 0.55)
      ..strokeWidth = 2;
    final point = Paint()..color = Colors.white;
    final cadre = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;

    for (final main in a.mains) {
      if (main.points.length < 21) continue;
      // En pixels : les coordonnées normalisées n'ont pas la même échelle en x et en y.
      final points = main.points.map(calage.versZone).toList();
      for (final liaison in Reperes.liaisons) {
        canvas.drawLine(points[liaison[0]], points[liaison[1]], traitSquelette);
      }
      for (final p in points) {
        canvas.drawCircle(p, 3, point);
      }
      // Couleur du cadre : vert si paume visible, orange sinon.
      cadre.color = main.paume ? Couleurs.validation : Couleurs.alerte;
      for (final zone in zonesEmpreintes(points)) {
        canvas.drawPath(Path()..addPolygon(zone.coins, true), cadre);
      }
    }
  }

  @override
  bool shouldRepaint(PeintreMain ancien) => ancien.analyse != analyse;
}
