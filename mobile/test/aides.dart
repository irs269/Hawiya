// Outils communs aux tests : services hors ligne en mémoire, agents fictifs.
import 'package:hawiya/api/modeles.dart';
import 'package:hawiya/hors_ligne/appareil.dart';
import 'package:hawiya/hors_ligne/coffre.dart';
import 'package:hawiya/hors_ligne/file_attente.dart';
import 'package:hawiya/hors_ligne/identifiants.dart';
import 'package:hawiya/hors_ligne/services.dart';

const agentFictif = AgentConnecte(matricule: 'AG-0001', nom: 'Agent fictif', role: 'agent');
const superviseurFictif = AgentConnecte(matricule: 'AG-0002', nom: 'Superviseur fictif', role: 'superviseur');

/// Services hors ligne sans disque ni coffre Android (PBKDF2 allégé).
ServicesHorsLigne servicesDeTest({FileAttente? file, Stream<bool>? reseau, CoffreMemoire? coffre, DateTime Function()? horloge}) {
  final c = coffre ?? CoffreMemoire();
  return ServicesHorsLigne(
    file: file ?? FileAttenteMemoire(),
    identifiants: IdentifiantsHorsLigne(c, iterations: 1000, horloge: horloge),
    appareil: IdentiteAppareil(c),
    reseau: reseau ?? const Stream.empty(),
  );
}
