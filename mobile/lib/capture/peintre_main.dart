import 'package:flutter/material.dart';

import '../theme/couleurs.dart';
import 'capture_native.dart';
import 'geometrie_doigts.dart';

/// Dessine, par-dessus l'aperçu, le squelette de chaque main et les zones
/// d'empreintes (cadres verts du prototype).
class PeintreMain extends CustomPainter {
  PeintreMain(this.mains);

  final List<MainDetectee> mains;

  @override
  void paint(Canvas canvas, Size taille) {
    Offset ecran(Offset p) => Offset(p.dx * taille.width, p.dy * taille.height);

    final traitSquelette = Paint()
      ..color = Colors.white.withValues(alpha: 0.55)
      ..strokeWidth = 2;
    final point = Paint()..color = Colors.white;
    final cadre = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..color = Couleurs.validation;

    for (final main in mains) {
      if (main.points.length < 21) continue;
      // En pixels : les coordonnées normalisées n'ont pas la même échelle en x et en y.
      final points = main.points.map(ecran).toList();
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
  bool shouldRepaint(PeintreMain ancien) => ancien.mains != mains;
}
