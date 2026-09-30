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

1. Cliquer sur **Authorize**.
2. `username` = `SEED_AGENT_MATRICULE` (par défaut `AG-0001`), `password` = `SEED_AGENT_MOT_DE_PASSE` (voir `.env`).
3. Tester `POST /citoyens`, `GET /citoyens`, `GET /citoyens/{numero}` et `GET /statistiques`.

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

## Règles du projet

Voir [`CLAUDE.md`](CLAUDE.md) : données fictives uniquement, modèles d'empreintes plutôt que photos, chiffrement partout, fonctionnement hors ligne, code commenté en français et testé.
