import 'package:flutter/material.dart';

import '../api/client_api.dart';
import '../api/modeles.dart';
import 'services.dart';

/// Demande le mot de passe pour se reconnecter EN LIGNE (nécessaire pour
/// synchroniser). Renvoie vrai si la connexion a réussi.
Future<bool> demanderReconnexion(
  BuildContext context, {
  required ClientApi api,
  required ServicesHorsLigne services,
  required AgentConnecte agent,
}) async {
  final motDePasse = TextEditingController();
  String? erreur;
  var enCours = false;
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, setState) {
        Future<void> valider() async {
          setState(() {
            enCours = true;
            erreur = null;
          });
          try {
            await api.connexion(agent.matricule, motDePasse.text);
            await services.identifiants.memoriser(agent.matricule, motDePasse.text,
                agent: await api.moi(), adresse: api.adresse);
            if (c.mounted) Navigator.pop(c, true);
          } on ErreurApi catch (e) {
            setState(() {
              enCours = false;
              erreur = e.message;
            });
          }
        }

        return AlertDialog(
          title: const Text('Connexion en ligne'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Agent ${agent.matricule} · ${api.adresse}'),
            const SizedBox(height: 12),
            TextField(
              controller: motDePasse,
              obscureText: true,
              autofocus: true,
              decoration: InputDecoration(labelText: 'Mot de passe', errorText: erreur, errorMaxLines: 4),
              onSubmitted: (_) => valider(),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Annuler')),
            FilledButton(onPressed: enCours ? null : valider, child: const Text('Se connecter')),
          ],
        );
      },
    ),
  );
  motDePasse.dispose();
  return ok ?? false;
}
