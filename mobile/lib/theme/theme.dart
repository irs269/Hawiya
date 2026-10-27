import 'package:flutter/material.dart';

import 'couleurs.dart';

/// Thème Hawiya (CLAUDE.md, section Design) : fond ivoire, vert profond,
/// accent doré ; titres en Fraunces, texte en Figtree ; boutons ≥ 44 px.
ThemeData themeHawiya() {
  const titre = TextStyle(fontFamily: 'Fraunces', fontWeight: FontWeight.w600, color: Couleurs.texte);
  final base = ThemeData(
    fontFamily: 'Figtree',
    colorScheme: ColorScheme.fromSeed(
      seedColor: Couleurs.vertProfond,
      primary: Couleurs.vertProfond,
      secondary: Couleurs.dore,
      surface: Couleurs.ivoire,
    ),
    scaffoldBackgroundColor: Couleurs.ivoire,
  );
  return base.copyWith(
    textTheme: base.textTheme.copyWith(
      headlineMedium: titre.copyWith(fontSize: 28),
      headlineSmall: titre.copyWith(fontSize: 24),
      titleLarge: titre.copyWith(fontSize: 20),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: Couleurs.ivoire,
      foregroundColor: Couleurs.texte,
      titleTextStyle: TextStyle(fontFamily: 'Fraunces', fontWeight: FontWeight.w600, fontSize: 20, color: Couleurs.texte),
    ),
    inputDecorationTheme: const InputDecorationTheme(
      border: OutlineInputBorder(),
      filled: true,
      fillColor: Colors.white,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(minimumSize: const Size(44, 52), backgroundColor: Couleurs.vertProfond),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(minimumSize: const Size(44, 52), foregroundColor: Couleurs.vertProfond),
    ),
  );
}
