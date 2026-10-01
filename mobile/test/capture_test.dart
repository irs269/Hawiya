import 'dart:math' as math;
import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:hawiya/capture/capture_native.dart';
import 'package:hawiya/capture/geometrie_doigts.dart';

void main() {
  group('Zone d\'empreinte', () {
    test('doigt vertical vers le haut : zone centrée au-dessus de l\'articulation', () {
      // Articulation en (100, 200), bout en (100, 160) : segment de 40 px vers le haut.
      final zone = zoneEmpreinte(const Offset(100, 160), const Offset(100, 200));
      expect(zone.longueur, closeTo(54, 1e-9)); // 40 × 1,35
      expect(zone.largeur, closeTo(40, 1e-9));
      expect(zone.angle, closeTo(-math.pi / 2, 1e-9));
      // De l'articulation (y=200) jusqu'à 35 % au-delà du bout (y=146) → centre y=173.
      expect(zone.centre.dx, closeTo(100, 1e-9));
      expect(zone.centre.dy, closeTo(173, 1e-9));
    });

    test('les 4 coins encadrent le centre et respectent les dimensions', () {
      final zone = zoneEmpreinte(const Offset(130, 140), const Offset(100, 180));
      final c = zone.coins;
      expect(c, hasLength(4));
      expect((c[1] - c[0]).distance, closeTo(zone.longueur, 1e-9));
      expect((c[3] - c[0]).distance, closeTo(zone.largeur, 1e-9));
      final milieu = (c[0] + c[2]) / 2;
      expect(milieu.dx, closeTo(zone.centre.dx, 1e-9));
      expect(milieu.dy, closeTo(zone.centre.dy, 1e-9));
    });

    test('pouce : zone décalée vers le bout (identique au Kotlin)', () {
      final zone = zoneEmpreinte(const Offset(100, 160), const Offset(100, 200), debut: debutPouce);
      expect(zone.longueur, closeTo(36, 1e-9));
      expect(zone.centre.dy, closeTo(164, 1e-9));
    });

    test('5 zones par main, centre des bouts sans le pouce', () {
      final points = List.generate(21, (i) => Offset(i.toDouble(), 2.0 * i));
      expect(zonesEmpreintes(points), hasLength(5));
      // Moyenne des points 8, 12, 16, 20.
      expect(centreDesBouts(points), const Offset(14, 28));
    });
  });

  group('Calage image → aperçu', () {
    test('image paysage 640×480 dans une zone portrait 300×400 : bandes en haut et en bas', () {
      final calage = CalageApercu(image: const Size(640, 480), zone: const Size(300, 400));
      // Échelle limitée par la largeur : 300/640. Hauteur affichée 225, bandes de 87,5.
      expect(calage.versZone(Offset.zero), const Offset(0, 87.5));
      expect(calage.versZone(const Offset(1, 1)), const Offset(300, 312.5));
      expect(calage.versZone(const Offset(0.5, 0.5)), const Offset(150, 200));
    });

    test('même format : aucune bande', () {
      final calage = CalageApercu(image: const Size(480, 640), zone: const Size(300, 400));
      expect(calage.versZone(const Offset(1, 1)), const Offset(300, 400));
      expect(calage.versZoneNormalisee(const Offset(0.25, 0.75)), const Offset(0.25, 0.75));
    });
  });

  group('Décodage des messages natifs', () {
    test('analyse avec une main', () {
      final analyse = Analyse.depuisMap({
        'type': 'analyse',
        'ips': 9.5,
        'latenceMs': 31,
        'largeur': 480,
        'hauteur': 640,
        'thermique': 0,
        'zoom': 1.0,
        'mains': [
          {
            'cote': 'droite',
            'confiance': 0.97,
            'points': [for (var i = 0; i < 42; i++) i / 100],
            'paume': true,
          },
        ],
      });
      expect(analyse.mains.single.cote, 'droite');
      expect(analyse.mains.single.points, hasLength(21));
      expect(analyse.mains.single.points[1], const Offset(0.02, 0.03));
      expect(analyse.largeur, 480);
    });
  });
}
