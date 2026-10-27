// Client de l'API avec un FAUX serveur (données fictives uniquement).
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hawiya/api/client_api.dart';
import 'package:hawiya/api/modeles.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const ficheFictive = {
  'id': '00000000-0000-0000-0000-000000000001',
  'numero': 'KM-2026-000001-A',
  'nom': 'MSA',
  'prenoms': 'Ahmed Nassur',
  'sexe': 'M',
  'date_naissance': '1990-05-14',
  'lieu_naissance': 'Moroni',
  'nationalite': 'Comorienne',
  'numero_acte_naissance': 'FICTIF-1990-0001',
  'telephone': '+2693210000',
  'ile': 'Ngazidja',
  'ville': 'Moroni',
  'quartier': 'Magoudjou',
  'adresse': 'Rue fictive n° 1',
  'taille_cm': 172,
  'couleur_yeux': 'marron',
  'couleur_cheveux': 'noirs',
  'agent_id': '00000000-0000-0000-0000-000000000002',
  'enregistre_le': '2026-10-01T10:00:00Z',
};

http.Response json(Object corps, [int code = 200]) =>
    http.Response.bytes(utf8.encode(jsonEncode(corps)), code, headers: {'content-type': 'application/json'});

List<DoigtEnvoi> doigts() => [
      for (final iso in [2, 3, 4, 5]) DoigtEnvoi(iso: iso, image: Uint8List.fromList([iso, 1, 2]), dpiEstime: 550),
    ];

Future<ClientApi> clientConnecte(Future<http.Response> Function(http.Request) routes) async {
  final api = ClientApi('192.168.1.10:8000/', client: MockClient((r) async {
    if (r.url.path == '/auth/connexion') return json({'access_token': 'jeton-fictif', 'token_type': 'bearer'});
    return routes(r);
  }));
  await api.connexion('AG-0001', 'mot-de-passe-fictif');
  return api;
}

void main() {
  test("normalisation de l'adresse du serveur", () {
    expect(ClientApi.normaliserAdresse(' 192.168.1.10:8000/ '), 'http://192.168.1.10:8000');
    expect(ClientApi.normaliserAdresse('https://hawiya.exemple//'), 'https://hawiya.exemple');
  });

  test('connexion : formulaire envoyé, jeton mémorisé', () async {
    late http.Request requete;
    final api = ClientApi('http://serveur', client: MockClient((r) async {
      requete = r;
      return json({'access_token': 'jeton-fictif'});
    }));
    await api.connexion(' AG-0001 ', 'secret-fictif');
    expect(api.connecte, isTrue);
    expect(requete.bodyFields, {'username': 'AG-0001', 'password': 'secret-fictif'});
  });

  test('connexion refusée : message clair', () async {
    final api = ClientApi('http://serveur', client: MockClient((_) async => json({'detail': 'x'}, 401)));
    expect(
      () => api.connexion('AG-0001', 'faux'),
      throwsA(isA<ErreurApi>().having((e) => e.message, 'message', contains('incorrect'))),
    );
  });

  test('serveur injoignable', () async {
    final api = ClientApi('http://serveur', client: MockClient((_) async => throw http.ClientException('réseau')));
    expect(() => api.connexion('a', 'b'), throwsA(isA<ErreurApi>()));
  });

  test("identification : envoi des scans en base64 avec le jeton", () async {
    late http.Request requete;
    final api = await clientConnecte((r) async {
      requete = r;
      return json({
        'verdict': 'identifie',
        'motif': '4 doigts sur 4 concordent',
        'doigts_compares': 4,
        'doigts_concordants': 4,
        'doigts_illisibles': [],
        'citoyen': ficheFictive,
      });
    });
    final r = await api.identifier([doigts(), doigts()]);

    expect(requete.headers['Authorization'], 'Bearer jeton-fictif');
    final corps = jsonDecode(requete.body) as Map<String, dynamic>;
    expect((corps['scans'] as List).length, 2);
    final premier = ((corps['scans'] as List).first as Map)['doigts'] as List;
    expect(premier.first, {'doigt': 2, 'image': base64Encode([2, 1, 2]), 'dpi_estime': 550.0});

    expect(r.verdict, VerdictIdentification.identifie);
    expect(r.citoyen!.numero, 'KM-2026-000001-A');
    expect(r.citoyen!.dateNaissance, DateTime(1990, 5, 14));
  });

  test("sécurité : aucune fiche gardée si le verdict n'est pas « identifié »", () async {
    final api = await clientConnecte((_) async => json({
          'verdict': 'non_concluant',
          'motif': 'deuxième candidat trop proche',
          'doigts_compares': 4,
          'doigts_concordants': 2,
          'citoyen': ficheFictive, // ne devrait jamais arriver, mais on s'en protège
        }));
    final r = await api.identifier([doigts()]);
    expect(r.verdict, VerdictIdentification.nonConcluant);
    expect(r.citoyen, isNull);
  });

  test('verdict inconnu refusé', () {
    expect(() => ReponseIdentification.depuisJson({'verdict': 'peut_etre'}), throwsFormatException);
  });

  test('enregistrement accepté', () async {
    late http.Request requete;
    final api = await clientConnecte((r) async {
      requete = r;
      return json({
        'numero': 'KM-2026-000001-A',
        'doigts_enregistres': [2, 3, 4, 5],
        'doigts_illisibles': [],
        'controle_doublon': {'verdict': 'aucun_doublon', 'motif': 'Aucune fiche ressemblante.', 'numeros': []},
      });
    });
    final r = await api.enregistrerEmpreintes('KM-2026-000001-A', doigts());
    expect(requete.method, 'PUT');
    expect(requete.url.path, '/citoyens/KM-2026-000001-A/empreintes');
    expect(jsonDecode(requete.body)['validation_superviseur'], isFalse);
    expect(r.enregistre, isTrue);
    expect(r.doigtsEnregistres, [2, 3, 4, 5]);
  });

  test("doublon (409) : renvoyé comme résultat, pas comme erreur", () async {
    final api = await clientConnecte((_) async => json({
          'detail': {
            'verdict': 'doublon_possible',
            'motif': '1 fiche(s) ressemblante(s)',
            'numeros': ['KM-2026-000007-B'],
          },
        }, 409));
    final r = await api.enregistrerEmpreintes('KM-2026-000001-A', doigts());
    expect(r.enregistre, isFalse);
    expect(r.controle.verdict, VerdictDoublon.doublonPossible);
    expect(r.controle.numeros, ['KM-2026-000007-B']);
  });

  test('erreur du serveur : message « detail » transmis', () async {
    final api = await clientConnecte(
        (_) async => json({'detail': 'Seul un superviseur peut valider un doublon possible'}, 403));
    expect(
      () => api.enregistrerEmpreintes('KM-2026-000001-A', doigts(), validationSuperviseur: true),
      throwsA(isA<ErreurApi>().having((e) => e.code, 'code', 403).having((e) => e.message, 'm', contains('superviseur'))),
    );
  });

  test('fiche introuvable', () async {
    final api = await clientConnecte((_) async => json({'detail': 'Fiche introuvable'}, 404));
    expect(() => api.lireCitoyen('KM-2026-999999-Z'), throwsA(isA<ErreurApi>()));
  });

  test('session expirée : le jeton est oublié', () async {
    final api = await clientConnecte((_) async => json({'detail': 'Session invalide ou expirée'}, 401));
    await expectLater(api.identifier([doigts()]), throwsA(isA<ErreurApi>()));
    expect(api.connecte, isFalse);
  });
}
