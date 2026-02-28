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
DRY_RUN=true bash scripts/gmail-reconcile.sh
```

Puis, si le résultat te convient :

```bash
DRY_RUN=false bash scripts/gmail-reconcile.sh
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
- classer automatiquement `Bankin`, `PayPal` et `Google Play`
- classer les alertes emploi auto secondaires et les newsletters éditoriales restantes
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

## Réconciliation de l'historique

Le script `scripts/gmail-reconcile.sh` applique des corrections ciblées sur l'existant :

- reclasse `PlatformNotifications-noreply@google.com` vers `☁️ Cloud`
- déplace les plateformes emploi hors de `💼 Recrutement` et `📌 Administratif`
- archive le bruit déjà labellisé mais encore présent dans `INBOX`
- reclasse les notifications `Bankin`, `PayPal`, `Google Play`, presse et newsletters restantes
- retire `📅 À Traiter` des vieux mails et du bruit
- marque comme lus les anciens emails déjà classés comme bruit

Le script fonctionne aussi avec `DRY_RUN=true`.

## Idempotence

Le tri quotidien et la migration historique sont conçus pour être relancés sans effet cumulatif incorrect :

- les requêtes excluent autant que possible les messages déjà traités
- les mutations retirent `INBOX`, `UNREAD` ou les anciens labels de source pour sortir du périmètre de la requête
- en mode réel, les scripts repartent toujours de la première page après mutation pour éviter les trous liés à la pagination Gmail pendant les reclassements

## GitHub Actions

Le workflow quotidien est dans `.github/workflows/daily-gmail-sort.yml`.

Le workflow manuel de migration historique est dans `.github/workflows/mailbox-migration.yml`.

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

Le workflow `Gmail Mailbox Migration` permet de lancer à la demande `scripts/gmail-migrate-mailbox.sh` depuis GitHub avec le même jeu de secrets.

## Push GitHub

Le dépôt ignore maintenant les secrets locaux via `.gitignore`, notamment `credentials.json`, `token.json`, `.env` et `venv/`.
