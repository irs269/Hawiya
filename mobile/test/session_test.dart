// Phase 1 bis côté téléphone : jetons renouvelables, appareil approuvé,
// mot de passe provisoire, reprise de session (faux serveur, données FICTIVES).
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hawiya/api/client_api.dart';
import 'package:hawiya/ecrans/ecran_connexion.dart';
import 'package:hawiya/ecrans/ecran_mot_de_passe.dart';
import 'package:hawiya/hors_ligne/appareil.dart';
import 'package:hawiya/hors_ligne/coffre.dart';
import 'package:hawiya/hors_ligne/identifiants.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'aides.dart';
import 'api_test.dart' show json;
import 'nouvelle_fiche_test.dart' show ouvrir, toucher;

/// Faux serveur d'authentification : jetons numérotés, appels notés.
class FauxAuth {
  FauxAuth({this.provisoire = false, this.appareil = 'approuve'});

  bool provisoire;
  String appareil; // approuve, en_attente, revoque
  bool horsLigne = false;
  int numero = 0;
  final appels = <String>[];
  late String jetonValide;
  String? renouvellementValide;
  String? motDePasseChange;

  Map<String, Object?> _jetons() {
    numero++;
    jetonValide = 'acces-$numero';
    renouvellementValide = 'renouvellement-$numero';
    return {
      'access_token': jetonValide,
      'refresh_token': renouvellementValide,
      'expires_in': 900,
      'doit_changer_mot_de_passe': provisoire,
    };
  }

  /// Simule l'expiration du jeton d'accès.
  void expirerAcces() => jetonValide = 'expire';

  late final client = MockClient((r) async {
    if (horsLigne) throw http.ClientException('pas de réseau');
    appels.add('${r.method} ${r.url.path}');
    switch (r.url.path) {
      case '/auth/connexion':
        if (r.bodyFields['password'] != 'mot-de-passe-fictif' && r.bodyFields['password'] != motDePasseChange) {
          return json({'detail': 'Matricule ou mot de passe incorrect.'}, 401);
        }
        if (appareil != 'approuve') {
          return json({
            'detail': {
              'code': 'appareil_$appareil',
              'message': appareil == 'revoque'
                  ? 'Cet appareil a été révoqué : il ne peut plus se connecter.'
                  : "Appareil en attente d'approbation.",
              'code_appareil': r.bodyFields['client_id']!.substring(0, 8).toUpperCase(),
            },
          }, 403);
        }
        return json(_jetons());
      case '/auth/renouveler':
        final jeton = (jsonDecode(r.body) as Map)['refresh_token'];
        if (jeton != renouvellementValide) {
          return json({'detail': {'code': 'jeton_reutilise', 'message': 'Session expirée'}}, 401);
        }
        return json(_jetons());
      case '/auth/mot-de-passe':
        motDePasseChange = (jsonDecode(r.body) as Map)['nouveau'] as String;
        provisoire = false;
        return http.Response('', 204);
      case '/auth/deconnexion':
        return http.Response('', 204);
    }
    if (r.headers['Authorization'] != 'Bearer $jetonValide') {
      return json({'detail': 'Session invalide ou expirée'}, 401);
    }
    if (r.url.path == '/auth/moi') {
      return json({'matricule': 'AG-0001', 'nom': 'Agent fictif', 'role': 'agent', 'doit_changer_mot_de_passe': provisoire});
    }
    return json({'detail': 'route inconnue'}, 404);
  });

  ClientApi fabrique(String adresse, {required String identifiantAppareil, Future<void> Function(String?)? surRenouvellement}) =>
      ClientApi(adresse, client: client, identifiantAppareil: identifiantAppareil, surRenouvellement: surRenouvellement);
}

void main() {
  group('Client : jetons', () {
    test("jeton d'accès expiré : renouvellement automatique puis requête rejouée", () async {
      final serveur = FauxAuth();
      final memorises = <String?>[];
      final api = ClientApi('http://serveur', client: serveur.client, identifiantAppareil: 'a1b2c3d4e5f6a7b8',
          surRenouvellement: (j) async => memorises.add(j));
      await api.connexion('AG-0001', 'mot-de-passe-fictif');
      serveur.expirerAcces();

      final agent = await api.moi();
      expect(agent.matricule, 'AG-0001');
      expect(serveur.appels, ['POST /auth/connexion', 'GET /auth/moi', 'POST /auth/renouveler', 'GET /auth/moi']);
      expect(memorises, ['renouvellement-1', 'renouvellement-2']); // le coffre suit la rotation
    });

    test('deux requêtes expirées en même temps : UN seul renouvellement', () async {
      final serveur = FauxAuth();
      final api = ClientApi('http://serveur', client: serveur.client);
      await api.connexion('AG-0001', 'mot-de-passe-fictif');
      serveur.expirerAcces();
      await Future.wait([api.moi(), api.moi()]);
      expect(serveur.appels.where((a) => a == 'POST /auth/renouveler'), hasLength(1));
    });

    test('renouvellement refusé : session oubliée', () async {
      final serveur = FauxAuth();
      String? dernier = 'pas encore appelé';
      final api = ClientApi('http://serveur', client: serveur.client, surRenouvellement: (j) async => dernier = j);
      await api.connexion('AG-0001', 'mot-de-passe-fictif');
      serveur
        ..expirerAcces()
        ..renouvellementValide = 'autre';
      await expectLater(api.moi(), throwsA(isA<ErreurApi>().having((e) => e.code, 'code', 401)));
      expect(api.connecte, isFalse);
      expect(dernier, isNull);
      expect(api.derniereRaisonRefus, 'jeton_reutilise');
    });

    test('reprise avec le jeton du coffre ; hors ligne : échec sans tout effacer', () async {
      final serveur = FauxAuth();
      serveur.renouvellementValide = 'renouvellement-garde';
      final api = ClientApi('http://serveur', client: serveur.client);
      expect(await api.reprendre('renouvellement-garde'), isTrue);
      expect((await api.moi()).nom, 'Agent fictif');

      serveur.horsLigne = true;
      expect(await ClientApi('http://serveur', client: serveur.client).reprendre('renouvellement-2'), isFalse);
    });

    test('déconnexion : révoquée sur le serveur et oubliée ici', () async {
      final serveur = FauxAuth();
      String? dernier = 'x';
      final api = ClientApi('http://serveur', client: serveur.client, surRenouvellement: (j) async => dernier = j);
      await api.connexion('AG-0001', 'mot-de-passe-fictif');
      await api.deconnexion();
      expect(serveur.appels.last, 'POST /auth/deconnexion');
      expect(api.connecte, isFalse);
      expect(dernier, isNull);
    });

    test('appareil en attente : raison et code transmis', () async {
      final serveur = FauxAuth(appareil: 'en_attente');
      final api = ClientApi('http://serveur', client: serveur.client, identifiantAppareil: 'beefcafe00112233');
      await expectLater(
        api.connexion('AG-0001', 'mot-de-passe-fictif'),
        throwsA(isA<ErreurApi>()
            .having((e) => e.raison, 'raison', 'appareil_en_attente')
            .having((e) => e.codeAppareil, 'code', 'BEEFCAFE')),
      );
    });
  });

  group('Appareil', () {
    test('identifiant stable, code court, nouvel identifiant après révocation', () async {
      final appareil = IdentiteAppareil(CoffreMemoire());
      final id = await appareil.identifiant();
      expect(id, hasLength(32));
      expect(await appareil.identifiant(), id);
      expect(IdentiteAppareil.code(id), id.substring(0, 8).toUpperCase());
      await appareil.memoriserSession(adresse: 'http://serveur', jeton: 'renouvellement-fictif');
      expect((await appareil.sessionMemorisee())!.jeton, 'renouvellement-fictif');
      await appareil.reinitialiser();
      expect(await appareil.identifiant(), isNot(id));
      expect(await appareil.sessionMemorisee(), isNull);
    });
  });

  test('règles du mot de passe (comme le serveur)', () {
    expect(problemeMotDePasse('court', 'AG-0001'), contains('10'));
    expect(problemeMotDePasse('xx-ag-0001-xx', 'AG-0001'), contains('matricule'));
    expect(problemeMotDePasse('aaaaaaaaaaaa', 'AG-0001'), 'Trop simple');
    expect(problemeMotDePasse('Nouveau-secret-2026', 'AG-0001', ancien: 'Nouveau-secret-2026'), contains('différent'));
    expect(problemeMotDePasse('Nouveau-secret-2026', 'AG-0001'), isNull);
  });

  group('Écran de connexion', () {
    Future<void> saisir(WidgetTester tester, String motDePasse) async {
      await tester.enterText(find.widgetWithText(TextField, 'Matricule agent'), 'AG-0001');
      await tester.enterText(find.widgetWithText(TextField, 'Mot de passe'), motDePasse);
      await toucher(tester, 'Se connecter');
    }

    testWidgets('téléphone en attente : le code à donner au superviseur est affiché', (tester) async {
      final serveur = FauxAuth(appareil: 'en_attente');
      final services = servicesDeTest();
      await ouvrir(tester, EcranConnexion(services: services, fabriqueClient: serveur.fabrique));
      await tester.pumpAndSettle();
      await saisir(tester, 'mot-de-passe-fictif');
      final code = IdentiteAppareil.code(await services.appareil.identifiant());
      expect(find.text('Téléphone à faire approuver'), findsOneWidget);
      expect(find.textContaining(code), findsWidgets);
    });

    testWidgets('mot de passe provisoire : changement obligatoire, puis accueil', (tester) async {
      final serveur = FauxAuth(provisoire: true);
      final coffre = CoffreMemoire();
      await ouvrir(tester, EcranConnexion(services: servicesDeTest(coffre: coffre), fabriqueClient: serveur.fabrique));
      await tester.pumpAndSettle();
      await saisir(tester, 'mot-de-passe-fictif');

      expect(find.text('Nouveau mot de passe'), findsWidgets);
      await tester.enterText(find.widgetWithText(TextField, 'Nouveau mot de passe'), 'court');
      await toucher(tester, 'Enregistrer le mot de passe');
      expect(find.text('Au moins 10 caractères'), findsOneWidget);

      await tester.enterText(find.widgetWithText(TextField, 'Nouveau mot de passe'), 'Nouveau-secret-2026');
      await tester.enterText(find.widgetWithText(TextField, 'Confirmer le nouveau mot de passe'), 'Nouveau-secret-2026');
      await toucher(tester, 'Enregistrer le mot de passe');

      expect(serveur.motDePasseChange, 'Nouveau-secret-2026');
      expect(find.text('Enregistrer une personne'), findsOneWidget); // accueil
      // La connexion hors ligne suit le NOUVEAU mot de passe.
      final ids = IdentifiantsHorsLigne(coffre, iterations: 1000);
      expect((await ids.verifier('AG-0001', 'Nouveau-secret-2026')).agent, isNotNull);
      expect((await ids.verifier('AG-0001', 'mot-de-passe-fictif')).agent, isNull);
    });

    testWidgets('au démarrage, la session précédente reprend sans mot de passe', (tester) async {
      final serveur = FauxAuth()..renouvellementValide = 'renouvellement-garde';
      final services = servicesDeTest();
      await services.appareil.memoriserSession(adresse: 'http://serveur', jeton: 'renouvellement-garde');
      await ouvrir(tester, EcranConnexion(services: services, fabriqueClient: serveur.fabrique));
      await tester.pumpAndSettle();
      expect(find.text('Enregistrer une personne'), findsOneWidget);
      expect((await services.appareil.sessionMemorisee())!.jeton, 'renouvellement-1'); // rotation gardée
    });

    testWidgets('appareil révoqué : identifiants hors ligne effacés, nouvel identifiant', (tester) async {
      final serveur = FauxAuth(appareil: 'revoque');
      final coffre = CoffreMemoire();
      final services = servicesDeTest(coffre: coffre);
      await services.identifiants.memoriser('AG-0001', 'mot-de-passe-fictif');
      final ancien = await services.appareil.identifiant();
      await ouvrir(tester, EcranConnexion(services: services, fabriqueClient: serveur.fabrique));
      await tester.pumpAndSettle();
      await saisir(tester, 'mot-de-passe-fictif');

      expect(find.textContaining('révoqué'), findsOneWidget);
      expect((await services.identifiants.verifier('AG-0001', 'mot-de-passe-fictif')).refus, RefusHorsLigne.inconnu);
      expect(await services.appareil.identifiant(), isNot(ancien));
    });
  });
}
