import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

import '../api/modeles.dart';
import 'coffre.dart';

/// Pourquoi une connexion hors ligne est refusée.
enum RefusHorsLigne {
  /// Agent jamais connecté en ligne sur ce téléphone (ou identifiants effacés).
  inconnu,
  motDePasseIncorrect,

  /// Trop d'essais ratés : attendre la fin du blocage.
  bloque,

  /// Dernière connexion en ligne trop ancienne : se connecter en ligne.
  expire,
}

class ResultatHorsLigne {
  const ResultatHorsLigne.accepte(AgentConnecte this.agent) : refus = null;
  const ResultatHorsLigne.refuse(RefusHorsLigne this.refus) : agent = null;

  final AgentConnecte? agent;
  final RefusHorsLigne? refus;

  String get message => switch (refus) {
        null => '',
        RefusHorsLigne.inconnu => "Serveur injoignable. La connexion hors ligne n'est possible qu'après une "
            'première connexion en ligne sur ce téléphone.',
        RefusHorsLigne.motDePasseIncorrect => 'Serveur injoignable et mot de passe incorrect.',
        RefusHorsLigne.bloque => 'Trop d\'essais ratés : connexion hors ligne bloquée '
            '${IdentifiantsHorsLigne.blocage.inMinutes} minutes.',
        RefusHorsLigne.expire => 'Dernière connexion en ligne il y a plus de '
            '${IdentifiantsHorsLigne.validite.inDays} jours : connectez-vous en ligne.',
      };
}

/// Connexion hors ligne : après une connexion EN LIGNE réussie, on garde dans
/// le coffre une empreinte du mot de passe (PBKDF2-HMAC-SHA256, sel aléatoire),
/// jamais le mot de passe lui-même. Plusieurs agents peuvent partager le
/// téléphone. Hors ligne : blocage après 5 essais ratés, et validité limitée à
/// 7 jours depuis la dernière connexion en ligne.
class IdentifiantsHorsLigne {
  IdentifiantsHorsLigne(this._coffre, {this.iterations = 100000, DateTime Function()? horloge})
      : _horloge = horloge ?? DateTime.now;

  static const cleCoffre = 'hawiya.identifiants_hors_ligne';
  static const echecsMax = 5;
  static const blocage = Duration(minutes: 15);
  static const validite = Duration(days: 7);

  final Coffre _coffre;
  final DateTime Function() _horloge;

  /// Coût du calcul (réduit dans les tests seulement).
  final int iterations;

  Future<Map<String, dynamic>> _tout() async {
    final brut = await _coffre.lire(cleCoffre);
    if (brut == null) return {'agents': <String, dynamic>{}};
    final j = jsonDecode(brut) as Map<String, dynamic>;
    // Ancien format (un seul agent) : simplement oublié, une connexion en ligne le recrée.
    return j.containsKey('agents') ? j : {'agents': <String, dynamic>{}};
  }

  Future<void> _ecrire(Map<String, dynamic> tout) => _coffre.ecrire(cleCoffre, jsonEncode(tout));

  Future<List<int>> _deriver(String motDePasse, List<int> sel, int iterations) async {
    final pbkdf2 = Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: iterations, bits: 256);
    final cle = await pbkdf2.deriveKeyFromPassword(password: motDePasse, nonce: sel);
    return cle.extractBytes();
  }

  static String _cle(String matricule) => matricule.trim().toUpperCase();

  /// À appeler après une connexion en ligne réussie (mot de passe définitif).
  Future<void> memoriser(String matricule, String motDePasse, {AgentConnecte? agent, String? adresse}) async {
    final aleatoire = Random.secure();
    final sel = List<int>.generate(16, (_) => aleatoire.nextInt(256));
    final tout = await _tout();
    (tout['agents'] as Map<String, dynamic>)[_cle(matricule)] = {
      'sel': base64Encode(sel),
      'iterations': iterations,
      'empreinte': base64Encode(await _deriver(motDePasse, sel, iterations)),
      'nom': agent?.nom,
      'role': agent?.role,
      'en_ligne_le': _horloge().toIso8601String(),
      'echecs': 0,
      'bloque_jusqu_a': null,
    };
    tout['adresse'] = adresse ?? tout['adresse'];
    await _ecrire(tout);
  }

  /// Vérifie le mot de passe hors ligne (compte les échecs, applique le blocage).
  Future<ResultatHorsLigne> verifier(String matricule, String motDePasse) async {
    final tout = await _tout();
    final agents = tout['agents'] as Map<String, dynamic>;
    final j = agents[_cle(matricule)] as Map<String, dynamic>?;
    if (j == null) return const ResultatHorsLigne.refuse(RefusHorsLigne.inconnu);
    final maintenant = _horloge();

    final bloqueJusqua = j['bloque_jusqu_a'] == null ? null : DateTime.parse(j['bloque_jusqu_a'] as String);
    if (bloqueJusqua != null && bloqueJusqua.isAfter(maintenant)) {
      return const ResultatHorsLigne.refuse(RefusHorsLigne.bloque);
    }
    final attendu = base64Decode(j['empreinte'] as String);
    final calcule = await _deriver(motDePasse, base64Decode(j['sel'] as String), (j['iterations'] as num).toInt());
    if (!_egal(attendu, calcule)) {
      final echecs = (j['echecs'] as num? ?? 0).toInt() + 1;
      j['echecs'] = echecs >= echecsMax ? 0 : echecs;
      if (echecs >= echecsMax) j['bloque_jusqu_a'] = maintenant.add(blocage).toIso8601String();
      await _ecrire(tout);
      return ResultatHorsLigne.refuse(echecs >= echecsMax ? RefusHorsLigne.bloque : RefusHorsLigne.motDePasseIncorrect);
    }
    j['echecs'] = 0;
    j['bloque_jusqu_a'] = null;
    await _ecrire(tout);
    if (maintenant.difference(DateTime.parse(j['en_ligne_le'] as String)) > validite) {
      return const ResultatHorsLigne.refuse(RefusHorsLigne.expire);
    }
    return ResultatHorsLigne.accepte(AgentConnecte(
      matricule: _cle(matricule),
      nom: j['nom'] as String? ?? _cle(matricule),
      role: j['role'] as String? ?? 'agent',
    ));
  }

  /// Dernière adresse de serveur utilisée (pré-remplie à l'écran de connexion).
  Future<String?> derniereAdresse() async => (await _tout())['adresse'] as String?;

  /// Oublie un agent (accès retiré par le serveur).
  Future<void> oublier(String matricule) async {
    final tout = await _tout();
    (tout['agents'] as Map<String, dynamic>).remove(_cle(matricule));
    await _ecrire(tout);
  }

  /// Oublie tous les agents (appareil révoqué).
  Future<void> oublierTout() => _coffre.supprimer(cleCoffre);

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
