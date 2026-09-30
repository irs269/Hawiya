# Hawiya — contexte du projet

Hawiya est une application d'identification biométrique pour les Comores.

## But du projet
Hawiya permet à un agent de l'État d'enregistrer un citoyen (identité, domicile, signalement, photo, signature, empreintes) avec un simple smartphone Android, puis de reconnaître cette personne plus tard quand elle présente sa main devant la caméra. Les empreintes sont capturées SANS lecteur d'empreintes : la caméra arrière et le flash du téléphone filment la main, l'application détecte les doigts et capture automatiquement les meilleures images. C'est d'abord une démo à présenter au Ministère de l'Intérieur des Comores.

## Deux parcours
1. **Enregistrement** : Identité -> Domicile et signalement -> Photo et signature -> Empreintes (main droite 4 doigts, main gauche 4 doigts, 2 pouces) -> contrôle anti-doublon -> attribution d'un numéro d'identification -> confirmation.
2. **Identification** : scan d'une main -> comparaison 1:N avec toute la base -> fiche de la personne, ou « personne non enregistrée ».

## Champs d'une fiche
Nom, prénom(s), sexe, date de naissance, lieu de naissance, nationalité, numéro d'acte de naissance, téléphone, île (Ngazidja, Ndzuani, Mwali), ville, quartier, adresse, taille (cm), couleur des yeux, couleur des cheveux, photo du visage, signature, modèles d'empreintes des 10 doigts, date et agent d'enregistrement.

## Architecture
- `mobile/` : application Flutter (Android d'abord), interface en français.
- `backend/` : API Python FastAPI + PostgreSQL (décision confirmée : pas de Supabase).
- `matcher/` : service Java qui utilise la bibliothèque SourceAFIS pour comparer les empreintes (1:1 et 1:N).
- `dashboard/` : tableau de bord web pour les superviseurs.
- `docker-compose.yml` pour lancer backend, base de données et matcher en local.

## Règles à respecter toujours
- Données sensibles : ne jamais écrire de vraies données personnelles dans le code, les tests ou les exemples. Utiliser uniquement des données fictives.
- Stocker les modèles d'empreintes (templates), pas les photos des doigts, sauf en mode évaluation explicitement activé.
- Tout chiffrer : sur le téléphone, pendant l'envoi (HTTPS), et au repos côté serveur.
- L'enregistrement doit fonctionner hors ligne ; la synchronisation se fait au retour du réseau.
- Code simple, commenté en français, avec des tests.
- À chaque phase : proposer d'abord un plan court, attendre la validation, puis coder. À la fin, lister ce qui a été fait, comment le tester, et ce qui reste incomplet. Être honnête sur ce qui ne marche pas.
- Ne jamais présenter l'application comme un système officiel de l'État.
- Commit Git à la fin de chaque phase.

## Design
Fond ivoire `#F5F3EE`, texte `#14201C`, couleur principale vert profond `#0F5A45`, accent doré `#C98A1B`, vert de validation `#3DDC97`. Titres en Fraunces, texte en Figtree. Écran caméra sur fond sombre `#101915`. Boutons d'au moins 44 px de haut.

## Ordre des phases retenu
Le document d'origine (« Prompts Claude Code par phase ») définit les phases 1, 1 bis, 2 à 9. Ordre de travail choisi pour traiter le risque principal (fiabilité des empreintes par caméra) le plus tôt possible :
1. Phase 1 — structure + serveur de base
2. Phases 3 + 4 — capture automatique et comparaison (spike de faisabilité)
3. Phase 2 — écrans et formulaires
4. Phase 1 bis — authentification complète des agents
5. Phases 5 à 9

## Notes techniques
- Phase 3 : pas de plugin Flutter officiel pour MediaPipe Hand Landmarker ; prévoir un module natif Kotlin (CameraX ImageAnalysis + ImageCapture, MediaPipe Tasks) exposé à Flutter par un canal de plateforme.
- Phase 4 : SourceAFIS attend des empreintes type contact à ~500 dpi ; la normalisation d'échelle (largeur du doigt) et la fusion des scores des 4 doigts sont essentielles. Le 1:N SourceAFIS est en force brute : suffisant pour une démo, pas pour tout le pays.

## Environnement de développement (Windows)
- Flutter : `C:\Users\admin\flutter\bin` ; Android SDK : `%LOCALAPPDATA%\Android\Sdk`.
- `JAVA_HOME` utilisateur = Temurin 17 (la commande `java` du PATH système reste Java 8).
- Python local 3.14 : le backend tourne en Python 3.12 dans Docker.
