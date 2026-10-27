import 'dart:io';
import 'dart:typed_data';

import '../api/modeles.dart';
import '../capture/capture_native.dart';

/// Prépare l'envoi des découpes d'une capture : seulement les doigts NETS
/// (une découpe floue ferait baisser les scores sans rien prouver), un seul
/// exemplaire par doigt. `lire` est remplaçable dans les tests.
Future<List<DoigtEnvoi>> doigtsAEnvoyer(
  Iterable<DecoupeDoigt> decoupes, {
  Future<Uint8List> Function(String chemin)? lire,
}) async {
  final lecture = lire ?? (chemin) => File(chemin).readAsBytes();
  final parDoigt = <int, DecoupeDoigt>{};
  for (final d in decoupes) {
    if (!d.acceptee) continue;
    final deja = parDoigt[d.iso];
    if (deja == null || d.nettete > deja.nettete) parDoigt[d.iso] = d;
  }
  final isos = parDoigt.keys.toList()..sort();
  return [
    for (final iso in isos)
      DoigtEnvoi(iso: iso, image: await lecture(parDoigt[iso]!.chemin), dpiEstime: parDoigt[iso]!.dpiEstime),
  ];
}

/// Étapes de l'identification : scan → réponse du serveur → éventuellement
/// nouveau scan (les scans sont combinés côté serveur), 3 au plus. Après le
/// 3e scan non concluant : vérification manuelle sur pièce d'identité.
class ParcoursIdentification {
  static const scansMax = 3;

  final List<List<DoigtEnvoi>> _scans = [];
  ReponseIdentification? _reponse;

  List<List<DoigtEnvoi>> get scans => List.unmodifiable(_scans);
  ReponseIdentification? get reponse => _reponse;
  int get nombreScans => _scans.length;

  /// Ajoute un scan et renvoie la liste complète à envoyer au serveur.
  List<List<DoigtEnvoi>> ajouterScan(List<DoigtEnvoi> doigts) {
    if (_scans.length >= scansMax) throw StateError('Nombre maximal de scans atteint');
    _scans.add(doigts);
    _reponse = null;
    return scans;
  }

  /// Le scan qui vient d'être ajouté n'a pas pu être envoyé : on le retire.
  void annulerDernierScan() {
    if (_scans.isNotEmpty) _scans.removeLast();
  }

  void enregistrerReponse(ReponseIdentification reponse) => _reponse = reponse;

  bool get nonConcluant => _reponse?.verdict == VerdictIdentification.nonConcluant;
  bool get peutRescanner => nonConcluant && _scans.length < scansMax;
  bool get verificationManuelle => nonConcluant && _scans.length >= scansMax;

  void recommencer() {
    _scans.clear();
    _reponse = null;
  }
}
