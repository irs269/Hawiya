# Rapport phase 2 : écrans et formulaires (27/10/2026)

> Prototype non officiel, données fictives uniquement.

## Ce qui a été fait

- **Parcours « Enregistrer une personne »** (mobile) : Identité → Domicile et signalement → Photo et signature → Empreintes (main droite, main gauche, pouces) → Récapitulatif → envoi → confirmation avec le numéro.
  - Validations identiques à celles du serveur (champs obligatoires, date, téléphone +269, taille 50 à 250 cm). Les erreurs s'affichent sous chaque champ.
  - Photo du visage par l'appareil photo (`image_picker`, 800 px, JPEG). Signature au doigt, convertie en PNG.
  - Empreintes : au moins 8 doigts nets sur 10, avec un bouton « Compléter les doigts manquants » qui ne refait que les étapes incomplètes.
  - Envoi, dans l'ordre du CLAUDE.md : contrôle anti-doublon (`POST /doublons`) **avant** la création de la fiche, puis fiche, puis photo et signature, puis empreintes. Doublon certain : arrêt, aucun numéro. Doublon possible : validation par un superviseur (bouton visible seulement pour un compte superviseur ; le serveur vérifie aussi).
  - En cas de coupure réseau, « Réessayer » reprend à l'étape qui a échoué **sans recréer la fiche**.
  - Quitter le parcours demande une confirmation.
- **Backend** : `PUT /citoyens/{numero}/medias`, `GET /citoyens/{numero}/photo` et `GET /citoyens/{numero}/signature`. Formats contrôlés par les premiers octets, 2 Mo au plus. Ajout de `GET /auth/moi` (rôle de l'agent).
- **Correction** : `POST /doublons` sans aucun doigt lisible renvoie 422. Avec trop peu de doigts lisibles, la réponse n'est jamais « aucun doublon », même si la base est vide.
- **Design** : polices Fraunces (titres) et Figtree (texte) intégrées à l'application (licence OFL, fichiers dans `mobile/assets/polices/`) ; interface Flutter en français (calendrier compris).

## Comment tester

- Backend : `docker compose run --rm backend pytest` (144 tests).
- Mobile : `flutter test` dans `mobile/` (70 tests) ; démo sur téléphone : voir le README, section « Démo avec l'application mobile ».

## Ce qui reste incomplet

- **Pas de mode hors ligne** : la saisie reste en mémoire et elle est perdue si l'application est fermée. Le stockage chiffré sur le téléphone et la synchronisation feront l'objet d'une phase dédiée.
- **Non essayé sur un vrai téléphone** : appareil photo, signature au doigt, enchaînement avec la capture des empreintes.
- Photo et signature **non chiffrées au repos** côté serveur (phase 7).
- Certains messages de validation du serveur restent en anglais (messages Pydantic). Les contrôles faits sur le téléphone couvrent les cas courants.
- Fiabilité de la reconnaissance toujours non mesurée avec plusieurs personnes.
