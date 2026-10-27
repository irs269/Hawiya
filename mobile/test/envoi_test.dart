// Ordre des envois d'un enregistrement, avec un FAUX serveur.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hawiya/api/client_api.dart';
import 'package:hawiya/api/modeles.dart';
import 'package:hawiya/fiche/envoi.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'api_test.dart' show ficheFictive, json;
import 'fiche_test.dart' show ficheComplete;

/// Faux serveur qui note chaque appel (« MÉTHODE /chemin »).
class FauxServeur {
  FauxServeur({this.doublon = 'aucun_doublon'});

  String doublon;
  final appels = <String>[];
  final corps = <String, Map<String, dynamic>>{};
  bool panneMedias = false;

  /// Plus aucun réseau (sauf la connexion déjà faite).
  bool horsLigne = false;

  /// Code d'erreur renvoyé à la création de la fiche (ex. 422).
  int? refusCreation;

  late final client = ClientApi('http://serveur', client: MockClient(_repondre));

  Future<http.Response> _repondre(http.Request r) async {
    final cle = '${r.method} ${r.url.path}';
    if (r.url.path == '/auth/connexion') return json({'access_token': 'jeton-fictif'});
    if (horsLigne) throw http.ClientException('réseau coupé');
    appels.add(cle);
    if (r.body.isNotEmpty) corps[cle] = jsonDecode(r.body) as Map<String, dynamic>;
    switch (cle) {
      case 'POST /doublons':
        return json({'verdict': doublon, 'motif': 'motif fictif', 'numeros': doublon == 'aucun_doublon' ? [] : ['KM-2026-000007-B']});
      case 'POST /citoyens':
        if (refusCreation != null) {
          return json({
            'detail': [
              {'loc': ['body', 'taille_cm'], 'msg': 'valeur refusée'},
            ],
          }, refusCreation!);
        }
        return json(ficheFictive, 201);
      case 'PUT /citoyens/KM-2026-000001-A/medias':
        if (panneMedias) throw http.ClientException('réseau coupé');
        return json({'photo': true, 'signature': true});
      case 'PUT /citoyens/KM-2026-000001-A/empreintes':
        return json({
          'numero': 'KM-2026-000001-A',
          'doigts_enregistres': [1, 2],
          'doigts_illisibles': [],
          'controle_doublon': {'verdict': doublon, 'motif': 'motif fictif', 'numeros': []},
        });
    }
    return json({'detail': 'route inconnue'}, 404);
  }
}

final doigts = [
  for (final iso in [1, 2]) DoigtEnvoi(iso: iso, image: Uint8List.fromList([iso]), dpiEstime: 550),
];

Future<EnvoiEnregistrement> envoi(FauxServeur serveur) async {
  await serveur.client.connexion('AG-0001', 'mot-de-passe-fictif');
  return EnvoiEnregistrement(api: serveur.client, fiche: ficheComplete(), doigts: doigts);
}

void main() {
  test("aucun doublon : contrôle AVANT création, puis médias et empreintes", () async {
    final serveur = FauxServeur();
    final e = await envoi(serveur);
    final etapes = <EtapeEnvoi>[];
    expect(await e.continuer(progression: etapes.add), IssueEnvoi.termine);
    expect(serveur.appels, [
      'POST /doublons',
      'POST /citoyens',
      'PUT /citoyens/KM-2026-000001-A/medias',
      'PUT /citoyens/KM-2026-000001-A/empreintes',
    ]);
    expect(etapes.last, EtapeEnvoi.termine);
    expect(e.citoyen!.numero, 'KM-2026-000001-A');
    expect(serveur.corps['POST /citoyens']!['telephone'], '+2693210000');
    expect(serveur.corps['PUT /citoyens/KM-2026-000001-A/medias']!.keys, containsAll(['photo', 'signature']));
  });

  test("doublon certain : arrêt, aucun numéro attribué", () async {
    final serveur = FauxServeur(doublon: 'doublon_certain');
    final e = await envoi(serveur);
    expect(await e.continuer(), IssueEnvoi.doublonCertain);
    expect(serveur.appels, ['POST /doublons']);
    expect(e.controle!.numeros, ['KM-2026-000007-B']);
  });

  test("doublon possible : arrêt, puis reprise après validation d'un superviseur", () async {
    final serveur = FauxServeur(doublon: 'doublon_possible');
    final e = await envoi(serveur);
    expect(await e.continuer(), IssueEnvoi.doublonPossible);
    expect(serveur.appels, ['POST /doublons']);

    e.validerParSuperviseur();
    expect(await e.continuer(), IssueEnvoi.termine);
    // Pas de second contrôle ; la validation est transmise avec les empreintes.
    expect(serveur.appels.where((a) => a == 'POST /doublons').length, 1);
    expect(serveur.corps['PUT /citoyens/KM-2026-000001-A/empreintes']!['validation_superviseur'], isTrue);
  });

  test("réseau coupé : la reprise ne recrée PAS la fiche", () async {
    final serveur = FauxServeur()..panneMedias = true;
    final e = await envoi(serveur);
    await expectLater(e.continuer(), throwsA(isA<ErreurApi>()));
    expect(e.etape, EtapeEnvoi.medias);

    serveur.panneMedias = false;
    expect(await e.continuer(), IssueEnvoi.termine);
    expect(serveur.appels.where((a) => a == 'POST /citoyens').length, 1);
  });
}
