// Écrans des parcours, avec un faux serveur et une fausse caméra.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hawiya/api/client_api.dart';
import 'package:hawiya/capture/capture_native.dart';
import 'package:hawiya/capture/guidage.dart';
import 'package:hawiya/ecrans/ecran_connexion.dart';
import 'package:hawiya/ecrans/ecran_enregistrement.dart';
import 'package:hawiya/ecrans/ecran_identification.dart';
import 'package:hawiya/parcours/source_capture.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'api_test.dart' show ficheFictive, json;
import 'parcours_test.dart' show decoupe;

/// Fausse caméra : renvoie des découpes fictives, compte les effacements.
class FausseCamera extends SourceCapture {
  FausseCamera({this.nets = 4});

  final int nets;
  int captures = 0;
  int nettoyages = 0;

  @override
  Future<List<DecoupeDoigt>?> capturer(BuildContext context, List<EtapeCapture> etapes, String titre) async {
    captures++;
    return [for (var i = 0; i < 4; i++) decoupe(2 + i, acceptee: i < nets)];
  }

  @override
  Future<Uint8List> lire(String chemin) async => Uint8List.fromList([1, 2, 3]);

  @override
  Future<void> nettoyer() async => nettoyages++;
}

Future<ClientApi> api(Future<http.Response> Function(http.Request) routes) async {
  final client = ClientApi('http://serveur', client: MockClient((r) async {
    if (r.url.path == '/auth/connexion') return json({'access_token': 'jeton-fictif'});
    return routes(r);
  }));
  await client.connexion('AG-0001', 'mot-de-passe-fictif');
  return client;
}

Map<String, Object?> verdict(String v, {Map<String, Object?>? citoyen, String motif = 'motif fictif'}) => {
      'verdict': v,
      'motif': motif,
      'doigts_compares': 4,
      'doigts_concordants': v == 'identifie' ? 4 : 1,
      'doigts_illisibles': <int>[],
      'citoyen': citoyen,
    };

Future<void> ouvrir(WidgetTester tester, Widget ecran) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 2.5;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: ecran));
}

void main() {
  testWidgets('identification réussie : la fiche s’affiche, les découpes sont effacées', (tester) async {
    final camera = FausseCamera();
    final client = await api((_) async => json(verdict('identifie', citoyen: ficheFictive)));
    await ouvrir(tester, EcranIdentification(api: client, source: camera));

    await tester.tap(find.text('Scanner la main'));
    await tester.pumpAndSettle();

    expect(find.text('Personne identifiée'), findsOneWidget);
    expect(find.text('MSA Ahmed Nassur'), findsOneWidget);
    expect(find.text('KM-2026-000001-A'), findsOneWidget);
    expect(camera.nettoyages, 1);
  });

  testWidgets('non concluant : pas de fiche, rescans puis vérification manuelle', (tester) async {
    final camera = FausseCamera();
    final tailles = <int>[];
    final client = await api((r) async {
      tailles.add(((jsonDecode(r.body) as Map)['scans'] as List).length);
      return json(verdict('non_concluant', motif: 'deuxième candidat trop proche'));
    });
    await ouvrir(tester, EcranIdentification(api: client, source: camera));

    await tester.tap(find.text('Scanner la main'));
    await tester.pumpAndSettle();
    expect(find.text('Résultat non concluant'), findsOneWidget);
    expect(find.textContaining('MSA'), findsNothing);

    await tester.tap(find.text('Rescanner (scan 2 sur 3)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rescanner (scan 3 sur 3)'));
    await tester.pumpAndSettle();

    expect(find.text('Vérification manuelle'), findsOneWidget);
    expect(tailles, [1, 2, 3]); // les scans précédents sont renvoyés avec le nouveau
  });

  testWidgets('trop peu de doigts nets : rien n’est envoyé', (tester) async {
    var appels = 0;
    final client = await api((_) async {
      appels++;
      return json(verdict('identifie', citoyen: ficheFictive));
    });
    await ouvrir(tester, EcranIdentification(api: client, source: FausseCamera(nets: 2)));
    await tester.tap(find.text('Scanner la main'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Seulement 2 doigt(s) net(s)'), findsOneWidget);
    expect(appels, 0);
  });

  testWidgets('personne non enregistrée', (tester) async {
    final client = await api((_) async => json(verdict('non_enregistre')));
    await ouvrir(tester, EcranIdentification(api: client, source: FausseCamera()));
    await tester.tap(find.text('Scanner la main'));
    await tester.pumpAndSettle();
    expect(find.text('Personne non enregistrée'), findsOneWidget);
  });

  testWidgets('enregistrement : doublon possible expliqué, puis validation refusée à un agent', (tester) async {
    final client = await api((r) async {
      if (r.method == 'GET') return json(ficheFictive);
      if ((jsonDecode(r.body) as Map)['validation_superviseur'] == true) {
        return json({'detail': 'Seul un superviseur peut valider un doublon possible'}, 403);
      }
      return json({
        'detail': {'verdict': 'doublon_possible', 'motif': '1 fiche(s) ressemblante(s)', 'numeros': ['KM-2026-000007-B']},
      }, 409);
    });
    await ouvrir(tester, EcranEnregistrement(api: client, source: FausseCamera()));

    await tester.enterText(find.byType(TextField), 'KM-2026-000001-A');
    await tester.tap(find.text('Rechercher la fiche'));
    await tester.pumpAndSettle();
    expect(find.text('MSA Ahmed Nassur'), findsOneWidget);

    await tester.tap(find.text('Capturer les empreintes'));
    await tester.pumpAndSettle();
    expect(find.text('Doublon possible'), findsOneWidget);
    expect(find.textContaining('KM-2026-000007-B'), findsOneWidget);

    await tester.tap(find.text('Valider après vérification (superviseur)'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Seul un superviseur'), findsOneWidget);
  });

  testWidgets('enregistrement accepté', (tester) async {
    final client = await api((r) async {
      if (r.method == 'GET') return json(ficheFictive);
      return json({
        'numero': 'KM-2026-000001-A',
        'doigts_enregistres': [2, 3, 4, 5],
        'doigts_illisibles': <int>[],
        'controle_doublon': {'verdict': 'aucun_doublon', 'motif': 'Aucune fiche ressemblante.', 'numeros': <String>[]},
      });
    });
    await ouvrir(tester, EcranEnregistrement(api: client, source: FausseCamera()));
    await tester.enterText(find.byType(TextField), 'KM-2026-000001-A');
    await tester.tap(find.text('Rechercher la fiche'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Capturer les empreintes'));
    await tester.pumpAndSettle();
    expect(find.text('Empreintes enregistrées'), findsOneWidget);
  });

  testWidgets('connexion refusée : message affiché', (tester) async {
    await ouvrir(
      tester,
      EcranConnexion(
        fabriqueClient: (adresse) =>
            ClientApi(adresse, client: MockClient((_) async => json({'detail': 'refus'}, 401))),
      ),
    );
    await tester.enterText(find.widgetWithText(TextField, 'Matricule agent'), 'AG-0001');
    await tester.enterText(find.widgetWithText(TextField, 'Mot de passe'), 'faux');
    await tester.tap(find.text('Se connecter'));
    await tester.pumpAndSettle();
    expect(find.text('Matricule ou mot de passe incorrect.'), findsOneWidget);
    expect(find.textContaining('non officiel'), findsOneWidget);
  });
}
