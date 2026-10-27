import 'package:flutter/material.dart';

import '../api/client_api.dart';
import '../capture/ecran_capture.dart';
import '../fiche/ecran_nouvelle_fiche.dart';
import '../theme/couleurs.dart';
import 'communs.dart';
import 'ecran_enregistrement.dart';
import 'ecran_identification.dart';

/// Accueil de l'agent connecté : les deux parcours, et le test de capture.
class EcranAccueil extends StatelessWidget {
  const EcranAccueil({super.key, required this.api});

  final ClientApi api;

  void _ouvrir(BuildContext context, Widget ecran) =>
      Navigator.push(context, MaterialPageRoute<void>(builder: (_) => ecran));

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: barreHawiya('Hawiya', actions: [
          IconButton(
            tooltip: 'Se déconnecter',
            icon: const Icon(Icons.logout),
            onPressed: () {
              api.deconnexion();
              Navigator.pop(context);
            },
          ),
        ]),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          children: [
            _Tuile(
              icone: Icons.person_add_alt_1_outlined,
              titre: 'Enregistrer une personne',
              texte: 'Identité, domicile, photo, signature et 10 empreintes.',
              onTap: () => _ouvrir(context, EcranNouvelleFiche(api: api)),
            ),
            const SizedBox(height: 12),
            _Tuile(
              icone: Icons.fingerprint,
              titre: 'Identifier une personne',
              texte: 'Scanner une main et retrouver la fiche.',
              onTap: () => _ouvrir(context, EcranIdentification(api: api)),
            ),
            const SizedBox(height: 12),
            _Tuile(
              icone: Icons.how_to_reg_outlined,
              titre: "Compléter les empreintes d'une fiche",
              texte: 'Ajouter ou refaire les empreintes d\'une fiche existante.',
              onTap: () => _ouvrir(context, EcranEnregistrement(api: api)),
            ),
            const SizedBox(height: 12),
            _Tuile(
              icone: Icons.bug_report_outlined,
              titre: 'Test de capture (débogage)',
              texte: 'Capture seule, images gardées pour évaluation.',
              discret: true,
              onTap: () => _ouvrir(context, const EcranCapture()),
            ),
            const PiedPrototype(),
          ],
        ),
      );
}

class _Tuile extends StatelessWidget {
  const _Tuile({required this.icone, required this.titre, required this.texte, required this.onTap, this.discret = false});

  final IconData icone;
  final String titre;
  final String texte;
  final VoidCallback onTap;
  final bool discret;

  @override
  Widget build(BuildContext context) => Material(
        color: discret ? Colors.white.withValues(alpha: 0.6) : Colors.white,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Row(children: [
              Icon(icone, size: 36, color: discret ? Colors.black45 : Couleurs.vertProfond),
              const SizedBox(width: 16),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(titre, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: Couleurs.texte)),
                  const SizedBox(height: 2),
                  Text(texte, style: const TextStyle(color: Colors.black54)),
                ]),
              ),
              const Icon(Icons.chevron_right, color: Colors.black38),
            ]),
          ),
        ),
      );
}
