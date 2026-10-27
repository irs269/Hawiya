import '../api/client_api.dart';
import '../api/modeles.dart';
import 'fiche.dart';

/// Étapes de l'envoi d'un enregistrement, dans l'ordre du CLAUDE.md :
/// contrôle anti-doublon AVANT d'attribuer un numéro, puis création de la
/// fiche, photo et signature, empreintes.
enum EtapeEnvoi { controle, creation, medias, empreintes, termine }

/// Où l'envoi s'est arrêté (hors erreur réseau, qui lève une ErreurApi).
enum IssueEnvoi { termine, doublonCertain, doublonPossible }

/// Enchaîne les appels au serveur. En cas d'erreur (réseau coupé…), l'état est
/// conservé : `continuer()` reprend à l'étape qui a échoué, SANS recréer la
/// fiche si elle existe déjà (pas de doublon de numéro).
///
/// L'état (étape, numéro, contrôle, validation) peut être restauré depuis la
/// file d'attente hors ligne, et `apresEtape` permet de le sauvegarder après
/// chaque étape réussie (reprise exacte même après un arrêt de l'application).
class EnvoiEnregistrement {
  EnvoiEnregistrement({
    required this.api,
    required this.fiche,
    required this.doigts,
    this.etape = EtapeEnvoi.controle,
    this.numero,
    this.controle,
    this.validationSuperviseur = false,
  });

  final ClientApi api;
  final BrouillonFiche fiche;
  final List<DoigtEnvoi> doigts;

  EtapeEnvoi etape;
  ControleDoublon? controle;

  /// Numéro attribué par le serveur (dès que la fiche est créée).
  String? numero;

  /// Fiche renvoyée par le serveur (seulement si créée pendant cet envoi).
  Citoyen? citoyen;
  /// Un superviseur a validé un doublon possible (le serveur vérifie son rôle).
  bool validationSuperviseur;

  /// Un superviseur a vérifié le doublon possible : on peut poursuivre.
  /// (Le serveur refuse si le compte connecté n'est pas superviseur.)
  void validerParSuperviseur() => validationSuperviseur = true;

  static const libelles = {
    EtapeEnvoi.controle: 'Contrôle anti-doublon…',
    EtapeEnvoi.creation: 'Création de la fiche…',
    EtapeEnvoi.medias: 'Envoi de la photo et de la signature…',
    EtapeEnvoi.empreintes: 'Enregistrement des empreintes…',
    EtapeEnvoi.termine: 'Terminé',
  };

  /// `progression` est appelé au début de chaque étape (affichage) ;
  /// `apresEtape` après chaque étape réussie (sauvegarde).
  Future<IssueEnvoi> continuer({
    void Function(EtapeEnvoi)? progression,
    Future<void> Function()? apresEtape,
  }) async {
    while (etape != EtapeEnvoi.termine) {
      progression?.call(etape);
      switch (etape) {
        case EtapeEnvoi.controle:
          // Déjà contrôlé et validé par un superviseur : pas de nouveau contrôle.
          if (controle == null || !validationSuperviseur) {
            controle = await api.controlerDoublon(doigts);
          }
          final issue = _bloquage(controle!);
          if (issue != null) {
            await apresEtape?.call();
            return issue;
          }
          etape = EtapeEnvoi.creation;
        case EtapeEnvoi.creation:
          citoyen = await api.creerCitoyen(fiche.versJson());
          numero = citoyen!.numero;
          etape = EtapeEnvoi.medias;
        case EtapeEnvoi.medias:
          await api.envoyerMedias(numero!, photo: fiche.photo, signature: fiche.signature);
          etape = EtapeEnvoi.empreintes;
        case EtapeEnvoi.empreintes:
          final r = await api.enregistrerEmpreintes(numero!, doigts, validationSuperviseur: validationSuperviseur);
          if (!r.enregistre) {
            // Rare : une fiche ressemblante a été enregistrée entre-temps. La
            // fiche existe déjà ; on reste sur cette étape (validation possible).
            controle = r.controle;
            await apresEtape?.call();
            return _bloquage(r.controle) ?? IssueEnvoi.doublonPossible;
          }
          etape = EtapeEnvoi.termine;
        case EtapeEnvoi.termine:
          break;
      }
      await apresEtape?.call();
    }
    progression?.call(etape);
    return IssueEnvoi.termine;
  }

  IssueEnvoi? _bloquage(ControleDoublon c) => switch (c.verdict) {
        VerdictDoublon.doublonCertain => IssueEnvoi.doublonCertain,
        VerdictDoublon.doublonPossible when !validationSuperviseur => IssueEnvoi.doublonPossible,
        _ => null,
      };
}
