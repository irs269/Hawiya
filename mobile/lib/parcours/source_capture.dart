import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../capture/capture_native.dart';
import '../capture/ecran_capture.dart';
import '../capture/guidage.dart';

/// Accès à la caméra pour les parcours. Remplaçable dans les tests (pas de
/// caméra ni de module natif sous `flutter test`).
class SourceCapture {
  const SourceCapture();

  /// Ouvre l'écran de capture pour `etapes` ; renvoie toutes les découpes,
  /// ou null si l'agent a quitté la capture.
  Future<List<DecoupeDoigt>?> capturer(BuildContext context, List<EtapeCapture> etapes, String titre) async {
    final resultats = await Navigator.push<Map<int, ResultatCapture>>(
      context,
      MaterialPageRoute(
        builder: (_) => EcranCapture(
          etapes: etapes,
          // Parcours réels : les images ne sont pas gardées.
          debogageInitial: false,
          renvoyerResultats: true,
          titreParcours: titre,
        ),
      ),
    );
    if (resultats == null) return null;
    return [for (final r in resultats.values) ...r.decoupes];
  }

  Future<Uint8List> lire(String chemin) => File(chemin).readAsBytes();

  /// Efface les découpes du téléphone (elles ne doivent pas y rester).
  Future<void> nettoyer() async {
    try {
      await CaptureNative.supprimerTemporaires();
    } catch (_) {
      // Rien à effacer, ou module natif absent : sans conséquence.
    }
  }
}
