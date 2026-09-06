# AGENTS.md — Guide pour les agents IA travaillant sur ce repo

Ce repo build l'image Docker de l'agent **hermes-leo**. Tout changement passe
par les règles suivantes. À LIRE AVANT de modifier quoi que ce soit.

## 🎯 Le but du repo

Une couche fine sur l'image officielle `nousresearch/hermes-agent` :
**seulement des binaires système** (gws, gh, kubectl, devin, go). Pas de
scripts, pas de venvs, pas de skills — ceux-ci vivent sur le PVC `/opt/data` et
les ConfigMaps (vps-infra), pas dans l'image.

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
   Si un retrait est décidé : **retirer l'outil de la table `TOOLS` de
   `scripts/sync-download-checksums.mjs` dans le MÊME commit**. Le script exige
   le couple `ARG <OUTIL>_VERSION` / `ARG <OUTIL>_SHA256` de chaque outil qu'il
   connaît (fail-closed volontaire) : sinon `--check` échoue pour les cinq, avec
   un message qui nomme l'outil manquant. Idem si l'URL téléchargée par le `RUN`
   change (renommage d'asset amont, variante `-musl`…) : le script recroise son
   URL avec celle du Dockerfile et refuse de travailler si elles divergent, pour
   éviter d'écrire le checksum d'un fichier que le build ne télécharge pas.
5. **Ne pas épingler une version** sans le commentaire Renovate qui précède
   l'ARG, ni sans son `ARG <OUTIL>_SHA256` juste après :
   ```dockerfile
   # renovate: datasource=github-releases depName=googleworkspace/cli
   ARG GWS_VERSION=0.22.5
   ARG GWS_SHA256=de78ecdbd2f1a84cca0063a7ecbc440240fc14b6ebccbb17f4646b792a8c5c1f
   ```
   Les trois lignes forment un bloc indissociable : le `RUN` qui suit vérifie
   l'archive avec `sha256sum -c` AVANT de l'extraire (S-01).
   **Le `ARG <OUTIL>_SHA256` est maintenu par machine — ne JAMAIS l'éditer à la
   main** (ni le copier depuis une page web). Pour le rafraîchir :
   ```bash
   node scripts/sync-download-checksums.mjs --check   # CI : sort 1 si un SHA est périmé
   node scripts/sync-download-checksums.mjs --write   # réécrit les lignes _SHA256 périmées
   node scripts/sync-download-checksums.mjs --write --only=golang   # un seul outil
   ```
   Le script est **sans dépendance** (Node + stdlib uniquement, pas de
   `package.json`, pas de `curl`/`jq`) parce qu'il doit tourner dans le
   conteneur `ghcr.io/renovatebot/renovate`. Ne pas y ajouter de dépendance.

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

### Synchronisation version ↔ SHA-256 (ne pas casser)

Renovate ne connaît que le `ARG <OUTIL>_VERSION`. Deux réglages, et deux
seulement, empêchent le `ARG <OUTIL>_SHA256` de rester périmé :

1. **`postUpgradeTasks` dans `renovate.json`** (règle des 5 binaires) :
   `node scripts/sync-download-checksums.mjs --write --only={{{depName}}}`,
   `fileFilters: ["Dockerfile"]`, `executionMode: "update"`. Le SHA corrigé
   fait donc partie du **commit Renovate** et reste relisible dans le diff.
2. **`RENOVATE_ALLOWED_COMMANDS` dans `renovate.yml`** : `allowedCommands` est
   une config **admin** (self-hosted), impossible à définir depuis
   `renovate.json`. C'est elle qui *autorise* la commande ci-dessus.

**Retirer l'un des deux casse la synchro, mais pas de la même façon :**

- retirer `postUpgradeTasks` de `renovate.json` **ne produit aucune erreur
  visible** : Renovate bumpe la version seule, et l'échec n'apparaît qu'au build
  sur `sha256sum -c` (symptôme vécu : PR #26 golang 1.27.1 « blocked ») ;
- retirer `RENOVATE_ALLOWED_COMMANDS` **est signalé** : Renovate loggue un
  `warn` et remonte un `artifactErrors` affiché dans le corps de la PR, qui
  nomme la commande refusée (« Post-upgrade command '…' has not been added to
  the allowed list in allowedCommands »). Le checksum reste périmé pour autant.

Dans les deux cas, le filet de sécurité est l'étape « Vérifier les SHA-256 des
5 téléchargements » de `pr-validation.yml` : elle nomme l'outil et les deux
valeurs **avant** le build, au lieu d'un échec opaque après le téléchargement de
70 Mo de Go. C'est une **étape du job `build-and-verify`**, pas un job séparé :
en job distinct relié par `needs:`, son échec rendait le check requis
`build-and-verify` *skipped*, et un check requis skipped est compté comme
satisfait par la branch protection. Ne pas la ré-extraire en job sans ajouter ce
job aux checks requis de `main`.

⚠️ **Un amont injoignable n'est pas un échec.** Le mode `--check` retente
(3 tentatives, timeout 60 s) puis se contente d'un **avertissement** si l'amont
répond 5xx, a retiré l'asset ou throttle le runner : seul un vrai écart entre le
checksum commité et le checksum publié sort en 1. Sans ça, une indisponibilité
amont rendrait `main` non mergeable alors que l'image reste construisible. En
mode `--write` (Renovate), au contraire, **tout échec est fatal** et rien n'est
écrit : Renovate produit alors une PR portant un `artifactErrors` plutôt qu'un
faux checksum. Cas concret attendu : kubectl est suivi en `github-tags` sur
`kubernetes/kubernetes`, alors que le binaire vient de `dl.k8s.io`. Un tag peut
exister **avant** la publication des binaires ; dans cette fenêtre le `--write`
échoue et la PR kubectl arrive avec un bloc d'erreur au lieu d'un bump propre.
C'est fail-closed et voulu : relancer `renovate.yml` une fois les binaires
publiés.

⚠️ **Ne pas remettre le groupe de capture `currentDigest`** dans
`customManagers` : aucune des datasources utilisées (`golang-version`,
`github-releases`, `github-tags`, `custom`) ne sait résoudre le SHA-256 d'une
archive comme un digest. Le résultat observé était : branche
`renovate/kubernetes-kubernetes-digest` en erreur en tentant d'écrire un SHA de
**commit git** de kubernetes/kubernetes dans `KUBECTL_SHA256`, « Could not
determine new digest for update » pour `googleworkspace/cli` et `cli/cli`, et
« Failed to look up custom package devin-cli: no-result » — soit gws, gh et
devin **gelés sans aucune mise à jour**.

Sources amont du checksum, par outil (utilisées par le script) :

| Outil | Source du SHA-256 publié |
|---|---|
| gws | `…/releases/download/v<V>/google-workspace-cli-x86_64-unknown-linux-gnu.tar.gz.sha256` (format `<hex>␠␠<fichier>`) |
| gh | `…/releases/download/v<V>/gh_<V>_checksums.txt` → ligne dont le fichier est exactement `gh_<V>_linux_amd64.tar.gz` |
| kubectl | `https://dl.k8s.io/release/v<V>/bin/linux/amd64/kubectl.sha256` (hex nu ; c'est le hash du **binaire**, pas d'une archive) |
| devin | `https://static.devin.ai/cli/<V>/manifest.json` → `.platforms["x86_64-unknown-linux"].sha256` (manifest **par version**, pas `/current/`) |
| go | `https://go.dev/dl/?mode=json&include=all` → entrée `.version == "go<V>"`, fichier `os=linux` `arch=amd64` `kind=archive`, champ `.sha256` |

⚠️ **go.dev ne publie PAS de `.sha256` par archive.**
`https://go.dev/dl/go<V>.linux-amd64.tar.gz.sha256` renvoie une **page HTML**,
pas un hash (vérifié). Toute implémentation qui suppose cette URL écrit du HTML
dans `GO_SHA256`. Utiliser l'endpoint `?mode=json`.

Avant d'écrire, le script ne se contente pas du checksum publié : il
**retélécharge l'artefact et recalcule le SHA-256 en flux**, et n'écrit rien si
les deux valeurs divergent.

**Portée exacte de cette contre-vérification** (à ne pas surestimer) : pour un
outil donné, le checksum publié et l'artefact viennent du **même éditeur, même
domaine, même chaîne TLS**. Elle attrape un téléchargement tronqué, un
cache/miroir divergent, une publication incohérente entre le fichier de checksums
et l'archive — elle **n'attrape pas** un éditeur qui publierait un artefact
malveillant avec le checksum correspondant (compromission d'un compte de
release). Ce n'est donc pas une attestation indépendante de la source, seulement
du transport.

Ce que S-01 conserve malgré tout : la valeur est **figée dans le dépôt**,
relisible dans le diff de la PR, et **rejouée à chaque build** contre le CDN
(donc une archive substituée après coup fait échouer le build). Comme la règle
qui porte `postUpgradeTasks` porte aussi `automerge: true`, le seul délai humain
restant sur ce chemin est `minimumReleaseAge` (3 jours pour les binaires) : c'est
un choix assumé ici, la review humaine se faisant au niveau vps-infra quand
l'image est déployée. Si ce compromis doit changer un jour, la bonne manette est
`minimumReleaseAge`, pas la désactivation de l'automerge (cf. plus haut).

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
