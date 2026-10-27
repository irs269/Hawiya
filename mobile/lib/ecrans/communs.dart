import 'package:flutter/material.dart';

import '../api/modeles.dart';
import '../theme/couleurs.dart';

/// Mention obligatoire : Hawiya n'est pas un système officiel de l'État.
const mentionPrototype = 'Prototype de démonstration · système non officiel · données fictives';

String formaterDate(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

/// Bouton principal (au moins 44 px de haut, voir CLAUDE.md : 52 px ici).
class BoutonPrincipal extends StatelessWidget {
  const BoutonPrincipal({super.key, required this.texte, required this.onPressed, this.icone, this.enCours = false});

  final String texte;
  final VoidCallback? onPressed;
  final IconData? icone;
  final bool enCours;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 52,
        width: double.infinity,
        child: FilledButton.icon(
          style: FilledButton.styleFrom(backgroundColor: Couleurs.vertProfond),
          onPressed: enCours ? null : onPressed,
          icon: enCours
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : Icon(icone ?? Icons.arrow_forward),
          label: Text(texte),
        ),
      );
}

class BoutonSecondaire extends StatelessWidget {
  const BoutonSecondaire({super.key, required this.texte, required this.onPressed, this.icone});

  final String texte;
  final VoidCallback? onPressed;
  final IconData? icone;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 52,
        width: double.infinity,
        child: OutlinedButton.icon(
          style: OutlinedButton.styleFrom(foregroundColor: Couleurs.vertProfond),
          onPressed: onPressed,
          icon: Icon(icone ?? Icons.refresh),
          label: Text(texte),
        ),
      );
}

/// Encadré coloré avec icône : verdicts, erreurs, consignes.
class Encadre extends StatelessWidget {
  const Encadre({super.key, required this.titre, this.texte, required this.couleur, required this.icone});

  final String titre;
  final String? texte;
  final Color couleur;
  final IconData icone;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: couleur.withValues(alpha: 0.10),
          border: Border.all(color: couleur.withValues(alpha: 0.5)),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icone, color: couleur, size: 28),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(titre, style: TextStyle(color: couleur, fontSize: 18, fontWeight: FontWeight.w700)),
              if (texte != null && texte!.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(texte!, style: const TextStyle(color: Couleurs.texte)),
              ],
            ]),
          ),
        ]),
      );
}

/// Fiche d'un citoyen (lecture seule).
class FicheCitoyen extends StatelessWidget {
  const FicheCitoyen({super.key, required this.citoyen});

  final Citoyen citoyen;

  @override
  Widget build(BuildContext context) {
    final c = citoyen;
    final lignes = <(String, String)>[
      ('Sexe', c.sexe == 'F' ? 'Féminin' : 'Masculin'),
      ('Naissance', '${formaterDate(c.dateNaissance)} à ${c.lieuNaissance}'),
      ('Nationalité', c.nationalite),
      ('Domicile', '${c.quartier}, ${c.ville} (${c.ile})'),
      if (c.telephone != null) ('Téléphone', c.telephone!),
      if (c.tailleCm != null) ('Taille', '${c.tailleCm} cm'),
      if (c.enregistreLe != null) ('Enregistré le', formaterDate(c.enregistreLe!.toLocal())),
    ];
    return Card(
      color: Colors.white,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${c.nom.toUpperCase()} ${c.prenoms}',
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: Couleurs.texte)),
          const SizedBox(height: 2),
          Text(c.numero,
              style: const TextStyle(fontSize: 16, color: Couleurs.vertProfond, fontWeight: FontWeight.w600)),
          const Divider(height: 24),
          for (final (libelle, valeur) in lignes)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SizedBox(width: 110, child: Text(libelle, style: const TextStyle(color: Colors.black54))),
                Expanded(child: Text(valeur, style: const TextStyle(color: Couleurs.texte))),
              ]),
            ),
        ]),
      ),
    );
  }
}

/// Barre d'en-tête claire commune aux écrans hors caméra.
AppBar barreHawiya(String titre, {List<Widget>? actions}) => AppBar(
      backgroundColor: Couleurs.ivoire,
      foregroundColor: Couleurs.texte,
      title: Text(titre),
      actions: actions,
    );

/// Mention « prototype » en bas des écrans.
class PiedPrototype extends StatelessWidget {
  const PiedPrototype({super.key});

  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.only(top: 24),
        child: Text(mentionPrototype,
            textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: Colors.black45)),
      );
}
