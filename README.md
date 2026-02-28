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

## Règles de tri

Les règles sont dans `config/rules.json`.

- `archive: true` applique le libellé puis retire `INBOX`
- `archive: false` applique seulement le libellé

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
