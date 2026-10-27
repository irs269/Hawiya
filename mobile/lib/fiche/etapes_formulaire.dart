import 'package:flutter/material.dart';

import '../ecrans/communs.dart';
import 'fiche.dart';

/// Champ texte relié au brouillon (valeur initiale + mise à jour à la frappe).
/// `erreur` n'est affichée qu'après un essai de passage à l'étape suivante.
class ChampTexte extends StatelessWidget {
  const ChampTexte({
    super.key,
    required this.libelle,
    required this.valeur,
    required this.onChanged,
    this.erreur,
    this.aide,
    this.clavier,
    this.majuscules = TextCapitalization.words,
  });

  final String libelle;
  final String valeur;
  final ValueChanged<String> onChanged;
  final String? erreur;
  final String? aide;
  final TextInputType? clavier;
  final TextCapitalization majuscules;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: TextFormField(
          initialValue: valeur,
          onChanged: onChanged,
          keyboardType: clavier,
          textCapitalization: majuscules,
          textInputAction: TextInputAction.next,
          decoration: InputDecoration(labelText: libelle, errorText: erreur, helperText: aide),
        ),
      );
}

/// Liste déroulante sur un référentiel (code → libellé).
class ChampChoix extends StatelessWidget {
  const ChampChoix({
    super.key,
    required this.libelle,
    required this.choix,
    required this.valeur,
    required this.onChanged,
    this.erreur,
  });

  final String libelle;
  final Map<String, String> choix;
  final String? valeur;
  final ValueChanged<String?> onChanged;
  final String? erreur;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: DropdownButtonFormField<String>(
          initialValue: valeur,
          items: [for (final e in choix.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
          onChanged: onChanged,
          decoration: InputDecoration(labelText: libelle, errorText: erreur),
        ),
      );
}

/// Choix exclusif court (sexe, île) en boutons segmentés.
class ChampSegments extends StatelessWidget {
  const ChampSegments({
    super.key,
    required this.libelle,
    required this.choix,
    required this.valeur,
    required this.onChanged,
    this.erreur,
  });

  final String libelle;
  final Map<String, String> choix;
  final String? valeur;
  final ValueChanged<String> onChanged;
  final String? erreur;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(libelle, style: const TextStyle(color: Colors.black54)),
          const SizedBox(height: 6),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<String>(
              emptySelectionAllowed: true,
              showSelectedIcon: false,
              segments: [for (final e in choix.entries) ButtonSegment(value: e.key, label: Text(e.value))],
              selected: {?valeur},
              onSelectionChanged: (s) {
                if (s.isNotEmpty) onChanged(s.first);
              },
            ),
          ),
          if (erreur != null)
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 12),
              child: Text(erreur!, style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 12)),
            ),
        ]),
      );
}

/// Étape 1 : identité.
class EtapeIdentite extends StatelessWidget {
  const EtapeIdentite({super.key, required this.fiche, required this.erreurs, required this.onChanged});

  final BrouillonFiche fiche;
  final Map<String, String> erreurs;
  final VoidCallback onChanged;

  Future<void> _choisirDate(BuildContext context) async {
    final aujourdhui = DateTime.now();
    final choisie = await showDatePicker(
      context: context,
      initialDate: fiche.dateNaissance ?? DateTime(aujourdhui.year - 30),
      firstDate: dateNaissanceMin,
      lastDate: aujourdhui,
      initialEntryMode: DatePickerEntryMode.input, // saisie au clavier, plus rapide
      helpText: 'Date de naissance',
    );
    if (choisie != null) {
      fiche.dateNaissance = choisie;
      onChanged();
    }
  }

  @override
  Widget build(BuildContext context) {
    void maj(void Function() action) {
      action();
      onChanged();
    }

    return Column(children: [
      ChampTexte(libelle: 'Nom', valeur: fiche.nom, erreur: erreurs['nom'], majuscules: TextCapitalization.characters,
          onChanged: (v) => maj(() => fiche.nom = v)),
      ChampTexte(libelle: 'Prénom(s)', valeur: fiche.prenoms, erreur: erreurs['prenoms'],
          onChanged: (v) => maj(() => fiche.prenoms = v)),
      ChampSegments(libelle: 'Sexe', choix: sexes, valeur: fiche.sexe, erreur: erreurs['sexe'],
          onChanged: (v) => maj(() => fiche.sexe = v)),
      Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: InkWell(
          onTap: () => _choisirDate(context),
          child: InputDecorator(
            decoration: InputDecoration(
              labelText: 'Date de naissance',
              errorText: erreurs['date_naissance'],
              suffixIcon: const Icon(Icons.calendar_today_outlined),
            ),
            child: Text(fiche.dateNaissance == null ? 'Choisir…' : formaterDate(fiche.dateNaissance!)),
          ),
        ),
      ),
      ChampTexte(libelle: 'Lieu de naissance', valeur: fiche.lieuNaissance, erreur: erreurs['lieu_naissance'],
          onChanged: (v) => maj(() => fiche.lieuNaissance = v)),
      ChampTexte(libelle: 'Nationalité', valeur: fiche.nationalite, erreur: erreurs['nationalite'],
          onChanged: (v) => maj(() => fiche.nationalite = v)),
      ChampTexte(libelle: "Numéro d'acte de naissance", valeur: fiche.numeroActeNaissance,
          erreur: erreurs['numero_acte_naissance'], majuscules: TextCapitalization.characters,
          onChanged: (v) => maj(() => fiche.numeroActeNaissance = v)),
      ChampTexte(libelle: 'Téléphone (facultatif)', valeur: fiche.telephone, erreur: erreurs['telephone'],
          aide: 'Ex. 321 00 00 ou +269 321 00 00', clavier: TextInputType.phone,
          onChanged: (v) => maj(() => fiche.telephone = v)),
    ]);
  }
}

/// Étape 2 : domicile et signalement.
class EtapeDomicile extends StatelessWidget {
  const EtapeDomicile({super.key, required this.fiche, required this.erreurs, required this.onChanged});

  final BrouillonFiche fiche;
  final Map<String, String> erreurs;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    void maj(void Function() action) {
      action();
      onChanged();
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Domicile', style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 10),
      ChampSegments(libelle: 'Île', choix: iles, valeur: fiche.ile, erreur: erreurs['ile'],
          onChanged: (v) => maj(() => fiche.ile = v)),
      ChampTexte(libelle: 'Ville ou village', valeur: fiche.ville, erreur: erreurs['ville'],
          onChanged: (v) => maj(() => fiche.ville = v)),
      ChampTexte(libelle: 'Quartier', valeur: fiche.quartier, erreur: erreurs['quartier'],
          onChanged: (v) => maj(() => fiche.quartier = v)),
      ChampTexte(libelle: 'Adresse', valeur: fiche.adresse, erreur: erreurs['adresse'],
          majuscules: TextCapitalization.sentences, onChanged: (v) => maj(() => fiche.adresse = v)),
      const SizedBox(height: 6),
      Text('Signalement', style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 10),
      ChampTexte(libelle: 'Taille (cm)', valeur: fiche.taille, erreur: erreurs['taille_cm'],
          clavier: TextInputType.number, onChanged: (v) => maj(() => fiche.taille = v)),
      ChampChoix(libelle: 'Couleur des yeux', choix: couleursYeux, valeur: fiche.couleurYeux,
          erreur: erreurs['couleur_yeux'], onChanged: (v) => maj(() => fiche.couleurYeux = v)),
      ChampChoix(libelle: 'Couleur des cheveux', choix: couleursCheveux, valeur: fiche.couleurCheveux,
          erreur: erreurs['couleur_cheveux'], onChanged: (v) => maj(() => fiche.couleurCheveux = v)),
    ]);
  }
}
