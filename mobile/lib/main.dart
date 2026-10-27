import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'ecrans/ecran_connexion.dart';
import 'theme/theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  runApp(const HawiyaApp());
}

class HawiyaApp extends StatelessWidget {
  const HawiyaApp({super.key});

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
      home: const EcranConnexion(),
    );
  }
}
