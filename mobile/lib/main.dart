import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'ecrans/ecran_connexion.dart';
import 'theme/couleurs.dart';

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
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Couleurs.vertProfond,
          primary: Couleurs.vertProfond,
          secondary: Couleurs.dore,
          surface: Couleurs.ivoire,
        ),
        scaffoldBackgroundColor: Couleurs.ivoire,
      ),
      // Connexion de l'agent → accueil (identification, enregistrement des
      // empreintes, test de capture). Les formulaires de fiche : phase 2.
      home: const EcranConnexion(),
    );
  }
}
