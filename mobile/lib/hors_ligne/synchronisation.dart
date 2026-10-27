import '../api/client_api.dart';
import '../api/modeles.dart';
import '../fiche/envoi.dart';
import 'file_attente.dart';

/// Résultat de l'envoi d'un élément.
enum IssueSync {
  /// Tout est enregistré sur le serveur ; l'élément est supprimé du téléphone.
  envoye,

  /// Pas de réseau (ou serveur injoignable) : l'élément reste en attente.
  horsLigne,

  /// L'agent doit se reconnecter en ligne (session absente ou expirée).
  reconnexion,

  /// Doublon certain ou possible : l'élément passe « à vérifier ».
  aVerifier,

  /// Refus du serveur (données invalides…) : l'élément passe « en erreur ».
  erreur,
}

class ResultatSync {
  const ResultatSync(this.issue, this.element, {this.citoyen, this.message});

  final IssueSync issue;
  final ElementAttente element;

  /// Fiche créée (seulement si elle l'a été pendant cet envoi).
  final Citoyen? citoyen;
  final String? message;
}

/// Bilan d'une synchronisation de toute la file.
class BilanSync {
  final envoyes = <ElementAttente>[];
  final aVerifier = <ElementAttente>[];
  final erreurs = <ElementAttente>[];

  /// La synchronisation s'est arrêtée : réseau absent ou reconnexion requise.
  IssueSync? arret;

  int get traites => envoyes.length + aVerifier.length + erreurs.length;
}

/// Envoie les enregistrements en attente au serveur, en sauvegardant
/// l'avancement après chaque étape (reprise exacte, jamais de fiche en double).
class Synchroniseur {
  Synchroniseur(this.file, this.api);

  final FileAttente file;
  final ClientApi api;
  bool _enCours = false;

  bool get enCours => _enCours;

  /// Envoie un élément (déjà écrit dans la file).
  Future<ResultatSync> envoyer(ElementAttente e, {void Function(EtapeEnvoi)? progression}) async {
    if (!api.connecte) return ResultatSync(IssueSync.reconnexion, e);
    final envoi = EnvoiEnregistrement(
      api: api,
      fiche: e.fiche,
      doigts: e.doigts,
      etape: e.etape,
      numero: e.numero,
      controle: e.controle,
      validationSuperviseur: e.validationSuperviseur,
    );

    Future<void> sauvegarder() async {
      e
        ..etape = envoi.etape
        ..numero = envoi.numero
        ..controle = envoi.controle;
      await file.enregistrer(e);
    }

    try {
      final issue = await envoi.continuer(progression: progression, apresEtape: sauvegarder);
      if (issue == IssueEnvoi.termine) {
        await file.supprimer(e.id);
        return ResultatSync(IssueSync.envoye, e, citoyen: envoi.citoyen);
      }
      e
        ..statut = StatutAttente.aVerifier
        ..message = envoi.controle?.motif;
      await file.enregistrer(e);
      return ResultatSync(IssueSync.aVerifier, e, message: e.message);
    } on ErreurApi catch (erreur) {
      await sauvegarder(); // garde l'avancement atteint avant l'erreur
      if (erreur.code == null || erreur.code == 503) {
        return ResultatSync(IssueSync.horsLigne, e, message: erreur.message);
      }
      if (erreur.code == 401) return ResultatSync(IssueSync.reconnexion, e, message: erreur.message);
      e
        ..statut = StatutAttente.erreur
        ..message = erreur.message;
      await file.enregistrer(e);
      return ResultatSync(IssueSync.erreur, e, message: erreur.message);
    }
  }

  /// Envoie tous les éléments « en attente » (les « à vérifier » et « en erreur »
  /// attendent une action de l'agent). S'arrête au premier problème de réseau
  /// ou de session.
  Future<BilanSync> synchroniserTout() async {
    final bilan = BilanSync();
    if (_enCours) return bilan;
    _enCours = true;
    try {
      for (final e in await file.lister()) {
        if (e.statut != StatutAttente.enAttente) continue;
        final r = await envoyer(e);
        switch (r.issue) {
          case IssueSync.envoye:
            bilan.envoyes.add(e);
          case IssueSync.aVerifier:
            bilan.aVerifier.add(e);
          case IssueSync.erreur:
            bilan.erreurs.add(e);
          case IssueSync.horsLigne || IssueSync.reconnexion:
            bilan.arret = r.issue;
            return bilan;
        }
      }
      return bilan;
    } finally {
      _enCours = false;
    }
  }

  /// Un superviseur a vérifié le doublon possible : l'élément repart.
  Future<ResultatSync> validerEtEnvoyer(ElementAttente e) async {
    e
      ..validationSuperviseur = true
      ..statut = StatutAttente.enAttente
      ..message = null;
    await file.enregistrer(e);
    return envoyer(e);
  }

  /// Remet un élément « en erreur » en attente (après correction côté serveur…).
  Future<ResultatSync> reessayer(ElementAttente e) async {
    e
      ..statut = StatutAttente.enAttente
      ..message = null;
    await file.enregistrer(e);
    return envoyer(e);
  }
}
