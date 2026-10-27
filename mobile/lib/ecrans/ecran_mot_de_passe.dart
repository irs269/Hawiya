import 'package:flutter/material.dart';

import '../api/client_api.dart';
import 'communs.dart';

/// Règles du mot de passe, identiques à celles du serveur (app/securite.py).
String? problemeMotDePasse(String nouveau, String matricule, {String? ancien}) {
  if (nouveau.length < 10) return 'Au moins 10 caractères';
  if (nouveau.toLowerCase().contains(matricule.trim().toLowerCase())) return 'Ne doit pas contenir le matricule';
  if (nouveau.split('').toSet().length < 4) return 'Trop simple';
  if (ancien != null && nouveau == ancien) return "Doit être différent de l'actuel";
  return null;
}

/// Changement de mot de passe. `obligatoire` : après un mot de passe
/// provisoire (création du compte, réinitialisation) ; le mot de passe actuel
/// est alors déjà connu. Renvoie le nouveau mot de passe (Navigator.pop), ou null.
class EcranMotDePasse extends StatefulWidget {
  const EcranMotDePasse({super.key, required this.api, required this.matricule, this.ancien, this.obligatoire = false});

  final ClientApi api;
  final String matricule;
  final String? ancien;
  final bool obligatoire;

  @override
  State<EcranMotDePasse> createState() => _EcranMotDePasseState();
}

class _EcranMotDePasseState extends State<EcranMotDePasse> {
  final _ancien = TextEditingController();
  final _nouveau = TextEditingController();
  final _confirmation = TextEditingController();
  bool _enCours = false;
  bool _essai = false;
  String? _erreur;

  @override
  void dispose() {
    _ancien.dispose();
    _nouveau.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  String get _ancienMotDePasse => widget.ancien ?? _ancien.text;

  String? get _problemeNouveau => problemeMotDePasse(_nouveau.text, widget.matricule, ancien: _ancienMotDePasse);
  String? get _problemeConfirmation => _confirmation.text == _nouveau.text ? null : 'Les deux saisies diffèrent';

  Future<void> _valider() async {
    setState(() {
      _essai = true;
      _erreur = null;
    });
    if (_problemeNouveau != null || _problemeConfirmation != null || _ancienMotDePasse.isEmpty) return;
    setState(() => _enCours = true);
    try {
      await widget.api.changerMotDePasse(_ancienMotDePasse, _nouveau.text);
      if (mounted) Navigator.pop(context, _nouveau.text);
    } on ErreurApi catch (e) {
      setState(() => _erreur = e.message);
    } finally {
      if (mounted) setState(() => _enCours = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: barreHawiya(widget.obligatoire ? 'Nouveau mot de passe' : 'Changer mon mot de passe'),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          children: [
            if (widget.obligatoire)
              const Padding(
                padding: EdgeInsets.only(bottom: 16),
                child: Text(
                  'Votre mot de passe est provisoire. Choisissez-en un nouveau, connu de vous seul, '
                  'avant de continuer.',
                ),
              ),
            if (widget.ancien == null) ...[
              TextField(
                controller: _ancien,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: 'Mot de passe actuel',
                  errorText: _essai && _ancien.text.isEmpty ? 'Obligatoire' : null,
                ),
              ),
              const SizedBox(height: 12),
            ],
            TextField(
              controller: _nouveau,
              obscureText: true,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: 'Nouveau mot de passe',
                helperText: '10 caractères au moins, sans le matricule',
                errorText: _essai ? _problemeNouveau : null,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _confirmation,
              obscureText: true,
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _valider(),
              decoration: InputDecoration(
                labelText: 'Confirmer le nouveau mot de passe',
                errorText: _essai ? _problemeConfirmation : null,
              ),
            ),
            if (_erreur != null) ...[
              const SizedBox(height: 12),
              Text(_erreur!, style: const TextStyle(color: Colors.red)),
            ],
            const SizedBox(height: 20),
            BoutonPrincipal(texte: 'Enregistrer le mot de passe', icone: Icons.lock_reset, enCours: _enCours, onPressed: _valider),
            const PiedPrototype(),
          ],
        ),
      );
}
