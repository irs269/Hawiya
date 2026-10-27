import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Petits secrets (clé de chiffrement, empreinte du mot de passe) gardés dans
/// le coffre sécurisé d'Android (Keystore). Remplaçable dans les tests.
abstract class Coffre {
  Future<String?> lire(String cle);
  Future<void> ecrire(String cle, String valeur);
  Future<void> supprimer(String cle);
}

class CoffreSecurise implements Coffre {
  const CoffreSecurise();

  static const _stockage = FlutterSecureStorage();

  @override
  Future<String?> lire(String cle) => _stockage.read(key: cle);

  @override
  Future<void> ecrire(String cle, String valeur) => _stockage.write(key: cle, value: valeur);

  @override
  Future<void> supprimer(String cle) => _stockage.delete(key: cle);
}

/// Coffre en mémoire, pour les tests uniquement.
class CoffreMemoire implements Coffre {
  final valeurs = <String, String>{};

  @override
  Future<String?> lire(String cle) async => valeurs[cle];

  @override
  Future<void> ecrire(String cle, String valeur) async => valeurs[cle] = valeur;

  @override
  Future<void> supprimer(String cle) async => valeurs.remove(cle);
}
