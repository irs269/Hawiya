import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:path_provider/path_provider.dart';

import 'appareil.dart';
import 'chiffrement.dart';
import 'coffre.dart';
import 'file_attente.dart';
import 'identifiants.dart';

/// Tout ce qu'il faut pour travailler hors ligne, créé une fois au démarrage
/// (et construit à la main dans les tests, avec un coffre en mémoire).
class ServicesHorsLigne {
  ServicesHorsLigne({required this.file, required this.identifiants, required this.appareil, required this.reseau});

  final FileAttente file;
  final IdentifiantsHorsLigne identifiants;
  final IdentiteAppareil appareil;

  /// Vrai quand le téléphone a un réseau (Wi-Fi, données mobiles…). Le serveur
  /// peut rester injoignable : seul l'envoi le dira.
  final Stream<bool> reseau;

  static Future<ServicesHorsLigne> initialiser() async {
    const coffre = CoffreSecurise();
    final dossierApp = await getApplicationSupportDirectory(); // privé à l'application
    final dossier = Directory('${dossierApp.path}/file_attente');
    return ServicesHorsLigne(
      file: FileAttenteChiffree(dossier, await Chiffreur.depuisCoffre(coffre)),
      identifiants: IdentifiantsHorsLigne(coffre),
      appareil: IdentiteAppareil(coffre),
      reseau: Connectivity()
          .onConnectivityChanged
          .map((etats) => etats.any((e) => e != ConnectivityResult.none))
          .distinct(),
    );
  }
}
