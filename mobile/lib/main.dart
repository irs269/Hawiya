import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'capture/ecran_capture.dart';
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
      // Étape 3b : l'application ne contient que la capture des empreintes.
      // La navigation complète arrive en phase 2.
      home: const EcranCapture(),
    );
  }
}
