import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../api/modeles.dart';
import '../fiche/envoi.dart';
import '../fiche/fiche.dart';
import 'chiffrement.dart';

/// État d'un enregistrement en attente.
enum StatutAttente {
  /// À envoyer dès que possible.
  enAttente,

  /// Doublon signalé par le serveur : vérification d'un superviseur.
  aVerifier,

  /// Refus du serveur autre qu'un doublon (données invalides…).
  erreur,
}

/// Un enregistrement fait sur le téléphone et pas encore entièrement envoyé.
/// Contient les DÉCOUPES DES DOIGTS (le modèle est calculé par le serveur) :
/// exception temporaire à la règle « modèles, pas photos des doigts », admise
/// pour le hors ligne ; le fichier est chiffré et effacé dès l'envoi réussi.
class ElementAttente {
  ElementAttente({
    required this.id,
    required this.creeLe,
    required this.agent,
    required this.fiche,
    required this.doigts,
    this.statut = StatutAttente.enAttente,
    this.etape = EtapeEnvoi.controle,
    this.numero,
    this.controle,
    this.validationSuperviseur = false,
    this.message,
  });

  /// Nouvel élément, avec un identifiant local aléatoire.
  factory ElementAttente.nouveau({required String agent, required BrouillonFiche fiche, required List<DoigtEnvoi> doigts}) {
    final aleatoire = Random.secure();
    final id = List.generate(16, (_) => aleatoire.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    return ElementAttente(id: id, creeLe: DateTime.now(), agent: agent, fiche: fiche, doigts: doigts);
  }

  final String id;
  final DateTime creeLe;

  /// Matricule de l'agent qui a fait l'enregistrement.
  final String agent;
  final BrouillonFiche fiche;
  final List<DoigtEnvoi> doigts;

  StatutAttente statut;
  EtapeEnvoi etape;
  String? numero;
  ControleDoublon? controle;
  bool validationSuperviseur;

  /// Dernier message à montrer à l'agent (refus, doublon…).
  String? message;

  /// Référence courte affichée tant qu'aucun numéro n'est attribué.
  String get reference => 'HL-${id.substring(0, 6).toUpperCase()}';

  String get nomComplet => '${fiche.nom.trim().toUpperCase()} ${fiche.prenoms.trim()}';

  Map<String, Object?> versJson() => {
        'version': 1,
        'id': id,
        'cree_le': creeLe.toIso8601String(),
        'agent': agent,
        'fiche': fiche.versStockage(),
        'doigts': [
          for (final d in doigts) {'iso': d.iso, 'image': base64Encode(d.image), 'dpi': d.dpiEstime},
        ],
        'statut': statut.name,
        'etape': etape.name,
        'numero': numero,
        'controle': controle == null
            ? null
            : {
                'verdict': {
                  VerdictDoublon.doublonCertain: 'doublon_certain',
                  VerdictDoublon.doublonPossible: 'doublon_possible',
                  VerdictDoublon.aucunDoublon: 'aucun_doublon',
                }[controle!.verdict],
                'motif': controle!.motif,
                'numeros': controle!.numeros,
              },
        'validation_superviseur': validationSuperviseur,
        'message': message,
      };

  factory ElementAttente.depuisJson(Map<String, dynamic> j) => ElementAttente(
        id: j['id'] as String,
        creeLe: DateTime.parse(j['cree_le'] as String),
        agent: j['agent'] as String,
        fiche: BrouillonFiche.depuisStockage(j['fiche'] as Map<String, dynamic>),
        doigts: [
          for (final d in j['doigts'] as List)
            DoigtEnvoi(
              iso: (d['iso'] as num).toInt(),
              image: base64Decode(d['image'] as String),
              dpiEstime: (d['dpi'] as num).toDouble(),
            ),
        ],
        statut: StatutAttente.values.byName(j['statut'] as String),
        etape: EtapeEnvoi.values.byName(j['etape'] as String),
        numero: j['numero'] as String?,
        controle: j['controle'] == null ? null : ControleDoublon.depuisJson(j['controle'] as Map<String, dynamic>),
        validationSuperviseur: j['validation_superviseur'] as bool? ?? false,
        message: j['message'] as String?,
      );
}

/// File d'attente des enregistrements à envoyer.
abstract class FileAttente {
  /// Ajoute ou remplace l'élément.
  Future<void> enregistrer(ElementAttente e);

  /// Tous les éléments, du plus ancien au plus récent. Les fichiers illisibles
  /// (modifiés, clé perdue) sont ignorés et signalés dans `illisibles`.
  Future<List<ElementAttente>> lister({List<String>? illisibles});

  /// Supprime l'élément : ses données (dont les découpes des doigts) disparaissent du téléphone.
  Future<void> supprimer(String id);

  Future<int> nombre() async => (await lister()).length;
}

/// File d'attente sur le téléphone : un fichier CHIFFRÉ par enregistrement,
/// dans le dossier privé de l'application.
class FileAttenteChiffree extends FileAttente {
  FileAttenteChiffree(this.dossier, this._chiffreur);

  final Directory dossier;
  final Chiffreur _chiffreur;
  static const _extension = '.hawiya';

  File _fichier(String id) => File('${dossier.path}/$id$_extension');

  /// Écriture atomique : fichier temporaire puis renommage (un arrêt brutal
  /// pendant l'écriture ne corrompt pas l'enregistrement précédent).
  @override
  Future<void> enregistrer(ElementAttente e) async {
    await dossier.create(recursive: true);
    final temporaire = File('${_fichier(e.id).path}.tmp');
    await temporaire.writeAsBytes(await _chiffreur.chiffrerJson(e.versJson()), flush: true);
    await temporaire.rename(_fichier(e.id).path);
  }

  @override
  Future<List<ElementAttente>> lister({List<String>? illisibles}) async {
    if (!await dossier.exists()) return [];
    final elements = <ElementAttente>[];
    await for (final f in dossier.list()) {
      if (f is! File || !f.path.endsWith(_extension)) continue;
      try {
        elements.add(ElementAttente.depuisJson(await _chiffreur.dechiffrerJson(await f.readAsBytes())));
      } on Exception {
        illisibles?.add(f.path);
      }
    }
    elements.sort((a, b) => a.creeLe.compareTo(b.creeLe));
    return elements;
  }

  @override
  Future<void> supprimer(String id) async {
    final f = _fichier(id);
    if (await f.exists()) await f.delete();
  }
}

/// File en mémoire, pour les tests d'écran (pas de fichiers sous `testWidgets`).
/// Passe par le même JSON que la file chiffrée.
class FileAttenteMemoire extends FileAttente {
  final _elements = <String, String>{};

  @override
  Future<void> enregistrer(ElementAttente e) async => _elements[e.id] = jsonEncode(e.versJson());

  @override
  Future<List<ElementAttente>> lister({List<String>? illisibles}) async => [
        for (final j in _elements.values) ElementAttente.depuisJson(jsonDecode(j) as Map<String, dynamic>),
      ]..sort((a, b) => a.creeLe.compareTo(b.creeLe));

  @override
  Future<void> supprimer(String id) async => _elements.remove(id);
}
