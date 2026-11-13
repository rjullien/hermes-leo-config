# Image custom Hermes Léo — image officielle + outils agents
# Pattern: rjullien/nullclaw-lea-config (image custom agent + Renovate)
#
# Outils ajoutés (tous absents de l'image officielle hermes-agent) :
#   - gws                 : Google Workspace CLI (Gmail, Tasks, Calendar, Drive) — remplace gws-axi 0.6.1 ET himalaya
#   - gh                  : GitHub CLI (issues, PRs, releases)
#   - kubectl             : debug cluster (lecture pods/logs)
#   - adb                 : Android Debug Bridge (tablettes murales, caméras, dépannage — depuis platform-tools Google)
#   - entire              : CLI Entire + plugins graph/brain (carte de repo précomputée, mémoire d'agents)
#   - entire-agent-hermes : adaptateur Entire ↔ Hermes (preview, build multi-stage depuis source)
#   - go                  : toolchain Go (compiler/tester les repos Go : opencode-usage-tracker, etc.)
#
# Base: image officielle hermes-agent (debian:13.4, glibc → binaires gnu, PAS musl)
#
# ⚠️ SÉCURITÉ : repo PUBLIC + image ghcr.io publique — AUCUN secret/token dans ce Dockerfile.
# Les credentials (gws OAuth, etc.) vont dans Infisical ou sur le PVC, jamais gravés ici.

# --- Builder : entire-agent-hermes (preview, pas de release / checksums amont) ---
# Image officielle golang épinglée par digest ; tag = go.mod de l'adaptateur
# (agents/entire-agent-hermes/go.mod → go 1.26.0). pinDigests (renovate.json)
# maintient le digest. On ne copie QUE le binaire dans l'image finale — pas de
# mise, pas de toolchain de build.
FROM golang:1.26.0@sha256:fb612b7831d53a89cbc0aaa7855b69ad7b0caf603715860cf538df854d047b84 AS entire-agent-hermes-builder

# Commit pin de entireio/external-agents : seule ancre d'intégrité (pas d'asset
# de release, pas de checksums.txt). Renovate le suit via git-refs (digest du
# tip de main) — customManagers dédié dans renovate.json (ce n'est PAS un
# ARG *_VERSION=, donc hors du manager des binaires curl).
# renovate: datasource=git-refs depName=entireio/external-agents packageName=https://github.com/entireio/external-agents
ARG EXTERNAL_AGENTS_REF=23c64f2861ddbfd2670cffafeb45f86bad6ebc2b

WORKDIR /src
RUN git clone --filter=blob:none https://github.com/entireio/external-agents.git . \
    && git checkout --detach "${EXTERNAL_AGENTS_REF}"

# Build command = mise.toml [tasks.build] de l'adaptateur (vérifié amont) :
#   go build -o entire-agent-hermes ./cmd/entire-agent-hermes
WORKDIR /src/agents/entire-agent-hermes
RUN mkdir -p /out \
    && CGO_ENABLED=0 go build -o /out/entire-agent-hermes ./cmd/entire-agent-hermes

# Base épinglée par digest (S-02) : reconstruire ce commit utilise toujours la
# même image, même si le tag v2026.8.16 est déplacé. Renovate maintient le
# couple tag+digest (pinDigests).
#
# ⚠️ ARCHITECTURE (P-03) : image linux/amd64 UNIQUEMENT. Les URLs ci-dessous
# ciblent x86_64/amd64 et build.yml ne construit que linux/amd64. Pour arm64,
# paramétrer via TARGETARCH et valider les 5 binaires (voir README §Architecture).
FROM nousresearch/hermes-agent:v0.22.7@sha256:e6d81ae52ebf6a43efa529701405509f20054ba818f179ddd748bed4f8af584c

# Ordre des couches (P-02) : chaque couple `# renovate` + ARG version + ARG
# SHA256 est placé JUSTE avant le RUN qui l'utilise, du plus léger au plus lourd
# (gws → gh → kubectl → adb → entire → entire-agent-hermes → go). Ainsi, changer
# la version d'un outil n'invalide QUE sa couche et les suivantes, pas les
# précédentes.
# Chaque outil a un SHA-256 attendu (S-01) : téléchargement vérifié AVANT
# extraction. Renovate maintient version + digest (voir renovate.json).
USER root

# Correctifs Debian (porte Trivy CRITICAL) : l'image de base est digests-épinglée
# et peut donc rester en retard sur les DSA/security de trixie. Sans cette
# couche, la CI échoue sur des CRITICAL OS « Status: fixed » (glib, mbedtls,
# perl, linux-libc-dev…) alors que `apt` peut les appliquer ici. On ne les
# met PAS dans `.trivyignore` — la porte doit rester capable d'échouer sur une
# régression introduite par ce dépôt. Reliquats vraiment non patchables via
# apt → S-03.
#
# linux-libc-dev est réinstallé explicitement (pas seulement via `upgrade`) :
# (1) le cache BuildKit/GHA rejoue sinon une couche `apt-get upgrade` figée
#     avant la publication de 6.12.113-1 (vu en CI #69 : `#7 CACHED` →
#     Trivy CRITICAL CVE-2026-98621/98725/98805 sur 6.12.111-1) ;
# (2) on ne le retire pas — `libc6-dev` / gcc / python3-dev en dépendent et
#     restent utiles aux lazy-installs natives du runtime hermes. Ce n'est
#     que des headers kernel userspace, mais Trivy les score quand même.
# La garde `dpkg --compare-versions` échoue le build si le miroir n'a pas
# encore le fix (≥ 6.12.113), plutôt que de publier une image vulnérable.
#
# SECURITY_CACHE_BUST : passé par la CI (semaine ISO UTC, ex. 2026-W43). Sans
# ça, `cache-from: type=gha` rejoue cette couche tant que l'instruction RUN
# est inchangée — un `apt-get upgrade` figé rate les DSA publiés après coup
# (symptôme #69). Redéclaré avant chaque RUN qui doit en dépendre (scope ARG).
ARG SECURITY_CACHE_BUST=
RUN echo "security-cache-bust=${SECURITY_CACHE_BUST}" \
    && apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y --no-install-recommends \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        linux-libc-dev \
    && dpkg --compare-versions "$(dpkg-query -W -f='${Version}' linux-libc-dev)" ge 6.12.113-1 \
    && rm -rf /var/lib/apt/lists/*

# Correctifs Python du venv hérité (porte Trivy CRITICAL) : même logique que
# l'apt upgrade — la base digests-épinglée laisse certifi/Pillow en retard sur
# les advisories PyPI (GHSA-6q48-6c7w-9gw2, CVE-2026-112393/112403/112900)
# alors qu'un pip upgrade les corrige ici. Idem brotlicffi 1.2.0.2
# (GHSA-9v8h-qqgm-4m35, publiée le 2026-10-22, corrigée en 1.2.1.0) : encore
# 1.2.0.2 dans l'uv.lock amont jusqu'à v0.22.5 au moins. Pas de `.trivyignore` pour ces
# CRITICAL corrigibles. Pillow 13 est un major bump : vérifié (hermes_cli,
# browser_harness, pillow_heif importent).
#
# Idem PyJWT 2.13.0 (CVE-2026-102268, contournement d'authentification,
# corrigée en 2.14.0 ; tirée par google-auth, mcp, msal, oauthlib).
#
# Deux sources de certifi dans la base :
#   1. /opt/hermes/.venv (site-packages) — upgradé via ensurepip + pip, puis
#      pip du venv retiré pour ne pas élargir la surface ;
#   2. pip vendored dans le Python outils (/usr/local/bin/python3 → tools/)
#      — Trivy le compte aussi (certifi 2026.6.17) ; pip 26.2.2 vendors
#      certifi 2026.10.19, donc on upgrade ce pip-là.
# Copies périmées dans les caches uv sont purgées pour ne pas les recompter.
ARG SECURITY_CACHE_BUST=
RUN echo "security-cache-bust=${SECURITY_CACHE_BUST}" \
    && /usr/local/bin/python3 -m pip install --no-cache-dir --upgrade "pip==26.2.2" \
    && /opt/hermes/.venv/bin/python -m ensurepip --upgrade \
    && /opt/hermes/.venv/bin/python -m pip install --no-cache-dir --upgrade \
        "certifi==2026.10.19" \
        "Pillow==13.0.0" \
        "brotlicffi==1.2.1.0" \
        "PyJWT==2.14.0" \
    && /opt/hermes/.venv/bin/python -m pip uninstall -y pip \
    && rm -rf /root/.cache/pip \
    && find /opt/hermes/uv-cache /root/.hermes -type d \
        \( -name 'certifi-2026.5.*' -o -name 'certifi-2026.6.*' \
           -o -name 'pillow-12.*' -o -name 'Pillow-12.*' \
           -o -name 'brotlicffi-1.2.0.*' \
           -o -name 'pyjwt-2.13.*' -o -name 'PyJWT-2.13.*' \) \
        -prune -exec rm -rf {} + 2>/dev/null || true

# --- matplotlib : graphiques Python (demande Camille, 08/11/2026) ---
# Paquet PyPI épinglé par version, installé dans les DEUX pythons runtime :
# le Python outils (/usr/local/bin/python3, celui des scripts agents quand le
# PATH est écrasé par K8s) ET le venv hermes (/opt/hermes/.venv, celui que
# `python3` résout avec le PATH par défaut de l'image) — sinon l'import dépend
# du contexte (piège constaté sur la PR : le smoke hors pod ne voyait pas le
# paquet). Même hygiène que le bloc sécurité : pip retiré du venv après usage.
# Pas de ARG _SHA256 : aucun artefact n'est téléchargé par le Dockerfile
# (wheel PyPI) ; l'ancre est le pin de version + la datasource pypi, tenue par
# Renovate.
# renovate: datasource=pypi depName=matplotlib
ARG MATPLOTLIB_VERSION=3.11.2
RUN /usr/local/bin/python3 -m pip install --no-cache-dir "matplotlib==${MATPLOTLIB_VERSION}" \
    && /opt/hermes/.venv/bin/python -m ensurepip --upgrade \
    && /opt/hermes/.venv/bin/python -m pip install --no-cache-dir "matplotlib==${MATPLOTLIB_VERSION}" \
    && /opt/hermes/.venv/bin/python -m pip uninstall -y pip \
    && rm -rf /root/.cache/pip

# --- gws : Google Workspace CLI (glibc/debian, pas de -musl) ---
# Remplace himalaya pour tout le Gmail automatisé (API native, OAuth standard)
# Télécharge dans un fichier temporaire, vérifie le SHA-256, PUIS extrait.
# renovate: datasource=github-releases depName=googleworkspace/cli
ARG GWS_VERSION=0.22.5
ARG GWS_SHA256=de78ecdbd2f1a84cca0063a7ecbc440240fc14b6ebccbb17f4646b792a8c5c1f
RUN curl -fsSL -o /tmp/gws.tar.gz https://github.com/googleworkspace/cli/releases/download/v${GWS_VERSION}/google-workspace-cli-x86_64-unknown-linux-gnu.tar.gz \
    && echo "${GWS_SHA256}  /tmp/gws.tar.gz" | sha256sum -c - \
    && tar xz -C /usr/local/bin --strip-components=0 -f /tmp/gws.tar.gz ./gws \
    && rm -f /tmp/gws.tar.gz \
    && chmod +x /usr/local/bin/gws

# --- gh : GitHub CLI ---
# renovate: datasource=github-releases depName=cli/cli
ARG GH_VERSION=2.103.3
ARG GH_SHA256=4c806978ffce1cec70853302a56d70ac6da4f19bae7adca4e1a8ab00633dd91d
RUN curl -fsSL -o /tmp/gh.tar.gz https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_amd64.tar.gz \
    && echo "${GH_SHA256}  /tmp/gh.tar.gz" | sha256sum -c - \
    && tar xz -C /tmp -f /tmp/gh.tar.gz \
    && cp /tmp/gh_${GH_VERSION}_linux_amd64/bin/gh /usr/local/bin/gh \
    && rm -rf /tmp/gh_${GH_VERSION}_linux_amd64 /tmp/gh.tar.gz \
    && chmod +x /usr/local/bin/gh

# --- kubectl : debug cluster ---
# renovate: datasource=github-tags depName=kubernetes/kubernetes
ARG KUBECTL_VERSION=1.37.2
ARG KUBECTL_SHA256=c04487523e7aa7d1493f7808174c899db93d7a9cf57531420cd76b9bd415f8f4
RUN curl -fsSL -o /tmp/kubectl https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/amd64/kubectl \
    && echo "${KUBECTL_SHA256}  /tmp/kubectl" | sha256sum -c - \
    && install -m 0755 /tmp/kubectl /usr/local/bin/kubectl \
    && rm -f /tmp/kubectl

# --- adb : Android Debug Bridge (tablettes, caméras, kiosque) ---
# Binaire glibc extrait du SDK Android platform-tools. Google ne publie PAS de
# SHA-256 pour ces archives (repository2-3.xml = SHA-1 uniquement) : le
# ARG ADB_SHA256 est calculé par scripts/sync-download-checksums.mjs sur
# l'artefact téléchargé (jamais édité à la main), retouché dans le commit
# Renovate par postUpgradeTasks, et contre-vérifié par S-01. Extraction via
# python3 zipfile (pas d'unzip dans la base).
# renovate: datasource=custom.android-platform-tools depName=android-platform-tools
ARG ADB_VERSION=37.0.1
ARG ADB_SHA256=d230f13842f60f782a8645f9c813f8f845bf36089ea7289f28c48f17979313f1
RUN curl -fsSL -o /tmp/platform-tools.zip https://dl.google.com/android/repository/platform-tools_r${ADB_VERSION}-linux.zip \
    && echo "${ADB_SHA256}  /tmp/platform-tools.zip" | sha256sum -c - \
    && /usr/local/bin/python3 -m zipfile -e /tmp/platform-tools.zip /tmp/pt \
    && install -m 0755 /tmp/pt/platform-tools/adb /usr/local/bin/adb \
    && rm -rf /tmp/pt /tmp/platform-tools.zip

# --- entire : CLI Entire + plugins graph & brain (entireio, licence MIT) ---
# entire-graph : carte de repo précomputée (tree-sitter, 36 langages, 100 % local,
# zéro réseau/zéro clé) ; entire-brain : mémoire BM25 des sessions/docs.
# Aucun secret (règle no-secrets). ENTIRE_PLUGIN_DIR en SYSTEME (pas $HOME) pour
# que les plugins soient visibles par tous les utilisateurs du conteneur.
# S-01 : le CLI lui-même vérifie le checksums.txt de chaque release de plugin
# (refus si absent) — donc pas d'ARG _SHA256 pour les plugins, contrairement aux
# outils téléchargés en curl direct ci-dessus. --pin = versions figées (builds
# reproductibles), bumpées par Renovate. Prérequis : git ≥ 2.36 (présent).
# renovate: datasource=github-releases depName=entireio/cli
ARG ENTIRE_CLI_VERSION=0.13.1
ARG ENTIRE_CLI_SHA256=c7afbecd5e18bee7a97b69ec318ff9f14033994eae309746c98ec7eed9c33048
# renovate: datasource=github-releases depName=entireio/entire-graph
ARG ENTIRE_GRAPH_VERSION=0.6.0
# renovate: datasource=github-releases depName=entireio/entire-brain
ARG ENTIRE_BRAIN_VERSION=0.5.1
ENV ENTIRE_PLUGIN_DIR=/usr/local/share/entire
RUN curl -fsSL -o /tmp/entire.tar.gz https://github.com/entireio/cli/releases/download/v${ENTIRE_CLI_VERSION}/entire_linux_amd64.tar.gz \
    && echo "${ENTIRE_CLI_SHA256}  /tmp/entire.tar.gz" | sha256sum -c - \
    && tar xz -C /tmp -f /tmp/entire.tar.gz \
    && install -m 0755 /tmp/entire /usr/local/bin/entire \
    && install -m 0755 /tmp/git-remote-entire /usr/local/bin/git-remote-entire \
    && rm -rf /tmp/entire /tmp/git-remote-entire /tmp/completions /tmp/LICENSE /tmp/README.md /tmp/entire.tar.gz \
    && entire plugin install graph --yes --pin v${ENTIRE_GRAPH_VERSION} \
    && entire plugin install brain --yes --pin v${ENTIRE_BRAIN_VERSION} \
    && chmod -R a+rX /usr/local/share/entire

# --- entire-agent-hermes : adaptateur Entire ↔ Hermes (preview) ---
# Copie UNIQUEMENT le binaire produit par le stage builder (pas de mise dans
# l'image finale). Pas de `entire enable` ici : c'est une étape runtime
# par-repo (écrit dans le profil HERMES_HOME + .entire/settings.json).
# Pas d'ARG _SHA256 : aucun artefact curl — ancre = commit EXTERNAL_AGENTS_REF
# (voir AGENTS.md, même classe documentaire que adb/pandoc sans checksum amont).
#
# HERMES_HOME : la base nousresearch/hermes-agent épingle déjà
# ENV HERMES_HOME=/opt/data (home du user hermes + VOLUME). L'adaptateur refuse
# les profils implicites ~/.hermes ; on réaffirme le MÊME chemin (égal au path
# effectif actuel / PVC Léo). Ne PAS déplacer le profil. vps-infra n'a pas à
# ajouter HERMES_HOME : l'ENV image survit au Deployment (qui monte déjà le PVC
# à /opt/data et n'écrase pas cette variable).
COPY --from=entire-agent-hermes-builder /out/entire-agent-hermes /usr/local/bin/entire-agent-hermes
ENV HERMES_HOME=/opt/data
RUN test -x /usr/local/bin/entire-agent-hermes

# --- go : toolchain Go (compiler/tester les repos Go : opencode-usage-tracker...) ---
# Version épinglée + Renovate (datasource golang-version). ~300 Mo — nécessaire
# pour `go build/test` depuis le pod (binaire nu inutilisable sans GOROOT).
# Placé en dernier (couche la plus lourde) pour préserver le cache des autres.
# renovate: datasource=golang-version depName=golang
ARG GO_VERSION=1.27.3
ARG GO_SHA256=65efbc80fdc1fa2cd2631cad5b481777a68e8725f34e89f50fc6ac714e379b40
RUN curl -fsSL -o /tmp/go.tar.gz https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz \
    && echo "${GO_SHA256}  /tmp/go.tar.gz" | sha256sum -c - \
    && tar xz -C /usr/local -f /tmp/go.tar.gz \
    && rm -f /tmp/go.tar.gz \
    && ln -s /usr/local/go/bin/go /usr/local/bin/go \
    && ln -s /usr/local/go/bin/gofmt /usr/local/bin/gofmt

# --- pandoc : convertisseur de documents (Markdown → docx/epub…) — demande Camille ---
# Télécharge dans un fichier temporaire, vérifie le SHA-256, PUIS extrait.
# jgm/pandoc ne publie AUCUN SHA-256 par release : la valeur « publiée » est le
# SHA-256 recalculé sur l'artefact téléchargé (même logique que adb) — jamais
# éditée à la main, `--write` la recalcule. S-01 = trivial (le pin est le seul
# ancre), à documenter comme tel dans AGENTS.md.
# renovate: datasource=github-releases depName=jgm/pandoc
ARG PANDOC_VERSION=3.13
ARG PANDOC_SHA256=38aa33b325a2bc96a4c39409631212db55702f564250bcdbead180b3bf646389
RUN curl -fsSL -o /tmp/pandoc.tar.gz https://github.com/jgm/pandoc/releases/download/${PANDOC_VERSION}/pandoc-${PANDOC_VERSION}-linux-amd64.tar.gz \
    && echo "${PANDOC_SHA256}  /tmp/pandoc.tar.gz" | sha256sum -c - \
    && tar -xzf /tmp/pandoc.tar.gz -C /tmp \
    && install -m 0755 /tmp/pandoc-${PANDOC_VERSION}/bin/pandoc /usr/local/bin/pandoc \
    && rm -rf /tmp/pandoc-${PANDOC_VERSION} /tmp/pandoc.tar.gz

# --- hermes sur le PATH « standard » (compat K8s / PATH écrasé) ---
# Depuis v0.21.6, main-wrapper.sh et dashboard/run n'activent plus le venv
# (`. /opt/hermes/.venv/bin/activate` retiré) et s'appuient uniquement sur
# `ENV PATH=/opt/hermes/bin:/opt/hermes/.venv/bin:…` du Dockerfile amont.
# Kubernetes (et tout `docker run -e PATH=…`) remplace ce PATH par un PATH
# classique sans /opt/hermes/* : `s6-setuidgid` → `s6-applyuidgid` échoue
# alors avec `unable to exec hermes: No such file or directory` (exit 127),
# le gateway ne démarre jamais. Le shim amont (`/opt/hermes/bin/hermes`)
# ré-exécute le binaire venv par chemin absolu ; un symlink dans
# /usr/local/bin suffit donc à le rendre trouvable même si PATH est écrasé.
RUN ln -sf /opt/hermes/bin/hermes /usr/local/bin/hermes

# --- Passage de relais du gateway (RollingUpdate K8s sans coupure longue) ---
# Exception assumée à « binaires seulement » : deux petits scripts shell, sans
# dépendance (flock = util-linux et curl sont déjà dans la base).
#   - /etc/cont-init.d/019-gateway-handoff : après 01-hermes-setup, AVANT
#     02-reconcile-profiles (qui démarre le gateway). Si l'ancien pod tient
#     encore $HERMES_HOME/gateway.lock (flock exclusif amont, PVC partagé), le
#     pod passe en standby (Ready) et attend que le verrou se libère (SIGTERM
#     de l'ancien pod par K8s), puis laisse démarrer le gateway. Sans autre pod
#     (Recreate, redémarrage), il passe immédiatement. Désactivable par
#     HERMES_HANDOFF_DISABLE=1 ; plafond HERMES_HANDOFF_MAX_WAIT (600 s).
#   - /usr/local/bin/hermes-probe : sonde K8s (exec) = OK en standby, sinon
#     /health du gateway.
# S6_CMD_WAIT_FOR_SERVICES_MAXTIME=0 : pas de délai sur les cont-init (défaut
# s6-overlay ≥ 3.1.6.2, fixé explicitement pour qu'une attente de relais ne
# soit jamais tuée si la base changeait ce défaut).
# HERMES_HANDOFF_VERSION : à incrémenter à chaque modification de ces scripts.
# C'est un `ARG *_VERSION=` : auto-release.yml ne crée une release (donc une
# image) que si une telle ligne ou le FROM change.
ARG HERMES_HANDOFF_VERSION=1
ENV S6_CMD_WAIT_FOR_SERVICES_MAXTIME=0
COPY --chmod=0755 rootfs/etc/cont-init.d/019-gateway-handoff /etc/cont-init.d/019-gateway-handoff
COPY --chmod=0755 rootfs/usr/local/bin/hermes-probe /usr/local/bin/hermes-probe
RUN echo "hermes-handoff=${HERMES_HANDOFF_VERSION}" \
    && test -x /usr/bin/flock \
    && test -x /usr/bin/curl \
    && test -x /command/s6-setuidgid \
    && id hermes >/dev/null

# Les scripts/venvs/skills restent sur le PVC (/opt/data) et les ConfigMaps —
# l'image ne porte que les binaires système/tools (+ les 2 scripts de relais
# ci-dessus).