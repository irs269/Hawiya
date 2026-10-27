# Hawiya

> **Prototype de démonstration — système non officiel.** Hawiya n'est pas un système de l'État comorien. Il ne contient que des données fictives.

Hawiya enregistre l'identité d'une personne et ses empreintes digitales avec la seule caméra d'un smartphone Android. Il la reconnaît ensuite quand elle présente sa main devant l'écran. *« Votre main suffit. »*

## Structure

| Dossier | Contenu | État |
|---|---|---|
| `backend/` | API FastAPI + PostgreSQL (fiches, numéros, journal) | Phase 1 ✅ |
| `matcher/` | Service Java SourceAFIS (comparaison 1:1 et 1:N) | Phase 4 |
| `mobile/` | Application Flutter (Android) | Phases 2-3 |
| `dashboard/` | Tableau de bord web des superviseurs | Phase 8 |
| `docs/` | Documentation, protocoles de test, sécurité | au fil des phases |

## Prérequis

- Docker Desktop (démarré)
- Git

Le backend et PostgreSQL tournent dans Docker : rien d'autre à installer pour la phase 1.

## Lancer le serveur

```bash
# 1. Créer le fichier de configuration (une seule fois) puis remplacer les « change-moi »
cp .env.example .env

# 2. Démarrer PostgreSQL + l'API (les migrations s'appliquent automatiquement)
docker compose up --build

# 3. (Autre terminal) Charger les 30 citoyens fictifs et l'agent de démonstration
docker compose exec backend python -m app.seed
```

- Documentation interactive de l'API : <http://localhost:8000/docs>
- Santé : <http://localhost:8000/sante>

### Se connecter dans /docs

Chaque appareil (téléphone ou poste) doit être **approuvé** avant de pouvoir se connecter.

1. Cliquer sur **Authorize** et saisir :
   - `username` = `SEED_AGENT_MATRICULE` (par défaut `AG-0001`) ;
   - `password` = `SEED_AGENT_MOT_DE_PASSE` (voir `.env`) ;
   - `client_id` = un identifiant pour ce poste, par exemple `poste-demo-0001` (8 caractères au moins).
2. La première fois, la réponse est « appareil en attente », avec un code. Approuver ce poste depuis le serveur :
   ```bash
   docker compose exec backend python -m app.outils appareils             # liste des demandes
   docker compose exec backend python -m app.outils approuver POSTE-DE    # code affiché
   ```
3. Se reconnecter, puis tester les routes. L'agent de démonstration est **administrateur** : il peut créer des agents (`POST /agents`) et approuver les téléphones (`POST /appareils/{code}/approuver`).

Règles de connexion (phase 1 bis) :
- jeton d'accès de 15 minutes, renouvelé automatiquement par l'application (jeton de renouvellement valable 30 jours, changé à chaque usage) ;
- blocage de 15 minutes après 5 mots de passe faux ;
- mot de passe provisoire à changer à la première connexion ;
- suspendre un agent ou révoquer un appareil coupe ses sessions immédiatement.

Pour retrouver l'accès si l'administrateur est bloqué : `docker compose exec backend python -m app.outils reinitialiser AG-0001`.

## Lancer les tests

```bash
docker compose run --rm backend pytest
```

Les tests utilisent une base séparée (`TEST_DATABASE_URL`, créée automatiquement) et ne touchent jamais la base de développement.

## Commandes utiles

```bash
docker compose exec backend python -m app.seed --reset   # recrée les 30 fiches fictives
docker compose exec backend alembic revision --autogenerate -m "description"   # nouvelle migration
docker compose exec backend alembic check                 # modèles et migrations cohérents ?
docker compose down -v                                    # tout arrêter ET effacer la base
```

## Numéro d'identification

Format **provisoire** : `KM-AAAA-NNNNNN-L`. Exemple : `KM-2026-000042-X`.

- `AAAA` : année d'enregistrement
- `NNNNNN` : séquence de l'année
- `L` : lettre de contrôle (modulo 23)

Le numéro est attribué par le serveur uniquement. Le format est défini dans un seul fichier, [`backend/app/numero.py`](backend/app/numero.py), pour pouvoir adopter le format officiel quand l'État le fixera.

## Empreintes et identification (API)

Ces routes demandent que le matcher soit démarré. Le téléphone envoie les découpes des bouts de doigts, encodées en base64. Elles servent à calculer les modèles puis sont oubliées : **seuls les modèles sont enregistrés**.

| Route | Rôle |
|---|---|
| `POST /doublons` | contrôle anti-doublon **avant** de créer la fiche (rien n'est enregistré) |
| `PUT /citoyens/{numero}/empreintes` | enregistre les modèles. En cas de doublon certain ou possible : refus (409), sauf validation explicite d'un superviseur |
| `PUT /citoyens/{numero}/medias` | photo du visage (JPEG/PNG) et signature (PNG), 2 Mo au plus |
| `GET /citoyens/{numero}/photo` · `/signature` | relecture de la photo ou de la signature |
| `POST /identification` | un à trois scans de la main → `identifie` (avec la fiche), `non_enregistre` ou `non_concluant` |

### Démo avec l'application mobile

1. Sur le PC : `docker compose up` (backend, base, matcher), puis `docker compose exec backend python -m app.seed --reset` pour les fiches fictives.
2. Téléphone et PC sur le **même Wi-Fi**. Installer la version de débogage : `flutter run` dans `mobile/`. Elle seule autorise le HTTP non chiffré vers le PC.
3. Dans l'application : saisir l'adresse du PC (ex. `http://192.168.1.10:8000`), puis le matricule et le mot de passe de l'agent de démonstration.
   La première fois, l'application affiche le **code du téléphone** : l'approuver avec `docker compose exec backend python -m app.outils approuver <code>`, puis se reconnecter.
4. **Enregistrer une personne** : identité, domicile et signalement, photo et signature, 10 empreintes, puis récapitulatif. L'envoi fait le contrôle anti-doublon **avant** d'attribuer le numéro.
5. **Identifier une personne** : choisir la main, puis scanner.
6. **Compléter les empreintes d'une fiche** : pour une fiche fictive déjà en base (données de démonstration).

**Sans réseau** : après une première connexion en ligne, l'agent peut se connecter et enregistrer hors ligne. Les enregistrements sont gardés **chiffrés** sur le téléphone et envoyés automatiquement au retour du réseau. Voir [`docs/rapport-hors-ligne.md`](docs/rapport-hors-ligne.md).

Règle : **ne jamais afficher la fiche d'une autre personne**. En cas de doute, la réponse est `non_concluant` : l'agent recommence le scan, puis passe à une vérification manuelle sur pièce d'identité. Conditions et seuils provisoires : [`docs/evaluation/diagnostic-phase4.md`](docs/evaluation/diagnostic-phase4.md).

## Règles du projet

Voir [`CLAUDE.md`](CLAUDE.md) : données fictives uniquement, modèles d'empreintes plutôt que photos, chiffrement partout, fonctionnement hors ligne, code commenté en français et testé.
