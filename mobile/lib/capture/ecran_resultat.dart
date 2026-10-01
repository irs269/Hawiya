import 'dart:io';

import 'package:flutter/material.dart';

import '../theme/couleurs.dart';
import 'capture_native.dart';
import 'guidage.dart';

/// Résultat d'une étape : découpes de chaque doigt avec leurs scores.
/// Renvoie « suivant » ou « recommencer » par Navigator.pop.
class EcranResultatEtape extends StatelessWidget {
  const EcranResultatEtape({
    super.key,
    required this.etape,
    required this.resultat,
    required this.numero,
    required this.total,
    required this.debogage,
  });

  final EtapeCapture etape;
  final ResultatCapture resultat;
  final int numero;
  final int total;
  final bool debogage;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Couleurs.ivoire,
      appBar: AppBar(
        backgroundColor: Couleurs.ivoire,
        foregroundColor: Couleurs.texte,
        title: Text('Étape $numero sur $total · résultat'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          Text(etape.titre,
              style: const TextStyle(
                  fontSize: 22, fontWeight: FontWeight.w600, color: Couleurs.texte)),
          const SizedBox(height: 8),
          if (!resultat.succes)
            _Bandeau(
              texte: resultat.raison ?? 'Capture incomplète.',
              couleur: Couleurs.dore,
              icone: Icons.warning_amber_rounded,
            )
          else
            const _Bandeau(
              texte: 'Vérifiez que les crêtes sont visibles sur chaque doigt.',
              couleur: Couleurs.vertProfond,
              icone: Icons.check_circle_outline,
            ),
          const SizedBox(height: 12),
          GrilleDecoupes(decoupes: resultat.decoupes),
          const SizedBox(height: 12),
          Text(
            'Photos : ${resultat.resolution} · rafale ${resultat.dureePhotosMs} ms · '
            'total ${resultat.dureeTotaleMs} ms',
            style: const TextStyle(color: Colors.black54, fontSize: 13),
          ),
          if (debogage && resultat.dossier != null) ...[
            const SizedBox(height: 4),
            Text('Enregistré dans : ${resultat.dossier}',
                style: const TextStyle(color: Colors.black54, fontSize: 12)),
          ],
          const SizedBox(height: 20),
          Row(children: [
            Expanded(
              child: SizedBox(
                height: 52,
                child: OutlinedButton(
                  onPressed: () => Navigator.pop(context, 'recommencer'),
                  child: const Text('Recommencer'),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: SizedBox(
                height: 52,
                child: FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: Couleurs.vertProfond),
                  onPressed: resultat.succes ? () => Navigator.pop(context, 'suivant') : null,
                  child: Text(numero < total ? 'Suivant' : 'Terminer'),
                ),
              ),
            ),
          ]),
        ],
      ),
    );
  }
}

/// Fin de session : toutes les découpes, étape par étape.
class EcranFinSession extends StatelessWidget {
  const EcranFinSession({super.key, required this.resultats, required this.debogage});

  final Map<int, ResultatCapture> resultats;
  final bool debogage;

  @override
  Widget build(BuildContext context) {
    final dossier = resultats.values.map((r) => r.dossier).whereType<String>().firstOrNull;
    return Scaffold(
      backgroundColor: Couleurs.ivoire,
      appBar: AppBar(
        backgroundColor: Couleurs.ivoire,
        foregroundColor: Couleurs.texte,
        title: const Text('Session terminée'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          for (final entree in resultats.entries) ...[
            Text(EtapeCapture.sequence[entree.key].titre,
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            GrilleDecoupes(decoupes: entree.value.decoupes),
            const SizedBox(height: 16),
          ],
          Text(
            debogage
                ? 'Mode débogage : les images sont gardées dans $dossier'
                : 'Les découpes seront effacées du téléphone en commençant une nouvelle session.',
            style: const TextStyle(color: Colors.black54, fontSize: 12),
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: 52,
            child: FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Couleurs.vertProfond),
              onPressed: () => Navigator.pop(context),
              child: const Text('Nouvelle session'),
            ),
          ),
        ],
      ),
    );
  }
}

/// Grille des découpes de doigts, avec scores.
class GrilleDecoupes extends StatelessWidget {
  const GrilleDecoupes({super.key, required this.decoupes});

  final List<DecoupeDoigt> decoupes;

  @override
  Widget build(BuildContext context) {
    if (decoupes.isEmpty) {
      return const Text('Aucune découpe.', style: TextStyle(color: Colors.black54));
    }
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        for (final d in decoupes)
          SizedBox(
            width: 160,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    color: Colors.black,
                    height: 200,
                    width: 160,
                    // Toucher = image en plein écran pour voir les crêtes.
                    child: GestureDetector(
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute<void>(builder: (_) => _ImagePleinEcran(decoupe: d)),
                      ),
                      child: Image.file(File(d.chemin), fit: BoxFit.contain),
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Text('${d.nom[0].toUpperCase()}${d.nom.substring(1)} · ISO ${d.iso}',
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                Text(
                  'netteté ${d.nettete.toStringAsFixed(0)} · ≈${d.dpiEstime.toStringAsFixed(0)} dpi\n'
                  '${d.largeur}×${d.hauteur} px · photo ${d.photo}/3',
                  style: const TextStyle(fontSize: 12, color: Colors.black54),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _ImagePleinEcran extends StatelessWidget {
  const _ImagePleinEcran({required this.decoupe});

  final DecoupeDoigt decoupe;

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          title: Text(decoupe.nom),
        ),
        body: InteractiveViewer(
          maxScale: 8,
          child: Center(child: Image.file(File(decoupe.chemin))),
        ),
      );
}

class _Bandeau extends StatelessWidget {
  const _Bandeau({required this.texte, required this.couleur, required this.icone});

  final String texte;
  final Color couleur;
  final IconData icone;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: couleur.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(children: [
          Icon(icone, color: couleur),
          const SizedBox(width: 10),
          Expanded(child: Text(texte, style: TextStyle(color: couleur, fontWeight: FontWeight.w600))),
        ]),
      );
}
