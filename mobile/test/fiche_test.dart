// Validations de la fiche (données FICTIVES).
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hawiya/fiche/fiche.dart';

/// Petite image PNG valide (4×4 pixels dorés), à la place d'une vraie photo.
final imageFictive = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAIAAAAmkwkpAAAAEElEQVR4nGM42SUNRwzEcQBd8hbh1nD6SQAAAABJRU5ErkJggg==');

/// Fiche fictive complète et valide.
BrouillonFiche ficheComplete() => BrouillonFiche()
  ..nom = 'MSA'
  ..prenoms = 'Ahmed Nassur'
  ..sexe = 'M'
  ..dateNaissance = DateTime(1990, 5, 14)
  ..lieuNaissance = 'Moroni'
  ..numeroActeNaissance = 'FICTIF-1990-0001'
  ..telephone = '321 00 00'
  ..ile = 'Ngazidja'
  ..ville = 'Moroni'
  ..quartier = 'Magoudjou'
  ..adresse = 'Rue fictive n° 1'
  ..taille = '172'
  ..couleurYeux = 'marron'
  ..couleurCheveux = 'noirs'
  ..photo = imageFictive
  ..signature = imageFictive;

void main() {
  group('Téléphone (mêmes règles que le serveur)', () {
    for (final (saisie, attendu) in [
      ('+269 321 00 00', '+2693210000'),
      ('321-00-00', '+2693210000'),
      ('00269 3210000', '+2693210000'),
      ('', null),
      ('   ', null),
    ]) {
      test('« $saisie »', () => expect(normaliserTelephone(saisie), attendu));
    }

    test('valide ou non', () {
      expect(validerTelephone('321 00 00'), isNull);
      expect(validerTelephone(''), isNull); // facultatif
      expect(validerTelephone('12345'), isNotNull);
      expect(validerTelephone('+33 6 12 34 56 78'), isNotNull);
    });
  });

  test('date de naissance', () {
    final aujourdhui = DateTime(2026, 10, 27);
    expect(validerDateNaissance(null), 'Date obligatoire');
    expect(validerDateNaissance(DateTime(2026, 10, 27), aujourdhui: aujourdhui), isNull);
    expect(validerDateNaissance(DateTime(2026, 10, 28), aujourdhui: aujourdhui), contains('futur'));
    expect(validerDateNaissance(DateTime(1899, 12, 31), aujourdhui: aujourdhui), contains('ancienne'));
  });

  test('taille', () {
    expect(validerTaille('172'), isNull);
    expect(validerTaille('49'), isNotNull);
    expect(validerTaille('251'), isNotNull);
    expect(validerTaille('1m72'), isNotNull);
  });

  test('champs obligatoires et longueur', () {
    expect(obligatoire('  '), 'Champ obligatoire');
    expect(obligatoire('a' * 101), contains('100'));
    expect(obligatoire('Moroni'), isNull);
  });

  test('fiche complète : aucune erreur', () {
    final f = ficheComplete();
    expect(erreursIdentite(f), isEmpty);
    expect(erreursDomicile(f), isEmpty);
    expect(erreursMedias(f), isEmpty);
  });

  test('fiche vide : chaque champ obligatoire est signalé', () {
    final f = BrouillonFiche();
    expect(erreursIdentite(f).keys,
        containsAll(['nom', 'prenoms', 'sexe', 'date_naissance', 'lieu_naissance', 'numero_acte_naissance']));
    expect(erreursIdentite(f).containsKey('nationalite'), isFalse); // « Comorienne » par défaut
    expect(erreursDomicile(f).keys.length, 7);
    expect(erreursMedias(f).keys, ['photo', 'signature']);
  });

  test('corps envoyé au serveur', () {
    final json = (ficheComplete()..nom = '  MSA ').versJson();
    expect(json['nom'], 'MSA');
    expect(json['date_naissance'], '1990-05-14');
    expect(json['telephone'], '+2693210000');
    expect(json['taille_cm'], 172);
    expect(json['nationalite'], 'Comorienne');
    expect(json.containsKey('photo'), isFalse); // envoyée à part
  });
}
