import 'dart:convert';

import 'package:http/http.dart' as http;

import 'modeles.dart';

/// Erreur de dialogue avec le serveur, avec un message lisible par l'agent.
class ErreurApi implements Exception {
  const ErreurApi(this.message, {this.code});

  final String message;

  /// Code HTTP (null si le serveur n'a pas répondu).
  final int? code;

  @override
  String toString() => message;
}

/// Client de l'API Hawiya. Le jeton de connexion n'est gardé qu'en mémoire
/// (le stockage sécurisé arrive avec l'authentification complète, phase 1 bis).
class ClientApi {
  ClientApi(String adresse, {http.Client? client, this.delai = const Duration(seconds: 60)})
      : adresse = normaliserAdresse(adresse),
        _http = client ?? http.Client();

  /// Adresse du serveur, sans « / » final (ex. http://192.168.1.20:8000).
  final String adresse;

  /// Délai d'attente : la comparaison multi-échelle prend quelques secondes.
  final Duration delai;
  final http.Client _http;
  String? _jeton;

  bool get connecte => _jeton != null;

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

  Future<http.Response> _envoyer(Future<http.Response> Function() requete) async {
    try {
      return await requete().timeout(delai);
    } on ErreurApi {
      rethrow;
    } catch (e) {
      throw ErreurApi('Serveur injoignable ($adresse). Vérifiez le réseau et l\'adresse.');
    }
  }

  /// Message d'erreur du serveur (« detail » de FastAPI) ou message générique.
  static String _detail(http.Response r) {
    try {
      final corps = jsonDecode(utf8.decode(r.bodyBytes));
      final detail = corps is Map ? corps['detail'] : null;
      if (detail is String) return detail;
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
    if (r.statusCode == 401) _jeton = null;
    if (r.statusCode >= 400) throw ErreurApi(_detail(r), code: r.statusCode);
  }

  static List<Map<String, Object>> _doigtsJson(List<DoigtEnvoi> doigts) => [
        for (final d in doigts) {'doigt': d.iso, 'image': base64Encode(d.image), 'dpi_estime': d.dpiEstime},
      ];

  // ----------------------------------------------------------------- routes

  Future<void> connexion(String matricule, String motDePasse) async {
    final r = await _envoyer(() => _http.post(
          _uri('/auth/connexion'),
          headers: {'Content-Type': 'application/x-www-form-urlencoded'},
          body: {'username': matricule.trim(), 'password': motDePasse},
        ));
    if (r.statusCode == 401) throw const ErreurApi('Matricule ou mot de passe incorrect.', code: 401);
    _verifier(r);
    _jeton = _json(r)['access_token'] as String;
  }

  void deconnexion() => _jeton = null;

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
