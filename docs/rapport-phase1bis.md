# Rapport phase 1 bis : authentification complète des agents (27/10/2026)

> Prototype non officiel, données fictives uniquement.

## Ce qui a été fait

### Serveur
- **Appareils approuvés** : toute connexion présente l'identifiant de l'appareil (`client_id`). Un appareil inconnu est enregistré « en attente » avec un code court (8 caractères). Un superviseur ou un administrateur l'approuve (`POST /appareils/{code}/approuver`), ou on passe par le serveur (`python -m app.outils approuver <code>`), utile au premier démarrage. Un appareil **révoqué** (perdu, volé) est refusé pour toujours, et ses sessions sont coupées.
- **Jetons** : le jeton d'accès (15 min) porte l'agent, l'appareil et la session. Le jeton de renouvellement (30 jours) est aléatoire, enregistré **haché**, et changé à chaque usage (`POST /auth/renouveler`). Un ancien jeton présenté de nouveau signale un vol probable : **toute la session est révoquée** et l'événement est journalisé. `POST /auth/deconnexion` révoque la session.
- **Contrôle à chaque requête** : agent actif, appareil approuvé, session non révoquée. Suspendre un agent ou révoquer un appareil prend effet immédiatement.
- **Blocage** : 5 mots de passe faux consécutifs bloquent le compte 15 minutes, même avec le bon mot de passe. Le message est identique dans tous les cas (il ne révèle ni les matricules ni les blocages), et tout est journalisé.
- **Mots de passe** : 10 caractères au moins, sans le matricule, pas trop simple. Un mot de passe **provisoire** (création, réinitialisation) bloque tout sauf `POST /auth/mot-de-passe` et `GET /auth/moi`. Changer son mot de passe coupe les autres sessions.
- **Gestion des agents** (administrateurs) : `GET/POST /agents`, `PATCH /agents/{matricule}` (rôle, statut, île), `POST /agents/{matricule}/reinitialiser`. Le mot de passe provisoire n'est montré qu'une fois, jamais journalisé. Un administrateur ne peut pas se retirer ses propres droits.
- **Rôles** vérifiés par une dépendance commune : agent, superviseur (doublons, appareils), administrateur (agents).
- Migration Alembic `0002`, vérifiée par `alembic check`, réversible.

### Téléphone
- Identifiant de l'appareil généré une fois et gardé dans le coffre ; son code est affiché sur l'écran de connexion. En attente d'approbation, un encadré indique le code à donner au superviseur.
- Jeton de renouvellement dans le coffre. **Renouvellement automatique** quand le jeton d'accès expire, avec la requête rejouée une fois, et **un seul renouvellement à la fois** (deux requêtes simultanées ne déclenchent pas la détection de vol). Au démarrage, la session reprend sans mot de passe si elle est encore valable.
- Écran de changement de mot de passe : obligatoire après un mot de passe provisoire, et disponible depuis l'accueil.
- Déconnexion : session révoquée sur le serveur ; les enregistrements en attente restent.
- **Connexion hors ligne renforcée** : plusieurs agents par téléphone, blocage après 5 essais ratés (15 min), validité de **7 jours** depuis la dernière connexion en ligne. Si le serveur répond « appareil révoqué », les identifiants hors ligne et la session sont effacés, et un nouvel identifiant d'appareil est créé.

## Comment tester

- Backend : `docker compose run --rm backend pytest` (170 tests).
- Mobile : `flutter test` dans `mobile/` (103 tests).
- Démo : voir le README, sections « Se connecter dans /docs » et « Démo avec l'application mobile ».

## Ce qui reste incomplet

- **Pas d'écran d'administration** : l'approbation des téléphones et la gestion des agents se font par l'API (`/docs`) ou en ligne de commande, en attendant le tableau de bord.
- **Pas de double authentification** (code par SMS ou autre).
- Les agents ne sont **pas encore limités à leur île ou commune** (le champ existe, il n'est pas appliqué aux données).
- Un agent suspendu reste connectable **hors ligne** sur un téléphone qui ne voit pas le serveur, jusqu'à 7 jours après sa dernière connexion en ligne. Il pourra enregistrer, mais rien ne sera envoyé, puisque le serveur refusera.
- **Non essayé sur un vrai téléphone.**
