/// Fiche en cours de saisie : valeurs autorisées et validations, ALIGNÉES sur
/// le serveur (backend/app/referentiels.py et schemas.py). Le serveur revérifie
/// tout ; ces contrôles servent à corriger la saisie avant l'envoi.
library;

import 'dart:typed_data';

/// Code envoyé au serveur → libellé affiché.
const iles = {'Ngazidja': 'Ngazidja', 'Ndzuani': 'Ndzuani', 'Mwali': 'Mwali'};
const sexes = {'M': 'Masculin', 'F': 'Féminin'};
const couleursYeux = {
  'noirs': 'Noirs',
  'marron_fonce': 'Marron foncé',
  'marron': 'Marron',
  'noisette': 'Noisette',
  'verts': 'Verts',
  'bleus': 'Bleus',
  'gris': 'Gris',
  'autre': 'Autre',
};
const couleursCheveux = {
  'noirs': 'Noirs',
  'bruns': 'Bruns',
  'chatains': 'Châtains',
  'blonds': 'Blonds',
  'roux': 'Roux',
  'gris': 'Gris',
  'blancs': 'Blancs',
  'chauve': 'Chauve',
  'autre': 'Autre',
};

const tailleMinCm = 50;
const tailleMaxCm = 250;
final dateNaissanceMin = DateTime(1900);

/// Fiche en cours de saisie (gardée en mémoire seulement : voir « hors ligne »
/// dans le rapport de phase 2).
class BrouillonFiche {
  String nom = '';
  String prenoms = '';
  String? sexe;
  DateTime? dateNaissance;
  String lieuNaissance = '';
  String nationalite = 'Comorienne';
  String numeroActeNaissance = '';
  String telephone = '';

  String? ile;
  String ville = '';
  String quartier = '';
  String adresse = '';
  String taille = '';
  String? couleurYeux;
  String? couleurCheveux;

  Uint8List? photo; // JPEG
  Uint8List? signature; // PNG

  /// Corps de POST /citoyens.
  Map<String, Object?> versJson() => {
        'nom': nom.trim(),
        'prenoms': prenoms.trim(),
        'sexe': sexe,
        'date_naissance': dateNaissance == null ? null : _date(dateNaissance!),
        'lieu_naissance': lieuNaissance.trim(),
        'nationalite': nationalite.trim(),
        'numero_acte_naissance': numeroActeNaissance.trim(),
        'telephone': normaliserTelephone(telephone),
        'ile': ile,
        'ville': ville.trim(),
        'quartier': quartier.trim(),
        'adresse': adresse.trim(),
        'taille_cm': int.tryParse(taille.trim()),
        'couleur_yeux': couleurYeux,
        'couleur_cheveux': couleurCheveux,
      };

  static String _date(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

// ------------------------------------------------------------------ validations
// Chaque fonction renvoie null si la valeur est correcte, sinon le message.

String? obligatoire(String? v, {int max = 100}) {
  final t = (v ?? '').trim();
  if (t.isEmpty) return 'Champ obligatoire';
  if (t.length > max) return '$max caractères au plus';
  return null;
}

String? choixObligatoire(Object? v) => v == null ? 'Choix obligatoire' : null;

String? validerDateNaissance(DateTime? d, {DateTime? aujourdhui}) {
  if (d == null) return 'Date obligatoire';
  final maintenant = aujourdhui ?? DateTime.now();
  if (d.isAfter(DateTime(maintenant.year, maintenant.month, maintenant.day))) {
    return 'La date ne peut pas être dans le futur';
  }
  if (d.isBefore(dateNaissanceMin)) return 'Date trop ancienne';
  return null;
}

/// Comme le serveur : « +269 321 00 00 », « 321-00-00 », « 00269… » → « +2693210000 ».
/// Chaîne vide → null (le téléphone est facultatif). Valeur invalide → renvoyée telle quelle.
String? normaliserTelephone(String saisie) {
  var t = saisie.replaceAll(RegExp(r'[\s.\-()]'), '');
  if (t.isEmpty) return null;
  if (RegExp(r'^\d{7}$').hasMatch(t)) t = '+269$t';
  if (t.startsWith('00269')) t = '+${t.substring(2)}';
  return t;
}

String? validerTelephone(String saisie) {
  final t = normaliserTelephone(saisie);
  if (t == null) return null;
  return RegExp(r'^\+269\d{7}$').hasMatch(t) ? null : 'Attendu : +269 suivi de 7 chiffres';
}

String? validerTaille(String saisie) {
  final t = int.tryParse(saisie.trim());
  if (t == null) return 'Taille en centimètres (nombre entier)';
  if (t < tailleMinCm || t > tailleMaxCm) return 'Entre $tailleMinCm et $tailleMaxCm cm';
  return null;
}

/// Erreurs de l'étape « Identité » (champ → message), vide si tout est correct.
Map<String, String> erreursIdentite(BrouillonFiche f, {DateTime? aujourdhui}) => _sansNulls({
      'nom': obligatoire(f.nom),
      'prenoms': obligatoire(f.prenoms, max: 150),
      'sexe': choixObligatoire(f.sexe),
      'date_naissance': validerDateNaissance(f.dateNaissance, aujourdhui: aujourdhui),
      'lieu_naissance': obligatoire(f.lieuNaissance, max: 150),
      'nationalite': obligatoire(f.nationalite),
      'numero_acte_naissance': obligatoire(f.numeroActeNaissance, max: 50),
      'telephone': validerTelephone(f.telephone),
    });

/// Erreurs de l'étape « Domicile et signalement ».
Map<String, String> erreursDomicile(BrouillonFiche f) => _sansNulls({
      'ile': choixObligatoire(f.ile),
      'ville': obligatoire(f.ville),
      'quartier': obligatoire(f.quartier),
      'adresse': obligatoire(f.adresse, max: 255),
      'taille_cm': validerTaille(f.taille),
      'couleur_yeux': choixObligatoire(f.couleurYeux),
      'couleur_cheveux': choixObligatoire(f.couleurCheveux),
    });

/// Erreurs de l'étape « Photo et signature ».
Map<String, String> erreursMedias(BrouillonFiche f) => _sansNulls({
      'photo': f.photo == null ? 'Photo du visage obligatoire' : null,
      'signature': f.signature == null ? 'Signature obligatoire' : null,
    });

Map<String, String> _sansNulls(Map<String, String?> m) => {
      for (final e in m.entries)
        if (e.value != null) e.key: e.value!,
    };
