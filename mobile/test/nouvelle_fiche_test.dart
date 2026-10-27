// Parcours « Enregistrer une personne » à l'écran : faux serveur, fausse
// caméra, fausse photo (aucune donnée réelle).
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hawiya/capture/capture_native.dart';
import 'package:hawiya/capture/guidage.dart';
import 'package:hawiya/fiche/ecran_nouvelle_fiche.dart';
import 'package:hawiya/fiche/fiche.dart';
import 'package:hawiya/fiche/signature.dart';
import 'package:hawiya/fiche/source_photo.dart';
import 'package:hawiya/parcours/source_capture.dart';

import 'envoi_test.dart' show FauxServeur;
import 'fiche_test.dart' show ficheComplete, imageFictive;
import 'parcours_test.dart' show decoupe;

/// Fausse caméra : tous les doigts des étapes demandées, nets.
class CameraComplete extends SourceCapture {
  int nettoyages = 0;

  @override
  Future<List<DecoupeDoigt>?> capturer(BuildContext context, List<EtapeCapture> etapes, String titre) async =>
      [for (final e in etapes) for (final iso in isoDeLEtape(e)) decoupe(iso)];

  @override
  Future<Uint8List> lire(String chemin) async => Uint8List.fromList([1, 2, 3]);

  @override
  Future<void> nettoyer() async => nettoyages++;
}

class FaussePhoto extends SourcePhoto {
  @override
  Future<Uint8List?> prendre() async => imageFictive;
}

Future<void> ouvrir(WidgetTester tester, Widget ecran) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 2.5;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: ecran));
}

Future<void> toucher(WidgetTester tester, String texte) async {
  final cible = find.text(texte);
  await tester.ensureVisible(cible);
  await tester.pumpAndSettle();
  await tester.tap(cible);
  await tester.pumpAndSettle();
}

void main() {
  test('chaque étape de capture correspond aux bons doigts ISO', () {
    expect([for (final e in EtapeCapture.sequence) isoDeLEtape(e)], [
      [2, 3, 4, 5],
      [7, 8, 9, 10],
      [1],
      [6],
    ]);
  });

  testWidgets("formulaire vide : on ne passe pas, les erreurs s'affichent", (tester) async {
    final serveur = FauxServeur();
    await serveur.client.connexion('AG-0001', 'x');
    await ouvrir(tester, EcranNouvelleFiche(api: serveur.client, source: CameraComplete(), sourcePhoto: FaussePhoto()));

    await toucher(tester, 'Suivant');
    expect(find.text('Identité'), findsOneWidget); // toujours à l'étape 1
    expect(find.text('Champ obligatoire'), findsWidgets);
    expect(find.text('Date obligatoire'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextFormField, 'Téléphone (facultatif)'), '12');
    await tester.pumpAndSettle();
    expect(find.text('Attendu : +269 suivi de 7 chiffres'), findsOneWidget);
  });

  testWidgets('parcours complet : formulaire → empreintes → numéro attribué', (tester) async {
    final serveur = FauxServeur();
    await serveur.client.connexion('AG-0001', 'x');
    final camera = CameraComplete();
    final fiche = ficheComplete()
      ..photo = null
      ..signature = null;
    await ouvrir(
      tester,
      EcranNouvelleFiche(api: serveur.client, source: camera, sourcePhoto: FaussePhoto(), brouillon: fiche),
    );

    await toucher(tester, 'Suivant'); // identité pré-remplie
    expect(find.text('Domicile et signalement'), findsOneWidget);
    await toucher(tester, 'Suivant');

    // Photo et signature : obligatoires.
    await toucher(tester, 'Suivant');
    expect(find.text('Photo du visage obligatoire'), findsOneWidget);
    await toucher(tester, 'Prendre la photo');
    expect(find.text('Reprendre la photo'), findsOneWidget);
    fiche.signature = imageFictive; // le dessin est testé à part
    await toucher(tester, 'Suivant');

    // Empreintes : au moins 8 doigts nets.
    expect(find.text('Empreintes'), findsOneWidget);
    await toucher(tester, 'Suivant');
    expect(find.textContaining('Au moins 8 doigts'), findsOneWidget);
    await toucher(tester, 'Capturer les empreintes');
    expect(find.text('10 doigt(s) net(s) sur 10'), findsOneWidget);
    expect(camera.nettoyages, 1);
    await toucher(tester, 'Suivant');

    // Récapitulatif puis envoi.
    expect(find.text('Récapitulatif'), findsOneWidget);
    expect(find.text('+2693210000'), findsOneWidget);
    await toucher(tester, 'Enregistrer');

    expect(find.text('Enregistrement terminé'), findsOneWidget);
    expect(find.text('KM-2026-000001-A'), findsWidgets);
    expect(serveur.appels.first, 'POST /doublons');
    expect(serveur.corps['PUT /citoyens/KM-2026-000001-A/empreintes']!['doigts'], hasLength(10));
  });

  testWidgets("doublon certain : arrêt expliqué, pas de numéro", (tester) async {
    final serveur = FauxServeur(doublon: 'doublon_certain');
    await serveur.client.connexion('AG-0001', 'x');
    await ouvrir(
      tester,
      EcranNouvelleFiche(api: serveur.client, source: CameraComplete(), sourcePhoto: FaussePhoto(), brouillon: ficheComplete()),
    );
    for (var i = 0; i < 3; i++) {
      await toucher(tester, 'Suivant');
    }
    await toucher(tester, 'Capturer les empreintes');
    await toucher(tester, 'Suivant');
    await toucher(tester, 'Enregistrer');

    expect(find.text('Personne déjà enregistrée'), findsOneWidget);
    expect(find.textContaining('KM-2026-000007-B'), findsOneWidget);
    expect(serveur.appels, ['POST /doublons']);
  });

  testWidgets('quitter demande confirmation', (tester) async {
    final serveur = FauxServeur();
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute<void>(builder: (_) => EcranNouvelleFiche(api: serveur.client)),
          ),
          child: const Text('ouvrir'),
        ),
      ),
    ));
    await tester.tap(find.text('ouvrir'));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Abandonner cet enregistrement ?'), findsOneWidget);
    await tester.tap(find.text('Abandonner'));
    await tester.pumpAndSettle();
    expect(find.text('ouvrir'), findsOneWidget);
  });

  testWidgets('signature : dessin au doigt puis export PNG', (tester) async {
    final controleur = ControleurSignature();
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: PadSignature(controleur: controleur))));
    expect(controleur.vide, isTrue);
    await tester.drag(find.byType(PadSignature), const Offset(120, 30));
    await tester.pump();
    expect(controleur.vide, isFalse);

    final png = await tester.runAsync(() => exporterSignature(controleur.traits, const Size(300, 150)));
    expect(png!.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]); // en-tête PNG
    controleur.effacer();
    expect(controleur.vide, isTrue);
  });

  test('brouillon : nationalité par défaut', () => expect(BrouillonFiche().nationalite, 'Comorienne'));
}
