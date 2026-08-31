# hermes-leo-config

Image Docker custom de l'agent **hermes-leo** (Léo) : image officielle
[`nousresearch/hermes-agent`](https://github.com/NousResearch/hermes-agent) +
outils agents absents de la base.

## Contenu ajouté

| Outil | Version | Usage |
|---|---|---|
| **gws** (Google Workspace CLI) | 0.22.5 | Gmail, Tasks, Calendar, Drive — Gmail automatisé (remplace himalaya) |
| **gh** (GitHub CLI) | 2.98.0 | Issues, PRs, releases |
| **kubectl** | 1.31.0 | Debug cluster (lecture pods/logs, RBAC read-only) |

## Versioning — calver `vYYYY.M.D`

Le repo est versionné **calver** comme hermes-agent (ex: `v2026.8.31`).
Une **release GitHub** déclenche le build et génère les tags image :

```
ghcr.io/rjullien/hermes-leo-config/hermes-leo-custom:v2026.8.31   ← tag release (calver)
ghcr.io/rjullien/hermes-leo-config/hermes-leo-custom:v2026.8      ← mois
ghcr.io/rjullien/hermes-leo-config/hermes-leo-custom:latest        ← majeur
ghcr.io/rjullien/hermes-leo-config/hermes-leo-custom:sha-<sha>     ← immuable
```

**Créer une version :**

```bash
gh release create v2026.8.31 \
  --repo rjullien/hermes-leo-config \
  --title "hermes-leo-config v2026.8.31" \
  --notes "Image custom hermes-leo : hermes-agent + gws/gh/kubectl"
```

Le workflow `build.yml` (déclenché sur `release: published`) pousse les 4 tags.

## Renovate (maintenance des versions)

Renovate tourne self-hosted via **GitHub Actions** (`renovate.yml`, pas l'app
Renovate publique). Config : `renovate.json`.

| Dépendance | Délai avant PR | Automerge |
|---|---|---|
| Binaires (gws, gh, kubectl) | 3 jours | ✅ automerge |
| Actions GitHub du repo | — | ✅ automerge |
| Image de base `hermes-agent` | 7 jours | ✅ automerge (review humaine = renovate vps-infra) |

**Règle sécurité** : tout est automergé ici (outillage image) — la **vérification
humaine se fait au niveau vps-infra** (le renovate de Baptiste) quand l'image est
référencée dans le deployment. Le délai (3j binaires / 7j hermes-agent) laisse le
temps de détecter une release compromise avant merge.

**Pièges connus (vécus le 31/08/2026) :**

1. **`GITHUB_TOKEN` ne suffit pas** → Renovate échoue avec `Integration unauthorized - aborting`.
   Il faut le secret `RENOVATE_TOKEN` (PAT OAuth `gho_...`) et le passer dans
   `renovatebot/github-action` avec `token: ${{ secrets.RENOVATE_TOKEN }}`.
2. **`RENOVATE_AUTOMERGE=false` dans l'env du workflow écrase la config du repo**
   (automerge dans `renovate.json`) → ne pas le définir.
3. **Le regex manager** lit les ARG épinglés :
   ```dockerfile
   # renovate: datasource=github-releases depName=googleworkspace/cli
   ARG GWS_VERSION=0.22.5
   ```
   → Renovate propose les bumps automatiquement.
4. **Binaire glibc** : l'image de base est debian (glibc) → télécharger
   `google-workspace-cli-x86_64-unknown-linux-gnu.tar.gz` (PAS `-musl`, réservé
   aux images Alpine).

## Secrets

**Aucun secret dans ce repo** (public). Les credentials OAuth Google
(refresh_token Gmail/Tasks) vont dans **Infisical** (projet `infrastructure`,
env `prod`, chemin `/agents/hermes-leo`) — jamais en git.

Config locale des credentials gws sur le pod :
`GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE` + `GOOGLE_WORKSPACE_CLI_CONFIG_DIR`
(par compte : rene / leo séparés pour éviter la fuite de compte via le cache).

## Déploiement

Le pod `hermes-leo` (namespace `openclaw`) référence l'image via
`workloads/agents/hermes-leo/hermes-leo-deployment.yaml` dans
[`BaptTF/vps-infra`](https://github.com/BaptTF/vps-infra).
Changement d'image → PR vps-infra (pattern GitOps, ArgoCD auto-sync).

## Tests manuels après déploiement

```bash
kubectl exec -n openclaw deploy/hermes-leo -- gws --version  # 0.22.5
kubectl exec -n openclaw deploy/hermes-leo -- gh --version   # 2.x
kubectl exec -n openclaw deploy/hermes-leo -- kubectl version --client
```