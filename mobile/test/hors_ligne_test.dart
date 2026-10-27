// Mode hors ligne : chiffrement, file d'attente sur disque, connexion hors
// ligne, synchronisation (faux serveur, données FICTIVES).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hawiya/api/modeles.dart';
import 'package:hawiya/fiche/envoi.dart';
import 'package:hawiya/hors_ligne/chiffrement.dart';
import 'package:hawiya/hors_ligne/coffre.dart';
import 'package:hawiya/hors_ligne/file_attente.dart';
import 'package:hawiya/hors_ligne/identifiants.dart';
import 'package:hawiya/hors_ligne/synchronisation.dart';

import 'envoi_test.dart' show FauxServeur;
import 'fiche_test.dart' show ficheComplete;

ElementAttente element({String agent = 'AG-0001'}) => ElementAttente.nouveau(
      agent: agent,
      fiche: ficheComplete(),
      doigts: [
        for (final iso in [1, 2]) DoigtEnvoi(iso: iso, image: Uint8List.fromList([iso, 9, 9]), dpiEstime: 540),
      ],
    );

bool contient(List<int> octets, String texte) => utf8.decode(octets, allowMalformed: true).contains(texte);

void main() {
  late Directory dossier;

  setUp(() => dossier = Directory.systemTemp.createTempSync('hawiya_test_'));
  tearDown(() => dossier.deleteSync(recursive: true));

  group('Chiffrement', () {
    test('aller-retour, clé gardée dans le coffre', () async {
      final coffre = CoffreMemoire();
      final chiffre = await (await Chiffreur.depuisCoffre(coffre)).chiffrerJson({'nom': 'MSA'});
      expect(contient(chiffre, 'MSA'), isFalse);
      // Même coffre (redémarrage de l'application) : même clé.
      final relu = await (await Chiffreur.depuisCoffre(coffre)).dechiffrerJson(chiffre);
      expect(relu['nom'], 'MSA');
      expect(coffre.valeurs.keys, [Chiffreur.cleCoffre]);
    });

    test('autre clé ou fichier modifié : refusé', () async {
      final chiffreur = await Chiffreur.depuisCoffre(CoffreMemoire());
      final chiffre = await chiffreur.chiffrer(utf8.encode('données fictives'));
      final autre = await Chiffreur.depuisCoffre(CoffreMemoire());
      expect(() => autre.dechiffrer(chiffre), throwsA(isA<ErreurDechiffrement>()));
      final modifie = Uint8List.fromList(chiffre)..[20] ^= 1;
      expect(() => chiffreur.dechiffrer(modifie), throwsA(isA<ErreurDechiffrement>()));
      expect(() => chiffreur.dechiffrer([1, 2, 3]), throwsA(isA<ErreurDechiffrement>()));
    });

    test('deux chiffrements du même texte diffèrent (nonce aléatoire)', () async {
      final c = await Chiffreur.depuisCoffre(CoffreMemoire());
      expect(await c.chiffrer([1, 2, 3]), isNot(await c.chiffrer([1, 2, 3])));
    });
  });

  group('File d\'attente chiffrée sur disque', () {
    test('enregistrer, relire, supprimer ; rien de lisible dans le fichier', () async {
      final file = FileAttenteChiffree(dossier, await Chiffreur.depuisCoffre(CoffreMemoire()));
      final e = element();
      await file.enregistrer(e);

      final fichiers = dossier.listSync().whereType<File>().toList();
      expect(fichiers, hasLength(1)); // pas de fichier temporaire oublié
      final brut = fichiers.single.readAsBytesSync();
      expect(contient(brut, 'MSA'), isFalse);
      expect(contient(brut, 'Moroni'), isFalse);

      final relus = await file.lister();
      expect(relus.single.nomComplet, 'MSA Ahmed Nassur');
      expect(relus.single.doigts.map((d) => d.image), [
        [1, 9, 9],
        [2, 9, 9],
      ]);
      expect(relus.single.fiche.photo, ficheComplete().photo);

      await file.supprimer(e.id);
      expect(await file.lister(), isEmpty);
      expect(dossier.listSync(), isEmpty);
    });

    test('fichier illisible : ignoré et signalé', () async {
      final file = FileAttenteChiffree(dossier, await Chiffreur.depuisCoffre(CoffreMemoire()));
      await file.enregistrer(element());
      File('${dossier.path}/corrompu.hawiya').writeAsBytesSync([1, 2, 3, 4]);
      final illisibles = <String>[];
      expect(await file.lister(illisibles: illisibles), hasLength(1));
      expect(illisibles.single, endsWith('corrompu.hawiya'));
    });

    test("état d'avancement conservé (JSON)", () {
      final e = element()
        ..statut = StatutAttente.aVerifier
        ..etape = EtapeEnvoi.medias
        ..numero = 'KM-2026-000001-A'
        ..controle = const ControleDoublon(verdict: VerdictDoublon.doublonPossible, motif: 'fictif', numeros: ['KM-2026-000007-B'])
        ..validationSuperviseur = true;
      final relu = ElementAttente.depuisJson(jsonDecode(jsonEncode(e.versJson())) as Map<String, dynamic>);
      expect(relu.statut, StatutAttente.aVerifier);
      expect(relu.etape, EtapeEnvoi.medias);
      expect(relu.numero, 'KM-2026-000001-A');
      expect(relu.controle!.verdict, VerdictDoublon.doublonPossible);
      expect(relu.controle!.numeros, ['KM-2026-000007-B']);
      expect(relu.validationSuperviseur, isTrue);
      expect(relu.fiche.versJson(), ficheComplete().versJson());
    });
  });

  group('Connexion hors ligne', () {
    test('reconnue après une connexion en ligne, sans garder le mot de passe', () async {
      final coffre = CoffreMemoire();
      final ids = IdentifiantsHorsLigne(coffre, iterations: 1000);
      expect(await ids.verifier('AG-0001', 'secret-fictif'), isNull); // jamais connecté
      await ids.memoriser('ag-0001', 'secret-fictif',
          agent: const AgentConnecte(matricule: 'AG-0001', nom: 'Agent fictif', role: 'superviseur'),
          adresse: 'http://192.168.1.10:8000');

      expect(coffre.valeurs.values.join(), isNot(contains('secret-fictif')));
      final agent = await ids.verifier(' AG-0001 ', 'secret-fictif');
      expect(agent!.role, 'superviseur');
      expect(await ids.verifier('AG-0001', 'faux'), isNull);
      expect(await ids.verifier('AG-0002', 'secret-fictif'), isNull);
      expect(await ids.derniereAdresse(), 'http://192.168.1.10:8000');
    });
  });

  group('Synchronisation', () {
    Future<(FauxServeur, Synchroniseur, FileAttente)> preparer({FileAttente? file}) async {
      final serveur = FauxServeur();
      await serveur.client.connexion('AG-0001', 'x');
      final f = file ?? FileAttenteMemoire();
      return (serveur, Synchroniseur(f, serveur.client), f);
    }

    test('envoi réussi : numéro attribué, effacé du téléphone', () async {
      final (serveur, sync, file) = await preparer();
      final e = element();
      await file.enregistrer(e);
      final r = await sync.envoyer(e);
      expect(r.issue, IssueSync.envoye);
      expect(r.element.numero, 'KM-2026-000001-A');
      expect(await file.lister(), isEmpty);
      expect(serveur.appels.first, 'POST /doublons');
    });

    test("coupure après création, redémarrage de l'application : reprise sans recréer la fiche", () async {
      final coffre = CoffreMemoire();
      final file1 = FileAttenteChiffree(dossier, await Chiffreur.depuisCoffre(coffre));
      final (serveur, sync, _) = await preparer(file: file1);
      serveur.panneMedias = true;
      final e = element();
      await file1.enregistrer(e);
      expect((await sync.envoyer(e)).issue, IssueSync.horsLigne);

      // « Redémarrage » : nouvelle file sur le même dossier, même coffre.
      final file2 = FileAttenteChiffree(dossier, await Chiffreur.depuisCoffre(coffre));
      final repris = (await file2.lister()).single;
      expect(repris.etape, EtapeEnvoi.medias);
      expect(repris.numero, 'KM-2026-000001-A');

      serveur.panneMedias = false;
      final bilan = await Synchroniseur(file2, serveur.client).synchroniserTout();
      expect(bilan.envoyes, hasLength(1));
      expect(serveur.appels.where((a) => a == 'POST /citoyens'), hasLength(1));
      expect(await file2.lister(), isEmpty);
    });

    test('non connecté en ligne : rien n\'est envoyé', () async {
      final serveur = FauxServeur(); // pas de connexion
      final file = FileAttenteMemoire();
      final e = element();
      await file.enregistrer(e);
      expect((await Synchroniseur(file, serveur.client).envoyer(e)).issue, IssueSync.reconnexion);
      expect(serveur.appels, isEmpty);
      expect(await file.lister(), hasLength(1));
    });

    test('doublon possible : « à vérifier », puis validation superviseur', () async {
      final (serveur, sync, file) = await preparer();
      serveur.doublon = 'doublon_possible';
      final e = element();
      await file.enregistrer(e);
      expect((await sync.envoyer(e)).issue, IssueSync.aVerifier);
      final enAttente = (await file.lister()).single;
      expect(enAttente.statut, StatutAttente.aVerifier);
      expect(enAttente.controle!.numeros, ['KM-2026-000007-B']);

      // synchroniserTout ne touche pas aux éléments à vérifier.
      expect((await sync.synchroniserTout()).traites, 0);

      final r = await sync.validerEtEnvoyer(enAttente);
      expect(r.issue, IssueSync.envoye);
      expect(serveur.corps['PUT /citoyens/KM-2026-000001-A/empreintes']!['validation_superviseur'], isTrue);
    });

    test('refus du serveur (422) : « en erreur » avec le message', () async {
      final (serveur, sync, file) = await preparer();
      serveur.refusCreation = 422;
      final e = element();
      await file.enregistrer(e);
      final r = await sync.envoyer(e);
      expect(r.issue, IssueSync.erreur);
      final relu = (await file.lister()).single;
      expect(relu.statut, StatutAttente.erreur);
      expect(relu.message, contains('taille_cm'));
    });

    test('réseau absent : arrêt dès le premier élément, les autres restent', () async {
      final (serveur, sync, file) = await preparer();
      for (var i = 0; i < 3; i++) {
        await file.enregistrer(element());
      }
      serveur.horsLigne = true;
      final bilan = await sync.synchroniserTout();
      expect(bilan.arret, IssueSync.horsLigne);
      expect(bilan.traites, 0);
      expect(await file.lister(), hasLength(3));

      serveur.horsLigne = false;
      expect((await sync.synchroniserTout()).envoyes, hasLength(3));
    });
  });
}
