# Rapport : enregistrement hors ligne et synchronisation (27/10/2026)

> Prototype non officiel, données fictives uniquement.

## Principe

« Enregistrer » écrit **toujours** l'enregistrement complet dans une file d'attente **chiffrée** sur le téléphone, puis tente l'envoi aussitôt :
- envoi réussi : numéro attribué, l'enregistrement est effacé du téléphone ;
- pas de réseau ou serveur injoignable : il reste en attente avec une référence provisoire (`HL-XXXXXX`) et part à la synchronisation. Le contrôle anti-doublon et le numéro se font à ce moment.

Ce qui reste **en ligne seulement** : l'identification et l'anti-doublon, qui comparent la personne à toute la base du serveur, et donc l'attribution du numéro.

## Ce qui a été fait (mobile)

- **Chiffrement** : AES-256-GCM, un fichier par enregistrement dans le dossier privé de l'application. La clé, aléatoire, est gardée dans le coffre Android (Keystore, `flutter_secure_storage`). Un fichier modifié est refusé (contrôle d'intégrité GCM), et il est signalé comme « illisible ». Écriture atomique (fichier temporaire puis renommage). Sauvegarde Android désactivée (`allowBackup="false"`).
- **Reprise exacte** : l'avancement (contrôle fait, numéro attribué, médias envoyés) est enregistré après chaque étape réussie. Après une coupure, ou même un redémarrage de l'application, l'envoi reprend à l'étape suivante **sans recréer la fiche**.
- **Synchronisation** : automatique au retour du réseau (`connectivity_plus`) et à chaque retour sur l'accueil, ou manuelle depuis l'écran « En attente ». Elle s'arrête au premier problème de réseau ou de session.
- **Écran « En attente d'envoi »** : états « en attente », « envoi à terminer » (fiche déjà créée), « à vérifier » (doublon) et « erreur » (refus du serveur). Actions : validation superviseur (doublon possible), réessai, suppression avec confirmation.
- **Connexion hors ligne** : après une connexion en ligne réussie, le téléphone garde une empreinte PBKDF2-HMAC-SHA256 du mot de passe (100 000 itérations, sel aléatoire), jamais le mot de passe lui-même. Hors ligne, l'agent peut enregistrer ; la synchronisation demande une reconnexion en ligne (fenêtre « Connexion en ligne »).

## Exception validée à la règle « modèles, pas photos des doigts »

Les modèles d'empreintes sont calculés par le serveur. Hors ligne, les **découpes des doigts** sont donc gardées sur le téléphone jusqu'à l'envoi : **chiffrées**, puis effacées dès que l'envoi a réussi (ou si l'agent supprime l'enregistrement). Cette exception a été validée le 27/10/2026.

## Comment tester

- `flutter test` dans `mobile/` (88 tests, dont 18 pour le hors ligne : chiffrement, file sur disque, reprise après redémarrage, connexion hors ligne, synchronisation, écrans).
- Sur le téléphone :
  1. Se connecter une fois en ligne.
  2. Couper le Wi-Fi, enregistrer une personne : l'écran « Enregistré sur le téléphone » s'affiche.
  3. Remettre le Wi-Fi : l'envoi part tout seul et le numéro est attribué. On peut aussi passer par « En attente d'envoi » puis « Synchroniser maintenant ».

## Ce qui reste incomplet

- **Non essayé sur un vrai téléphone** : coffre Android, détection du réseau, comportement après redémarrage.
- **Une saisie en cours** (avant « Enregistrer ») n'est pas sauvegardée : fermer l'application à ce moment la fait perdre.
- **Un seul agent mémorisé** pour la connexion hors ligne (le dernier connecté en ligne). Pas de verrouillage après plusieurs essais hors ligne, ni d'expiration. C'est provisoire, en attendant l'authentification complète (phase 1 bis).
- **Doublons entre enregistrements hors ligne** : deux personnes enregistrées hors ligne ne sont comparées qu'à l'envoi, l'une après l'autre. La seconde est alors signalée « à vérifier » si elle ressemble à la première.
- **Clé perdue = données perdues** (réinitialisation du téléphone, effacement des données de l'application) : les enregistrements non envoyés deviennent illisibles. C'est voulu, pour la sécurité, mais il faut synchroniser régulièrement.
