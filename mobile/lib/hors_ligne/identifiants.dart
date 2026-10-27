import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

import '../api/modeles.dart';
import 'coffre.dart';

/// Connexion hors ligne : après une connexion EN LIGNE réussie, on garde dans
/// le coffre une empreinte du mot de passe (PBKDF2-HMAC-SHA256, sel aléatoire),
/// jamais le mot de passe lui-même. L'agent peut alors se reconnecter sans
/// réseau pour ENREGISTRER ; la synchronisation exige une connexion en ligne.
/// (Système provisoire : l'authentification complète est la phase 1 bis.)
class IdentifiantsHorsLigne {
  IdentifiantsHorsLigne(this._coffre, {this.iterations = 100000});

  static const cleCoffre = 'hawiya.identifiants_hors_ligne';
  final Coffre _coffre;

  /// Coût du calcul (réduit dans les tests seulement).
  final int iterations;

  Future<List<int>> _deriver(String motDePasse, List<int> sel, int iterations) async {
    final pbkdf2 = Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: iterations, bits: 256);
    final cle = await pbkdf2.deriveKeyFromPassword(password: motDePasse, nonce: sel);
    return cle.extractBytes();
  }

  /// À appeler après une connexion en ligne réussie.
  Future<void> memoriser(String matricule, String motDePasse, {AgentConnecte? agent, String? adresse}) async {
    final aleatoire = Random.secure();
    final sel = List<int>.generate(16, (_) => aleatoire.nextInt(256));
    await _coffre.ecrire(
      cleCoffre,
      jsonEncode({
        'matricule': matricule.trim().toUpperCase(),
        'sel': base64Encode(sel),
        'iterations': iterations,
        'empreinte': base64Encode(await _deriver(motDePasse, sel, iterations)),
        'nom': agent?.nom,
        'role': agent?.role,
        'adresse': adresse,
      }),
    );
  }

  /// Agent reconnu hors ligne (null si matricule ou mot de passe incorrect,
  /// ou si aucun agent n'a jamais été connecté en ligne sur ce téléphone).
  Future<AgentConnecte?> verifier(String matricule, String motDePasse) async {
    final brut = await _coffre.lire(cleCoffre);
    if (brut == null) return null;
    final j = jsonDecode(brut) as Map<String, dynamic>;
    if (j['matricule'] != matricule.trim().toUpperCase()) return null;
    final attendu = base64Decode(j['empreinte'] as String);
    final calcule = await _deriver(motDePasse, base64Decode(j['sel'] as String), (j['iterations'] as num).toInt());
    if (!_egal(attendu, calcule)) return null;
    return AgentConnecte(
      matricule: j['matricule'] as String,
      nom: j['nom'] as String? ?? j['matricule'] as String,
      role: j['role'] as String? ?? 'agent',
    );
  }

  /// Dernière adresse de serveur utilisée (pré-remplie à l'écran de connexion).
  Future<String?> derniereAdresse() async {
    final brut = await _coffre.lire(cleCoffre);
    return brut == null ? null : (jsonDecode(brut) as Map<String, dynamic>)['adresse'] as String?;
  }

  Future<void> oublier() => _coffre.supprimer(cleCoffre);

  /// Comparaison en temps constant.
  static bool _egal(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var difference = 0;
    for (var i = 0; i < a.length; i++) {
      difference |= a[i] ^ b[i];
    }
    return difference == 0;
  }
}
