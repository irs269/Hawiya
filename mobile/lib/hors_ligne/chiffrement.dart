import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'coffre.dart';

/// Le fichier a été modifié, ou la clé n'est pas la bonne.
class ErreurDechiffrement implements Exception {
  const ErreurDechiffrement(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Chiffrement AES-256-GCM des enregistrements en attente.
///
/// La clé (256 bits, aléatoire) est créée au premier usage et gardée dans le
/// coffre sécurisé : sans elle, les fichiers sont illisibles. GCM vérifie aussi
/// l'intégrité : un fichier modifié est refusé.
///
/// Format d'un fichier : version (1 octet) + nonce (12) + chiffré + code MAC (16).
class Chiffreur {
  Chiffreur._(this._cle);

  static const cleCoffre = 'hawiya.cle_file_attente';
  static const _version = 1;
  static final _algo = AesGcm.with256bits();

  final SecretKey _cle;

  /// Lit la clé dans le coffre, ou la crée si elle n'existe pas encore.
  static Future<Chiffreur> depuisCoffre(Coffre coffre) async {
    final existante = await coffre.lire(cleCoffre);
    if (existante != null) return Chiffreur._(SecretKey(base64Decode(existante)));
    final cle = await _algo.newSecretKey();
    await coffre.ecrire(cleCoffre, base64Encode(await cle.extractBytes()));
    return Chiffreur._(cle);
  }

  Future<Uint8List> chiffrer(List<int> clair) async {
    final boite = await _algo.encrypt(clair, secretKey: _cle);
    return Uint8List.fromList([_version, ...boite.nonce, ...boite.cipherText, ...boite.mac.bytes]);
  }

  Future<Uint8List> dechiffrer(List<int> donnees) async {
    if (donnees.length < 1 + 12 + 16 || donnees.first != _version) {
      throw const ErreurDechiffrement('Fichier illisible (format inconnu)');
    }
    final boite = SecretBox(
      donnees.sublist(13, donnees.length - 16),
      nonce: donnees.sublist(1, 13),
      mac: Mac(donnees.sublist(donnees.length - 16)),
    );
    try {
      return Uint8List.fromList(await _algo.decrypt(boite, secretKey: _cle));
    } on SecretBoxAuthenticationError {
      throw const ErreurDechiffrement('Fichier modifié ou clé incorrecte');
    }
  }

  Future<Uint8List> chiffrerJson(Object json) => chiffrer(utf8.encode(jsonEncode(json)));

  Future<Map<String, dynamic>> dechiffrerJson(List<int> donnees) async =>
      jsonDecode(utf8.decode(await dechiffrer(donnees))) as Map<String, dynamic>;
}
