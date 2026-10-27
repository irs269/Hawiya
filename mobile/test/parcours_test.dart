import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hawiya/api/modeles.dart';
import 'package:hawiya/capture/capture_native.dart';
import 'package:hawiya/parcours/parcours.dart';

DecoupeDoigt decoupe(int iso, {bool acceptee = true, double nettete = 0.1, String? chemin}) => DecoupeDoigt(
      doigt: (iso - 1) % 5,
      iso: iso,
      nom: 'doigt $iso',
      chemin: chemin ?? '/tmp/fictif_$iso.png',
      largeur: 300,
      hauteur: 400,
      nettete: nettete,
      luminance: 120,
      eblouissement: 0,
      dpiEstime: 540,
      photo: 1,
      acceptee: acceptee,
    );

Future<Uint8List> fauxFichier(String chemin) async => Uint8List.fromList(chemin.codeUnits);

ReponseIdentification reponse(VerdictIdentification v) =>
    ReponseIdentification(verdict: v, motif: 'fictif', doigtsCompares: 4, doigtsConcordants: 0);

void main() {
  group('Préparation des doigts à envoyer', () {
    test('seuls les doigts nets, triés, un par doigt (le plus net)', () async {
      final doigts = await doigtsAEnvoyer([
        decoupe(4),
        decoupe(2, nettete: 0.05, chemin: '/tmp/a.png'),
        decoupe(2, nettete: 0.09, chemin: '/tmp/b.png'),
        decoupe(5, acceptee: false),
        decoupe(3),
      ], lire: fauxFichier);
      expect(doigts.map((d) => d.iso), [2, 3, 4]);
      expect(String.fromCharCodes(doigts.first.image), '/tmp/b.png');
      expect(doigts.first.dpiEstime, 540);
    });

    test('aucun doigt net', () async {
      expect(await doigtsAEnvoyer([decoupe(2, acceptee: false)], lire: fauxFichier), isEmpty);
    });
  });

  group('Parcours identification', () {
    final doigts = [DoigtEnvoi(iso: 2, image: Uint8List(1), dpiEstime: 500)];

    test('les scans s’accumulent et sont tous renvoyés', () {
      final p = ParcoursIdentification();
      expect(p.ajouterScan(doigts).length, 1);
      p.enregistrerReponse(reponse(VerdictIdentification.nonConcluant));
      expect(p.peutRescanner, isTrue);
      expect(p.ajouterScan(doigts).length, 2);
      expect(p.reponse, isNull);
    });

    test('après 3 scans non concluants : vérification manuelle', () {
      final p = ParcoursIdentification();
      for (var i = 0; i < ParcoursIdentification.scansMax; i++) {
        p.ajouterScan(doigts);
        p.enregistrerReponse(reponse(VerdictIdentification.nonConcluant));
      }
      expect(p.peutRescanner, isFalse);
      expect(p.verificationManuelle, isTrue);
      expect(() => p.ajouterScan(doigts), throwsStateError);
    });

    test('identifié : ni rescan ni vérification manuelle', () {
      final p = ParcoursIdentification()..ajouterScan(doigts);
      p.enregistrerReponse(reponse(VerdictIdentification.identifie));
      expect(p.peutRescanner, isFalse);
      expect(p.verificationManuelle, isFalse);
    });

    test('envoi échoué : le scan est retiré ; recommencer remet à zéro', () {
      final p = ParcoursIdentification()..ajouterScan(doigts);
      p.annulerDernierScan();
      expect(p.nombreScans, 0);
      p.ajouterScan(doigts);
      p.recommencer();
      expect(p.nombreScans, 0);
      expect(p.reponse, isNull);
    });
  });
}
