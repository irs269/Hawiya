/// Données échangées avec le serveur Hawiya (voir backend/app/schemas.py).
library;

import 'dart:typed_data';

/// Fiche d'un citoyen, telle que renvoyée par l'API (données FICTIVES en démo).
class Citoyen {
  const Citoyen({
    required this.numero,
    required this.nom,
    required this.prenoms,
    required this.sexe,
    required this.dateNaissance,
    required this.lieuNaissance,
    required this.nationalite,
    required this.ile,
    required this.ville,
    required this.quartier,
    this.telephone,
    this.tailleCm,
    this.enregistreLe,
  });

  final String numero;
  final String nom;
  final String prenoms;
  final String sexe;
  final DateTime dateNaissance;
  final String lieuNaissance;
  final String nationalite;
  final String ile;
  final String ville;
  final String quartier;
  final String? telephone;
  final int? tailleCm;
  final DateTime? enregistreLe;

  factory Citoyen.depuisJson(Map<String, dynamic> j) => Citoyen(
        numero: j['numero'] as String,
        nom: j['nom'] as String,
        prenoms: j['prenoms'] as String,
        sexe: j['sexe'] as String,
        dateNaissance: DateTime.parse(j['date_naissance'] as String),
        lieuNaissance: j['lieu_naissance'] as String? ?? '',
        nationalite: j['nationalite'] as String? ?? '',
        ile: j['ile'] as String,
        ville: j['ville'] as String? ?? '',
        quartier: j['quartier'] as String? ?? '',
        telephone: j['telephone'] as String?,
        tailleCm: (j['taille_cm'] as num?)?.toInt(),
        enregistreLe: j['enregistre_le'] == null ? null : DateTime.parse(j['enregistre_le'] as String),
      );
}

/// Agent connecté (GET /auth/moi).
class AgentConnecte {
  const AgentConnecte({required this.matricule, required this.nom, required this.role, this.doitChangerMotDePasse = false});

  final String matricule;
  final String nom;

  /// « agent », « superviseur » ou « administrateur ».
  final String role;

  /// Mot de passe provisoire : à changer avant toute autre action.
  final bool doitChangerMotDePasse;

  /// Peut valider un doublon possible (le serveur le vérifie aussi).
  bool get peutValiderDoublon => role == 'superviseur' || role == 'administrateur';

  factory AgentConnecte.depuisJson(Map<String, dynamic> j) => AgentConnecte(
        matricule: j['matricule'] as String,
        nom: j['nom'] as String,
        role: j['role'] as String,
        doitChangerMotDePasse: j['doit_changer_mot_de_passe'] as bool? ?? false,
      );
}

/// Un doigt à envoyer : image de la découpe (PNG) et résolution estimée.
/// L'image sert au calcul du modèle sur le serveur, qui ne la garde pas.
class DoigtEnvoi {
  const DoigtEnvoi({required this.iso, required this.image, required this.dpiEstime});

  /// ISO 19794 : 1 = pouce droit … 10 = auriculaire gauche.
  final int iso;
  final Uint8List image;
  final double dpiEstime;
}

enum VerdictIdentification { identifie, nonEnregistre, nonConcluant }

class ReponseIdentification {
  const ReponseIdentification({
    required this.verdict,
    required this.motif,
    required this.doigtsCompares,
    required this.doigtsConcordants,
    this.doigtsIllisibles = const [],
    this.citoyen,
  });

  final VerdictIdentification verdict;
  final String motif;
  final int doigtsCompares;
  final int doigtsConcordants;
  final List<int> doigtsIllisibles;

  /// Seulement si le verdict est « identifié ».
  final Citoyen? citoyen;

  static const _verdicts = {
    'identifie': VerdictIdentification.identifie,
    'non_enregistre': VerdictIdentification.nonEnregistre,
    'non_concluant': VerdictIdentification.nonConcluant,
  };

  factory ReponseIdentification.depuisJson(Map<String, dynamic> j) {
    final verdict = _verdicts[j['verdict']];
    if (verdict == null) throw FormatException('Verdict inconnu : ${j['verdict']}');
    final citoyen = j['citoyen'] == null ? null : Citoyen.depuisJson(j['citoyen'] as Map<String, dynamic>);
    // Sécurité : jamais de fiche affichée si le serveur ne dit pas « identifié ».
    return ReponseIdentification(
      verdict: verdict,
      motif: j['motif'] as String? ?? '',
      doigtsCompares: (j['doigts_compares'] as num?)?.toInt() ?? 0,
      doigtsConcordants: (j['doigts_concordants'] as num?)?.toInt() ?? 0,
      doigtsIllisibles: [for (final d in (j['doigts_illisibles'] as List?) ?? const []) (d as num).toInt()],
      citoyen: verdict == VerdictIdentification.identifie ? citoyen : null,
    );
  }
}

enum VerdictDoublon { doublonCertain, doublonPossible, aucunDoublon }

class ControleDoublon {
  const ControleDoublon({required this.verdict, required this.motif, this.numeros = const []});

  final VerdictDoublon verdict;
  final String motif;

  /// Numéros des fiches à vérifier.
  final List<String> numeros;

  static const _verdicts = {
    'doublon_certain': VerdictDoublon.doublonCertain,
    'doublon_possible': VerdictDoublon.doublonPossible,
    'aucun_doublon': VerdictDoublon.aucunDoublon,
  };

  factory ControleDoublon.depuisJson(Map<String, dynamic> j) {
    final verdict = _verdicts[j['verdict']];
    if (verdict == null) throw FormatException('Verdict inconnu : ${j['verdict']}');
    return ControleDoublon(
      verdict: verdict,
      motif: j['motif'] as String? ?? '',
      numeros: [for (final n in (j['numeros'] as List?) ?? const []) n as String],
    );
  }
}

/// Résultat de l'envoi des empreintes d'une fiche : enregistrées, ou refusées
/// pour doublon (certain ou possible).
class ResultatEnregistrement {
  const ResultatEnregistrement({
    required this.enregistre,
    required this.controle,
    this.doigtsEnregistres = const [],
    this.doigtsIllisibles = const [],
  });

  final bool enregistre;
  final ControleDoublon controle;
  final List<int> doigtsEnregistres;
  final List<int> doigtsIllisibles;
}
