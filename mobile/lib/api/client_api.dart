import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'modeles.dart';

/// Erreur de dialogue avec le serveur, avec un message lisible par l'agent.
class ErreurApi implements Exception {
  const ErreurApi(this.message, {this.code, this.raison, this.codeAppareil});

  final String message;

  /// Code HTTP (null si le serveur n'a pas répondu).
  final int? code;

  /// Code d'erreur précis du serveur (« appareil_en_attente », « jeton_reutilise »…).
  final String? raison;

  /// Code court de l'appareil, quand il doit être approuvé.
  final String? codeAppareil;

  @override
  String toString() => message;
}

/// Client de l'API Hawiya.
///
/// - Le jeton d'ACCÈS (15 min) reste en mémoire.
/// - Le jeton de RENOUVELLEMENT est confié à `surRenouvellement` pour être
///   gardé dans le coffre du téléphone ; quand le jeton d'accès expire, le
///   client en obtient un nouveau tout seul et rejoue la requête une fois.
/// - Chaque connexion présente l'identifiant de l'appareil (approuvé par un superviseur).
class ClientApi {
  ClientApi(
    String adresse, {
    http.Client? client,
    this.delai = const Duration(seconds: 60),
    this.identifiantAppareil = 'appareil-non-renseigne',
    this.nomAppareil,
    this.surRenouvellement,
  })  : adresse = normaliserAdresse(adresse),
        _http = client ?? http.Client();

  /// Adresse du serveur, sans « / » final (ex. http://192.168.1.20:8000).
  final String adresse;

  /// Délai d'attente : la comparaison multi-échelle prend quelques secondes.
  final Duration delai;
  final String identifiantAppareil;
  final String? nomAppareil;

  /// Appelé à chaque nouveau jeton de renouvellement (null = session terminée).
  final Future<void> Function(String? jeton)? surRenouvellement;

  final http.Client _http;
  String? _jeton;
  String? _renouvellement;
  Future<bool>? _renouvellementEnCours;

  /// Raison du dernier refus de renouvellement (ex. « acces_retire »).
  String? derniereRaisonRefus;

  bool get connecte => _jeton != null || _renouvellement != null;

  static String normaliserAdresse(String saisie) {
    var a = saisie.trim();
    if (a.isEmpty) return a;
    if (!a.startsWith('http://') && !a.startsWith('https://')) a = 'http://$a';
    while (a.endsWith('/')) {
      a = a.substring(0, a.length - 1);
    }
    return a;
  }

  Uri _uri(String chemin) => Uri.parse('$adresse$chemin');

  Map<String, String> get _entetes => {
        'Content-Type': 'application/json',
        if (_jeton != null) 'Authorization': 'Bearer $_jeton',
      };

  Future<http.Response> _brut(Future<http.Response> Function() requete) async {
    try {
      return await requete().timeout(delai);
    } catch (e) {
      throw ErreurApi('Serveur injoignable ($adresse). Vérifiez le réseau et l\'adresse.');
    }
  }

  /// Envoie la requête ; si le jeton d'accès a expiré (401), le renouvelle puis
  /// rejoue la requête UNE fois (les en-têtes sont recalculés à l'appel).
  Future<http.Response> _envoyer(Future<http.Response> Function() requete) async {
    final r = await _brut(requete);
    if (r.statusCode != 401 || _renouvellement == null) return r;
    if (!await _renouveler()) return r;
    return _brut(requete);
  }

  /// Un seul renouvellement à la fois : deux requêtes expirées en même temps
  /// ne doivent pas présenter deux fois le même jeton (le serveur y verrait un vol).
  Future<bool> _renouveler() => _renouvellementEnCours ??= _faireRenouvellement().whenComplete(() {
        _renouvellementEnCours = null;
      });

  Future<bool> _faireRenouvellement() async {
    final jeton = _renouvellement;
    if (jeton == null) return false;
    final http.Response r;
    try {
      r = await _brut(() => _http.post(
            _uri('/auth/renouveler'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'refresh_token': jeton}),
          ));
    } on ErreurApi {
      return false; // pas de réseau : on garde le jeton pour plus tard
    }
    if (r.statusCode == 200) {
      await _enregistrerJetons(_json(r));
      return true;
    }
    if (r.statusCode == 401) {
      derniereRaisonRefus = _raison(r);
      _jeton = null;
      _renouvellement = null;
      await surRenouvellement?.call(null);
    }
    return false;
  }

  Future<void> _enregistrerJetons(Map<String, dynamic> j) async {
    _jeton = j['access_token'] as String;
    _renouvellement = j['refresh_token'] as String?;
    await surRenouvellement?.call(_renouvellement);
  }

  static String? _raison(http.Response r) {
    try {
      final detail = (jsonDecode(utf8.decode(r.bodyBytes)) as Map)['detail'];
      if (detail is Map) return detail['code'] as String?;
    } catch (_) {}
    return null;
  }

  /// Message d'erreur du serveur (« detail » de FastAPI) ou message générique.
  static String _detail(http.Response r) {
    try {
      final corps = jsonDecode(utf8.decode(r.bodyBytes));
      final detail = corps is Map ? corps['detail'] : null;
      if (detail is String) return detail;
      // Erreurs de validation FastAPI : liste de {loc, msg}.
      if (detail is List && detail.isNotEmpty) {
        return [
          for (final e in detail.take(3))
            if (e is Map) '${(e['loc'] as List?)?.last ?? ''} : ${e['msg']}',
        ].join('\n');
      }
      if (detail is Map && detail['message'] is String) return detail['message'] as String;
      if (detail is Map && detail['motif'] is String) return detail['motif'] as String;
    } catch (_) {}
    return switch (r.statusCode) {
      401 => 'Session expirée : reconnectez-vous.',
      403 => 'Action non autorisée pour ce compte.',
      404 => 'Introuvable.',
      422 => 'Données refusées par le serveur.',
      503 => 'Service de comparaison indisponible.',
      _ => 'Erreur du serveur (${r.statusCode}).',
    };
  }

  static Map<String, dynamic> _json(http.Response r) =>
      jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;

  void _verifier(http.Response r) {
    if (r.statusCode == 401) {
      _jeton = null;
      _renouvellement = null;
    }
    if (r.statusCode >= 400) {
      String? codeAppareil;
      try {
        final detail = _json(r)['detail'];
        if (detail is Map) codeAppareil = detail['code_appareil'] as String?;
      } catch (_) {}
      throw ErreurApi(_detail(r), code: r.statusCode, raison: _raison(r), codeAppareil: codeAppareil);
    }
  }

  static List<Map<String, Object>> _doigtsJson(List<DoigtEnvoi> doigts) => [
        for (final d in doigts) {'doigt': d.iso, 'image': base64Encode(d.image), 'dpi_estime': d.dpiEstime},
      ];

  // ----------------------------------------------------------------- session

  /// Connexion par mot de passe depuis cet appareil. Renvoie vrai si le mot de
  /// passe est provisoire et doit être changé avant toute autre action.
  /// Appareil pas encore approuvé : ErreurApi (403, raison « appareil_en_attente »).
  Future<bool> connexion(String matricule, String motDePasse) async {
    final r = await _brut(() => _http.post(
          _uri('/auth/connexion'),
          headers: {'Content-Type': 'application/x-www-form-urlencoded'},
          body: {
            'username': matricule.trim(),
            'password': motDePasse,
            'client_id': identifiantAppareil,
            'appareil_nom': ?nomAppareil,
          },
        ));
    _verifier(r);
    final j = _json(r);
    await _enregistrerJetons(j);
    return j['doit_changer_mot_de_passe'] as bool? ?? false;
  }

  /// Reprend une session avec un jeton de renouvellement gardé dans le coffre
  /// (redémarrage de l'application). Faux si la session n'est plus valable
  /// ou si le serveur est injoignable.
  Future<bool> reprendre(String jetonRenouvellement) async {
    _renouvellement = jetonRenouvellement;
    final ok = await _renouveler();
    if (!ok && _jeton == null) _renouvellement = null;
    return ok;
  }

  /// Révoque la session sur le serveur (si joignable) et l'oublie ici.
  Future<void> deconnexion() async {
    if (_jeton != null) {
      try {
        await _brut(() => _http.post(_uri('/auth/deconnexion'), headers: _entetes));
      } on ErreurApi {
        // Hors ligne : la session expirera d'elle-même côté serveur.
      }
    }
    _jeton = null;
    _renouvellement = null;
    await surRenouvellement?.call(null);
  }

  Future<void> changerMotDePasse(String ancien, String nouveau) async {
    final corps = jsonEncode({'ancien': ancien, 'nouveau': nouveau});
    final r = await _envoyer(() => _http.post(_uri('/auth/mot-de-passe'), headers: _entetes, body: corps));
    _verifier(r);
  }

  Future<AgentConnecte> moi() async {
    final r = await _envoyer(() => _http.get(_uri('/auth/moi'), headers: _entetes));
    _verifier(r);
    return AgentConnecte.depuisJson(_json(r));
  }

  // ----------------------------------------------------------------- routes

  /// Crée la fiche (POST /citoyens) ; le serveur attribue le numéro.
  Future<Citoyen> creerCitoyen(Map<String, Object?> fiche) async {
    final r = await _envoyer(() => _http.post(_uri('/citoyens'), headers: _entetes, body: jsonEncode(fiche)));
    _verifier(r);
    return Citoyen.depuisJson(_json(r));
  }

  /// Photo du visage (JPEG/PNG) et signature (PNG) d'une fiche.
  Future<void> envoyerMedias(String numero, {List<int>? photo, List<int>? signature}) async {
    final corps = jsonEncode({
      if (photo != null) 'photo': base64Encode(photo),
      if (signature != null) 'signature': base64Encode(signature),
    });
    final r = await _envoyer(() => _http.put(
          _uri('/citoyens/${Uri.encodeComponent(numero.trim())}/medias'),
          headers: _entetes,
          body: corps,
        ));
    _verifier(r);
  }

  /// Contrôle anti-doublon AVANT la création de la fiche (rien n'est enregistré).
  Future<ControleDoublon> controlerDoublon(List<DoigtEnvoi> doigts) async {
    final corps = jsonEncode({'doigts': _doigtsJson(doigts)});
    final r = await _envoyer(() => _http.post(_uri('/doublons'), headers: _entetes, body: corps));
    _verifier(r);
    return ControleDoublon.depuisJson(_json(r));
  }

  Future<Citoyen> lireCitoyen(String numero) async {
    final r = await _envoyer(() => _http.get(_uri('/citoyens/${Uri.encodeComponent(numero.trim())}'), headers: _entetes));
    if (r.statusCode == 404) throw const ErreurApi('Aucune fiche ne porte ce numéro.', code: 404);
    _verifier(r);
    return Citoyen.depuisJson(_json(r));
  }

  /// Un ou plusieurs scans de la même main (3 au plus).
  Future<ReponseIdentification> identifier(List<List<DoigtEnvoi>> scans) async {
    final corps = jsonEncode({
      'scans': [
        for (final s in scans) {'doigts': _doigtsJson(s)},
      ],
    });
    final r = await _envoyer(() => _http.post(_uri('/identification'), headers: _entetes, body: corps));
    _verifier(r);
    return ReponseIdentification.depuisJson(_json(r));
  }

  /// Enregistre les modèles d'empreintes d'une fiche. Un doublon (409) n'est pas
  /// une erreur : il est renvoyé dans le résultat pour être expliqué à l'agent.
  Future<ResultatEnregistrement> enregistrerEmpreintes(
    String numero,
    List<DoigtEnvoi> doigts, {
    bool validationSuperviseur = false,
  }) async {
    final corps = jsonEncode({'doigts': _doigtsJson(doigts), 'validation_superviseur': validationSuperviseur});
    final r = await _envoyer(() => _http.put(
          _uri('/citoyens/${Uri.encodeComponent(numero.trim())}/empreintes'),
          headers: _entetes,
          body: corps,
        ));
    if (r.statusCode == 409) {
      final detail = _json(r)['detail'] as Map<String, dynamic>;
      return ResultatEnregistrement(enregistre: false, controle: ControleDoublon.depuisJson(detail));
    }
    _verifier(r);
    final j = _json(r);
    return ResultatEnregistrement(
      enregistre: true,
      controle: ControleDoublon.depuisJson(j['controle_doublon'] as Map<String, dynamic>),
      doigtsEnregistres: [for (final d in j['doigts_enregistres'] as List) (d as num).toInt()],
      doigtsIllisibles: [for (final d in (j['doigts_illisibles'] as List?) ?? const []) (d as num).toInt()],
    );
  }
}
