# AGENTS.md — Guide pour les agents IA travaillant sur ce repo

Ce repo build l'image Docker de l'agent **hermes-leo**. Tout changement passe
par les règles suivantes. À LIRE AVANT de modifier quoi que ce soit.

## 🎯 Le but du repo

Une couche fine sur l'image officielle `nousresearch/hermes-agent` :
**seulement des binaires système** (gws, gh, kubectl). Pas de scripts, pas de
venvs, pas de skills — ceux-ci vivent sur le PVC `/opt/data` et les ConfigMaps
(vps-infra), pas dans l'image.

## 🚫 Règles absolues

1. **JAMAIS de secret dans ce repo** : pas de refresh_token, client_secret,
   clé API, token, credentials Google. Le repo est **public**. Toute credential
   va dans **Infisical** (projet `infrastructure`, env `prod`,
   chemin `/agents/hermes-leo`).
2. **Ne pas modifier l'image de base** (`FROM nousresearch/hermes-agent`) sans
   raison critique — elle est trackée par Renovate (review manuelle 7j).
3. **Binaire gws = glibc** (`-unknown-linux-gnu`), PAS musl (base debian).
4. **Ne pas retirer un outil** tant que le pod l'utilise (check vps-infra +
   skills + crons avant). Exemple : himalaya a été retiré car gws le remplace
   pour Gmail — mais vérifier les usages avant chaque retrait.
5. **Ne pas épingler une version** sans le commentaire Renovate qui précède
   l'ARG :
   ```dockerfile
   # renovate: datasource=github-releases depName=googleworkspace/cli
   ARG GWS_VERSION=0.22.5
   ```

## 🔄 Workflow de mise à jour d'un outil

1. Modifier la version dans le Dockerfile (ou laisser Renovate proposer).
2. Marquer une **release GitHub calver** :
   ```bash
   gh release create v2026.8.31 --repo rjullien/hermes-leo-config \
     --title "hermes-leo-config v2026.8.31" --notes "..."
   ```
   → `build.yml` (déclenché sur `release: published`) build + push les tags
   `vYYYY.M.D`, `vYYYY.M`, `latest`, `sha-<commit>`.
3. Mettre à jour le tag dans **vps-infra**
   (`workloads/agents/hermes-leo/hermes-leo-deployment.yaml`) → PR vers
   `BaptTF/vps-infra` → ArgoCD déploie.

## 🤖 Renovate — ce que l'agent doit savoir

- Renovate tourne **self-hosted via GitHub Actions** (`renovate.yml`), PAS
  l'app publique. Secret `RENOVATE_TOKEN` requis (PAT, car `GITHUB_TOKEN` ne
  suffit pas → `Integration unauthorized`).
- **Tout est en automerge** (binaires 3j, actions, hermes-agent 7j) : la
  **review humaine se fait au niveau vps-infra** (renovate de Baptiste) quand
  l'image est déployée — pas ici. Ne pas re-désactiver l'automerge.
- Ne PAS remettre `RENOVATE_AUTOMERGE=false` dans le workflow : ça écrase
  `renovate.json`.
- Dashboard des updates : issue #1 « Dependency Dashboard ».
- Après un **changement de config Renovate** : relancer
  `gh workflow run renovate.yml --repo rjullien/hermes-leo-config`.
- Les branches/PRs Renovate apparaissent en « Errored » si une branche a déjà
  été patchée par un run antérieur → supprimer la branche et relancer.

## 🧪 Vérification après build

```bash
# Tester l'image localement (docker dispo) :
docker run --rm --entrypoint gws   ghcr.io/rjullien/hermes-leo-config/hermes-leo-custom:latest --version
docker run --rm --entrypoint gh    ghcr.io/rjullien/hermes-leo-config/hermes-leo-custom:latest --version
docker run --rm --entrypoint kubectl ghcr.io/rjullien/hermes-leo-config/hermes-leo-custom:latest version --client

# Ou dans le pod après déploiement :
kubectl exec -n openclaw deploy/hermes-leo -- gws --version
```

## 📝 Conventions

- Commits : Conventional Commits (`feat:`, `fix:`, `ci:`, `chore:`, `docs:`).
- Une release calver = un build. Pas de tag volant hors release.
- Tout changement de comportement → update README.md (l'image est publique,
  les utilisateurs externes lisent le README).