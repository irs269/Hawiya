import 'package:flutter/services.dart';

/// Une main détectée par MediaPipe (coordonnées normalisées 0..1, image portrait).
class MainDetectee {
  const MainDetectee({
    required this.cote,
    required this.confiance,
    required this.points,
    required this.paume,
    this.etiquetteBrute = '',
    this.produit = 0,
  });

  /// Diagnostic : étiquette MediaPipe avant correction (« Left »/« Right »).
  final String etiquetteBrute;

  /// Diagnostic : signe du produit vectoriel utilisé pour paume/dos.
  final double produit;

  /// « droite » ou « gauche », du point de vue de la personne filmée.
  final String cote;
  final double confiance;

  /// Les 21 points de repère MediaPipe.
  final List<Offset> points;

  /// Estimation : la paume (et non le dos de la main) est tournée vers la caméra.
  final bool paume;

  factory MainDetectee.depuisMap(Map<Object?, Object?> m) {
    final valeurs = (m['points'] as List).cast<num>();
    return MainDetectee(
      cote: m['cote'] as String,
      confiance: (m['confiance'] as num).toDouble(),
      points: [
        for (var i = 0; i + 1 < valeurs.length; i += 2)
          Offset(valeurs[i].toDouble(), valeurs[i + 1].toDouble()),
      ],
      paume: m['paume'] as bool,
      etiquetteBrute: m['etiquetteBrute'] as String? ?? '',
      produit: (m['produit'] as num?)?.toDouble() ?? 0,
    );
  }
}

/// Résultat de l'analyse d'une image par le module natif.
class Analyse {
  const Analyse({
    required this.ips,
    required this.latenceMs,
    required this.largeur,
    required this.hauteur,
    required this.thermique,
    required this.zoom,
    required this.mains,
  });

  final double ips;
  final int latenceMs;
  final int largeur;
  final int hauteur;

  /// 0 = normal … 6 = arrêt imminent ; -1 = inconnu (Android < 10).
  final int thermique;
  final double zoom;
  final List<MainDetectee> mains;

  factory Analyse.depuisMap(Map<Object?, Object?> m) => Analyse(
        ips: (m['ips'] as num).toDouble(),
        latenceMs: (m['latenceMs'] as num).toInt(),
        largeur: (m['largeur'] as num).toInt(),
        hauteur: (m['hauteur'] as num).toInt(),
        thermique: (m['thermique'] as num).toInt(),
        zoom: (m['zoom'] as num).toDouble(),
        mains: [
          for (final main in m['mains'] as List)
            MainDetectee.depuisMap(main as Map<Object?, Object?>),
        ],
      );
}

/// Erreur signalée par le module natif (modèle absent, caméra indisponible…).
class ErreurCapture implements Exception {
  const ErreurCapture(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Accès au module natif de capture (Kotlin : CameraX + MediaPipe).
class CaptureNative {
  /// Identifiant de la vue native d'aperçu (voir CanalCapture.kt).
  static const vueApercu = 'hawiya/apercu';

  static const _canal = MethodChannel('hawiya/capture');
  static const _flux = EventChannel('hawiya/capture/flux');

  /// Analyses en direct ; les erreurs natives arrivent comme [ErreurCapture].
  static final Stream<Analyse> analyses =
      _flux.receiveBroadcastStream().map((evenement) {
    final m = evenement as Map<Object?, Object?>;
    if (m['type'] == 'erreur') throw ErreurCapture(m['message'] as String);
    return Analyse.depuisMap(m);
  });

  static Future<bool> demanderPermission() async =>
      await _canal.invokeMethod<bool>('permission') ?? false;

  /// Démarre la caméra et renvoie le diagnostic du téléphone.
  static Future<Map<String, Object?>> demarrer() async {
    final infos = await _canal.invokeMapMethod<String, Object?>('demarrer');
    return infos ?? {};
  }

  static Future<Map<String, Object?>> infos() async =>
      await _canal.invokeMapMethod<String, Object?>('infos') ?? {};

  static Future<void> arreter() => _canal.invokeMethod('arreter');

  static Future<void> flash(bool actif) =>
      _canal.invokeMethod('flash', {'actif': actif});

  /// [lineaire] entre 0 (pas de zoom) et 1 (zoom maximal).
  static Future<void> zoom(double lineaire) =>
      _canal.invokeMethod('zoom', {'lineaire': lineaire});

  /// Mise au point sur un point de l'aperçu (coordonnées 0..1).
  static Future<void> mettreAuPoint(Offset point) =>
      _canal.invokeMethod('mettreAuPoint', {'x': point.dx, 'y': point.dy});
}
