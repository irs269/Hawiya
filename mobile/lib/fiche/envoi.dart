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
class EnvoiEnregistrement {
  EnvoiEnregistrement({required this.api, required this.fiche, required this.doigts});

  final ClientApi api;
  final BrouillonFiche fiche;
  final List<DoigtEnvoi> doigts;

  EtapeEnvoi etape = EtapeEnvoi.controle;
  ControleDoublon? controle;
  Citoyen? citoyen;
  bool _validationSuperviseur = false;

  bool get validationSuperviseur => _validationSuperviseur;

  /// Un superviseur a vérifié le doublon possible : on peut poursuivre.
  /// (Le serveur refuse si le compte connecté n'est pas superviseur.)
  void validerParSuperviseur() => _validationSuperviseur = true;

  static const libelles = {
    EtapeEnvoi.controle: 'Contrôle anti-doublon…',
    EtapeEnvoi.creation: 'Création de la fiche…',
    EtapeEnvoi.medias: 'Envoi de la photo et de la signature…',
    EtapeEnvoi.empreintes: 'Enregistrement des empreintes…',
    EtapeEnvoi.termine: 'Terminé',
  };

  /// `progression` est appelé au début de chaque étape (affichage).
  Future<IssueEnvoi> continuer({void Function(EtapeEnvoi)? progression}) async {
    while (etape != EtapeEnvoi.termine) {
      progression?.call(etape);
      switch (etape) {
        case EtapeEnvoi.controle:
          // Déjà contrôlé et validé par un superviseur : pas de nouveau contrôle.
          if (controle == null || !_validationSuperviseur) {
            controle = await api.controlerDoublon(doigts);
          }
          final issue = _bloquage(controle!);
          if (issue != null) return issue;
          etape = EtapeEnvoi.creation;
        case EtapeEnvoi.creation:
          citoyen = await api.creerCitoyen(fiche.versJson());
          etape = EtapeEnvoi.medias;
        case EtapeEnvoi.medias:
          await api.envoyerMedias(citoyen!.numero, photo: fiche.photo, signature: fiche.signature);
          etape = EtapeEnvoi.empreintes;
        case EtapeEnvoi.empreintes:
          final r = await api.enregistrerEmpreintes(
            citoyen!.numero,
            doigts,
            validationSuperviseur: _validationSuperviseur,
          );
          if (!r.enregistre) {
            // Rare : une fiche ressemblante a été enregistrée entre-temps. La
            // fiche existe déjà ; on reste sur cette étape (validation possible).
            controle = r.controle;
            return _bloquage(r.controle) ?? IssueEnvoi.doublonPossible;
          }
          etape = EtapeEnvoi.termine;
        case EtapeEnvoi.termine:
          break;
      }
    }
    progression?.call(etape);
    return IssueEnvoi.termine;
  }

  IssueEnvoi? _bloquage(ControleDoublon c) => switch (c.verdict) {
        VerdictDoublon.doublonCertain => IssueEnvoi.doublonCertain,
        VerdictDoublon.doublonPossible when !_validationSuperviseur => IssueEnvoi.doublonPossible,
        _ => null,
      };
}
