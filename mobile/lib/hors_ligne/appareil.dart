import 'dart:convert';
import 'dart:math';

import 'coffre.dart';

/// Identité de ce téléphone auprès du serveur : un identifiant aléatoire créé
/// au premier lancement et gardé dans le coffre. Un superviseur doit approuver
/// le téléphone (code court = 8 premiers caractères) avant toute connexion.
class IdentiteAppareil {
  IdentiteAppareil(this._coffre);

  static const cleCoffre = 'hawiya.appareil';
  static const cleSession = 'hawiya.session';
  final Coffre _coffre;

  Future<String> identifiant() async {
    final existant = await _coffre.lire(cleCoffre);
    if (existant != null) return existant;
    final aleatoire = Random.secure();
    final nouveau = List.generate(16, (_) => aleatoire.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    await _coffre.ecrire(cleCoffre, nouveau);
    return nouveau;
  }

  static String code(String identifiant) => identifiant.substring(0, 8).toUpperCase();

  /// Appareil révoqué : on repart avec un nouvel identifiant (à faire approuver)
  /// et on oublie la session.
  Future<void> reinitialiser() async {
    await _coffre.supprimer(cleCoffre);
    await _coffre.supprimer(cleSession);
  }

  // Session en cours (jeton de renouvellement), pour reprendre sans mot de
  // passe après un redémarrage de l'application.

  Future<void> memoriserSession({required String adresse, required String? jeton}) async {
    if (jeton == null) {
      await _coffre.supprimer(cleSession);
    } else {
      await _coffre.ecrire(cleSession, jsonEncode({'adresse': adresse, 'jeton': jeton}));
    }
  }

  Future<({String adresse, String jeton})?> sessionMemorisee() async {
    final brut = await _coffre.lire(cleSession);
    if (brut == null) return null;
    final j = jsonDecode(brut) as Map<String, dynamic>;
    return (adresse: j['adresse'] as String, jeton: j['jeton'] as String);
  }
}
