import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'ecrans/ecran_connexion.dart';
import 'hors_ligne/services.dart';
import 'theme/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  // Clé de chiffrement (coffre Android), file d'attente, état du réseau.
  final services = await ServicesHorsLigne.initialiser();
  runApp(HawiyaApp(services: services));
}

class HawiyaApp extends StatelessWidget {
  const HawiyaApp({super.key, required this.services});

  final ServicesHorsLigne services;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Hawiya',
      debugShowCheckedModeBanner: false,
      theme: themeHawiya(),
      // Interface en français (calendrier, boutons système…).
      locale: const Locale('fr'),
      supportedLocales: const [Locale('fr')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      // Connexion de l'agent → accueil (enregistrer une personne, identifier,
      // compléter les empreintes d'une fiche, test de capture).
      home: EcranConnexion(services: services),
    );
  }
}
