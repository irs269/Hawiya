// Écrans du mode hors ligne (faux serveur, file en mémoire, données FICTIVES).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hawiya/api/client_api.dart';
import 'package:hawiya/api/modeles.dart';
import 'package:hawiya/ecrans/ecran_accueil.dart';
import 'package:hawiya/ecrans/ecran_connexion.dart';
import 'package:hawiya/fiche/ecran_nouvelle_fiche.dart';
import 'package:hawiya/hors_ligne/coffre.dart';
import 'package:hawiya/hors_ligne/ecran_attente.dart';
import 'package:hawiya/hors_ligne/file_attente.dart';
import 'package:hawiya/hors_ligne/identifiants.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'aides.dart';
import 'envoi_test.dart' show FauxServeur;
import 'fiche_test.dart' show ficheComplete;
import 'hors_ligne_test.dart' show element;
import 'nouvelle_fiche_test.dart' show CameraComplete, FaussePhoto, ouvrir, toucher;

void main() {
  testWidgets('sans réseau : enregistrement gardé sur le téléphone', (tester) async {
    final serveur = FauxServeur(); // agent connecté hors ligne : pas de jeton
    final file = FileAttenteMemoire();
    await ouvrir(
      tester,
      EcranNouvelleFiche(
        api: serveur.client,
        services: servicesDeTest(file: file),
        agent: agentFictif,
        source: CameraComplete(),
        sourcePhoto: FaussePhoto(),
        brouillon: ficheComplete(),
      ),
    );
    for (var i = 0; i < 3; i++) {
      await toucher(tester, 'Suivant');
    }
    await toucher(tester, 'Capturer les empreintes');
    await toucher(tester, 'Suivant');
    await toucher(tester, 'Enregistrer');

    expect(find.text('Enregistré sur le téléphone'), findsOneWidget);
    expect(find.textContaining('référence provisoire HL-'), findsOneWidget);
    expect(serveur.appels, isEmpty);
    final enAttente = await file.lister();
    expect(enAttente.single.doigts, hasLength(10));
  });

  testWidgets('connexion hors ligne après une première connexion en ligne', (tester) async {
    final coffre = CoffreMemoire();
    await IdentifiantsHorsLigne(coffre, iterations: 1000).memoriser('AG-0001', 'mot-de-passe-fictif', agent: agentFictif);
    final services = servicesDeTest(coffre: coffre);
    ClientApi sansReseau(String adresse, {required String identifiantAppareil, Future<void> Function(String?)? surRenouvellement}) =>
        ClientApi(adresse, client: MockClient((_) async => throw http.ClientException('pas de réseau')));

    await ouvrir(tester, EcranConnexion(services: services, fabriqueClient: sansReseau));
    await tester.pumpAndSettle(); // fin de la tentative de reprise de session
    await tester.enterText(find.widgetWithText(TextField, 'Matricule agent'), 'AG-0001');
    await tester.enterText(find.widgetWithText(TextField, 'Mot de passe'), 'faux');
    await toucher(tester, 'Se connecter');
    expect(find.textContaining('mot de passe incorrect'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextField, 'Mot de passe'), 'mot-de-passe-fictif');
    await toucher(tester, 'Se connecter');
    expect(find.text('Mode hors ligne'), findsOneWidget);
    expect(find.text('En ligne seulement.'), findsWidgets); // identification désactivée
  });

  testWidgets("accueil : synchronisation au retour du réseau", (tester) async {
    final serveur = FauxServeur();
    await serveur.client.connexion('AG-0001', 'x');
    final file = FileAttenteMemoire();
    await file.enregistrer(element());
    final reseau = StreamController<bool>();
    addTearDown(reseau.close);
    serveur.horsLigne = true;

    await ouvrir(tester, EcranAccueil(api: serveur.client, services: servicesDeTest(file: file, reseau: reseau.stream), agent: agentFictif));
    await tester.pumpAndSettle();
    expect(find.text("En attente d'envoi (1)"), findsOneWidget);

    serveur.horsLigne = false;
    reseau.add(true);
    await tester.pumpAndSettle();
    expect(find.textContaining('1 enregistrement(s) envoyé(s)'), findsOneWidget);
    expect(find.text("En attente d'envoi"), findsOneWidget);
    expect(await file.lister(), isEmpty);
  });

  testWidgets('« En attente » : un superviseur valide un doublon possible', (tester) async {
    final serveur = FauxServeur(doublon: 'doublon_possible');
    await serveur.client.connexion('AG-0002', 'x');
    final file = FileAttenteMemoire();
    final e = element()
      ..statut = StatutAttente.aVerifier
      ..controle = const ControleDoublon(
        verdict: VerdictDoublon.doublonPossible,
        motif: '1 fiche(s) ressemblante(s)',
        numeros: ['KM-2026-000007-B'],
      )
      ..message = '1 fiche(s) ressemblante(s)';
    await file.enregistrer(e);

    await ouvrir(tester, EcranAttente(api: serveur.client, services: servicesDeTest(file: file), agent: superviseurFictif));
    await tester.pumpAndSettle();
    expect(find.text('À vérifier'), findsOneWidget);
    expect(find.text('MSA Ahmed Nassur'), findsOneWidget);

    serveur.doublon = 'doublon_possible';
    await toucher(tester, 'Valider (superviseur)');
    expect(find.textContaining('Envoyé : numéro KM-2026-000001-A'), findsOneWidget);
    expect(find.text('Aucun enregistrement en attente.'), findsOneWidget);
  });

  testWidgets('« En attente » : un simple agent ne voit pas la validation', (tester) async {
    final serveur = FauxServeur();
    await serveur.client.connexion('AG-0001', 'x');
    final file = FileAttenteMemoire();
    await file.enregistrer(element()..statut = StatutAttente.aVerifier);
    await ouvrir(tester, EcranAttente(api: serveur.client, services: servicesDeTest(file: file), agent: agentFictif));
    await tester.pumpAndSettle();
    expect(find.text('Valider (superviseur)'), findsNothing);

    await toucher(tester, 'Supprimer');
    await tester.tap(find.text('Supprimer').last); // confirmation
    await tester.pumpAndSettle();
    expect(await file.lister(), isEmpty);
  });
}
