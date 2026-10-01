import 'package:flutter/services.dart';

/// Mesures de qualité d'un doigt sur l'image d'analyse (calculées en Kotlin).
class MesuresDoigt {
  const MesuresDoigt({
    required this.visible,
    this.nettete = 0,
    this.luminance = 0,
    this.eblouissement = 0,
  });

  /// La zone de l'empreinte est entièrement dans l'image.
  final bool visible;

  /// Variance du Laplacien (contours ; les crêtes sont trop fines à cette résolution).
  final double nettete;

  /// 0..255.
  final double luminance;

  /// Part des pixels éblouis par le flash (0..1).
  final double eblouissement;

  factory MesuresDoigt.depuisMap(Map<Object?, Object?> m) => MesuresDoigt(
        visible: m['visible'] as bool,
        nettete: (m['nettete'] as num?)?.toDouble() ?? 0,
        luminance: (m['luminance'] as num?)?.toDouble() ?? 0,
        eblouissement: (m['eblouissement'] as num?)?.toDouble() ?? 0,
      );
}

/// Une main détectée par MediaPipe (coordonnées normalisées 0..1, image portrait).
class MainDetectee {
  const MainDetectee({
    required this.cote,
    required this.confiance,
    required this.points,
    required this.paume,
    this.etiquetteBrute = '',
    this.produit = 0,
    this.doigts = const [],
    this.profondeurs = const [],
  });

  /// Mesures des 5 doigts (pouce en premier) ; vide si non fournies.
  final List<MesuresDoigt> doigts;

  /// Profondeur relative des 21 points (MediaPipe « z », échelle ≈ largeur de l'image).
  final List<double> profondeurs;

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
      doigts: [
        for (final d in (m['doigts'] as List?) ?? const [])
          MesuresDoigt.depuisMap(d as Map<Object?, Object?>),
      ],
      profondeurs: [
        for (final z in (m['profondeurs'] as List?) ?? const []) (z as num).toDouble(),
      ],
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

/// Découpe pleine résolution d'un bout de doigt (meilleure des 3 photos).
class DecoupeDoigt {
  const DecoupeDoigt({
    required this.doigt,
    required this.iso,
    required this.nom,
    required this.chemin,
    required this.largeur,
    required this.hauteur,
    required this.nettete,
    required this.luminance,
    required this.eblouissement,
    required this.dpiEstime,
    required this.photo,
    this.netteteLaplacien = 0,
    this.acceptee = true,
    this.rafale = 1,
  });

  /// Ancienne mesure (variance du Laplacien), gardée pour comparaison.
  final double netteteLaplacien;

  /// Netteté au-dessus du seuil.
  final bool acceptee;

  /// Rafale d'où vient la découpe (1 = première ; 2-3 = rafales ciblées).
  final int rafale;

  /// 0 = pouce … 4 = auriculaire.
  final int doigt;

  /// Numérotation ISO/IEC 19794 (1 = pouce droit … 10 = auriculaire gauche).
  final int iso;
  final String nom;

  /// Fichier PNG sur le téléphone.
  final String chemin;
  final int largeur;
  final int hauteur;

  /// Netteté des crêtes, 0..1 (énergie dans la bande des crêtes × cohérence).
  final double nettete;
  final double luminance;
  final double eblouissement;

  /// Résolution estimée, en supposant un doigt de 18 mm de large.
  final double dpiEstime;

  /// Numéro de la photo de la rafale retenue (1 à 3).
  final int photo;

  factory DecoupeDoigt.depuisMap(Map<Object?, Object?> m) => DecoupeDoigt(
        doigt: (m['doigt'] as num).toInt(),
        iso: (m['iso'] as num).toInt(),
        nom: m['nom'] as String,
        chemin: m['chemin'] as String,
        largeur: (m['largeur'] as num).toInt(),
        hauteur: (m['hauteur'] as num).toInt(),
        nettete: (m['nettete'] as num).toDouble(),
        luminance: (m['luminance'] as num).toDouble(),
        eblouissement: (m['eblouissement'] as num).toDouble(),
        dpiEstime: (m['dpiEstime'] as num).toDouble(),
        photo: (m['photo'] as num).toInt(),
        netteteLaplacien: (m['netteteLaplacien'] as num?)?.toDouble() ?? 0,
        acceptee: m['acceptee'] as bool? ?? true,
        rafale: (m['rafale'] as num?)?.toInt() ?? 1,
      );
}

/// Résultat d'une rafale.
class ResultatCapture {
  const ResultatCapture({
    required this.succes,
    this.raison,
    this.decoupes = const [],
    this.resolution = '',
    this.dureePhotosMs = 0,
    this.dureeTotaleMs = 0,
    this.dossier,
    this.rafales = 1,
    this.seuilNettete = 0,
  });

  /// Nombre de rafales faites (plus d'une si des doigts étaient flous).
  final int rafales;
  final double seuilNettete;

  final bool succes;
  final String? raison;
  final List<DecoupeDoigt> decoupes;
  final String resolution;
  final int dureePhotosMs;
  final int dureeTotaleMs;
  final String? dossier;

  factory ResultatCapture.depuisMap(Map<Object?, Object?> m) => ResultatCapture(
        succes: m['succes'] as bool,
        raison: m['raison'] as String?,
        decoupes: [
          for (final d in (m['resultats'] as List?) ?? const [])
            DecoupeDoigt.depuisMap(d as Map<Object?, Object?>),
        ],
        resolution: m['resolution'] as String? ?? '',
        dureePhotosMs: (m['dureePhotosMs'] as num?)?.toInt() ?? 0,
        dureeTotaleMs: (m['dureeTotaleMs'] as num?)?.toInt() ?? 0,
        dossier: m['dossier'] as String?,
        rafales: (m['rafales'] as num?)?.toInt() ?? 1,
        seuilNettete: (m['seuilNettete'] as num?)?.toDouble() ?? 0,
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

  /// Rafale de 3 photos + découpes des [doigts] (0 = pouce … 4 = auriculaire).
  /// [miseAuPoint] : point de l'aperçu (0..1) sur lequel verrouiller la mise au point.
  static Future<ResultatCapture> capturer({
    required String main,
    required List<int> doigts,
    required String session,
    required bool debogage,
    required double seuilNettete,
    Offset? miseAuPoint,
    Map<String, Object?> contexte = const {},
  }) async {
    final reponse = await _canal.invokeMapMethod<Object?, Object?>('capturer', {
      'main': main,
      'doigts': doigts,
      'session': session,
      'debogage': debogage,
      'seuilNettete': seuilNettete,
      // Mesures de pose au déclenchement (JSON de débogage, calibrage des seuils).
      'contexte': contexte,
      if (miseAuPoint != null) 'x': miseAuPoint.dx,
      if (miseAuPoint != null) 'y': miseAuPoint.dy,
    });
    return ResultatCapture.depuisMap(reponse ?? {'succes': false, 'raison': 'Pas de réponse'});
  }

  /// Arrête l'analyse et le flash (écran résultat, inactivité, chauffe).
  static Future<void> pause() => _canal.invokeMethod('pause');

  static Future<void> reprendre() => _canal.invokeMethod('reprendre');

  /// Efface les découpes temporaires (hors mode débogage).
  static Future<void> supprimerTemporaires() => _canal.invokeMethod('supprimerTemporaires');
}
