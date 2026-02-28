# gmail-auto-sort

Tri Gmail automatisé sans dépendance Python pour l'exécution courante.

Le runtime principal est maintenant `bash + curl + jq` via `scripts/gmail-sort.sh`. Le script Python `tri_emails.py` reste dans le dépôt, mais il n'est plus nécessaire pour l'automatisation quotidienne ni pour GitHub Actions.

## Exécution locale

Prérequis :

- `bash`
- `curl`
- `jq`
- un projet Google Cloud avec Gmail API activée
- un `refresh_token` OAuth valide

Crée un fichier `.env` non versionné à la racine :

```bash
GOOGLE_CLIENT_ID=...
GOOGLE_CLIENT_SECRET=...
GMAIL_REFRESH_TOKEN=...
```

Puis lance :

```bash
bash scripts/gmail-sort.sh
```

Pour tester sans modifier Gmail :

```bash
DRY_RUN=true bash scripts/gmail-sort.sh
```

Pour nettoyer l'historique existant des labels et des non lus bruit :

```bash
DRY_RUN=true bash scripts/gmail-migrate-mailbox.sh
```

Puis, si le résultat te convient :

```bash
DRY_RUN=false bash scripts/gmail-migrate-mailbox.sh
```

## Règles de tri

Les règles sont dans `config/rules.json`.

- `archive: true` applique le libellé puis retire `INBOX`
- `archive: false` applique seulement le libellé
- `mark_read: true` retire aussi `UNREAD`
- `trash: true` envoie les messages à la corbeille
- `max_messages` limite le volume traité par exécution

Les règles ont été resserrées pour :

- séparer `☁️ Cloud` des newsletters
- sortir les plateformes emploi du label `💼 Recrutement`
- limiter `📅 À Traiter` aux non lus récents et réellement actionnables
- éviter de retraiter les mêmes messages grâce aux exclusions `-label:"..."`

## Purge prudente

La purge est configurée en deux étapes :

1. `🗑️ Purge Candidats` :
   - prend les emails déjà classés comme bruit
   - applique un délai minimum selon la catégorie
   - archive et marque comme lus
   - limite le volume à `500` messages par run

2. `🗑️ Corbeille Auto` :
   - envoie en corbeille uniquement les emails déjà marqués comme candidats
   - laisse une fenêtre de grâce avant suppression automatique par Gmail
   - exclut `is:starred` et `is:important`

Cette approche évite de supprimer brutalement des mails dès leur première détection.

## Migration de l'historique

Le script `scripts/gmail-migrate-mailbox.sh` applique des corrections ciblées sur l'existant :

- reclasse `PlatformNotifications-noreply@google.com` vers `☁️ Cloud`
- déplace les plateformes emploi hors de `💼 Recrutement` et `📌 Administratif`
- retire `📅 À Traiter` des vieux mails et du bruit
- marque comme lus les anciens emails déjà classés comme bruit

Le script fonctionne aussi avec `DRY_RUN=true`.

## GitHub Actions

Le workflow quotidien est dans `.github/workflows/daily-gmail-sort.yml`.

Secrets GitHub à créer dans `Settings > Secrets and variables > Actions` :

- `GOOGLE_CLIENT_ID`
- `GOOGLE_CLIENT_SECRET`
- `GMAIL_REFRESH_TOKEN`

Valeurs à récupérer :

- `GOOGLE_CLIENT_ID` et `GOOGLE_CLIENT_SECRET` depuis `credentials.json`
- `GMAIL_REFRESH_TOKEN` depuis `token.json`

Exemple d'extraction locale :

```bash
jq -r '.installed.client_id' credentials.json
jq -r '.installed.client_secret' credentials.json
jq -r '.refresh_token' token.json
```

Le workflow peut être lancé :

- automatiquement chaque jour à `06:00 UTC`
- manuellement via `workflow_dispatch`

Le lancement manuel accepte un mode `dry_run`.

## Push GitHub

Le dépôt ignore maintenant les secrets locaux via `.gitignore`, notamment `credentials.json`, `token.json`, `.env` et `venv/`.
