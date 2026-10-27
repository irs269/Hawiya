import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../theme/couleurs.dart';

/// Traits de la signature (une liste de points par trait), en coordonnées du cadre.
class ControleurSignature extends ChangeNotifier {
  final List<List<Offset>> traits = [];

  bool get vide => traits.every((t) => t.isEmpty);

  void commencer(Offset p) {
    traits.add([p]);
    notifyListeners();
  }

  void prolonger(Offset p) {
    if (traits.isEmpty) return;
    traits.last.add(p);
    notifyListeners();
  }

  void effacer() {
    traits.clear();
    notifyListeners();
  }
}

/// Dessine les traits : encre sombre sur fond blanc.
class _PeintreSignature extends CustomPainter {
  _PeintreSignature(this.controleur) : super(repaint: controleur);

  final ControleurSignature controleur;

  static Paint get crayon => Paint()
    ..color = Couleurs.texte
    ..strokeWidth = 3
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..style = PaintingStyle.stroke;

  static void dessiner(Canvas canvas, List<List<Offset>> traits) {
    for (final t in traits) {
      if (t.length == 1) {
        canvas.drawCircle(t.first, 1.5, crayon..style = PaintingStyle.fill);
        continue;
      }
      final chemin = Path()..moveTo(t.first.dx, t.first.dy);
      for (final p in t.skip(1)) {
        chemin.lineTo(p.dx, p.dy);
      }
      canvas.drawPath(chemin, crayon);
    }
  }

  @override
  void paint(Canvas canvas, Size size) => dessiner(canvas, controleur.traits);

  @override
  bool shouldRepaint(_PeintreSignature ancien) => true;
}

/// Cadre où la personne signe avec le doigt.
class PadSignature extends StatelessWidget {
  const PadSignature({super.key, required this.controleur, this.hauteur = 200});

  final ControleurSignature controleur;
  final double hauteur;

  @override
  Widget build(BuildContext context) => Container(
        height: hauteur,
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: Colors.black26),
          borderRadius: BorderRadius.circular(12),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: GestureDetector(
            onPanStart: (d) => controleur.commencer(d.localPosition),
            onPanUpdate: (d) => controleur.prolonger(d.localPosition),
            child: CustomPaint(painter: _PeintreSignature(controleur), size: Size.infinite),
          ),
        ),
      );
}

/// Image PNG de la signature (fond blanc), à la taille du cadre × `echelle`.
Future<Uint8List> exporterSignature(List<List<Offset>> traits, Size taille, {double echelle = 2}) async {
  final enregistreur = ui.PictureRecorder();
  final canvas = Canvas(enregistreur)
    ..scale(echelle)
    ..drawRect(Offset.zero & taille, Paint()..color = Colors.white);
  _PeintreSignature.dessiner(canvas, traits);
  final image = await enregistreur
      .endRecording()
      .toImage((taille.width * echelle).round(), (taille.height * echelle).round());
  final donnees = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return donnees!.buffer.asUint8List();
}
