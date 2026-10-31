# Image custom Hermes Léo — image officielle + outils agents
# Pattern: rjullien/nullclaw-lea-config (image custom agent + Renovate)
#
# Outils ajoutés (tous absents de l'image officielle hermes-agent) :
#   - gws      : Google Workspace CLI (Gmail, Tasks, Calendar, Drive) — remplace gws-axi 0.6.1 ET himalaya
#   - gh       : GitHub CLI (issues, PRs, releases)
#   - kubectl  : debug cluster (lecture pods/logs)
#   - devin    : Devin CLI (agent IA terminal) — auth OAuth, credentials sur PVC (/opt/data), PAS dans l'image
#   - go       : toolchain Go (compiler/tester les repos Go depuis le pod : opencode-usage-tracker, etc.)
#
# Base: image officielle hermes-agent (debian:13.4, glibc → binaires gnu, PAS musl)
#
# ⚠️ SÉCURITÉ : repo PUBLIC + image ghcr.io publique — AUCUN secret/token dans ce Dockerfile.
# Les credentials (gws OAuth, devin auth, etc.) vont dans Infisical ou sur le PVC, jamais gravés ici.

# Base épinglée par digest (S-02) : reconstruire ce commit utilise toujours la
# même image, même si le tag v2026.8.16 est déplacé. Renovate maintient le
# couple tag+digest (pinDigests).
#
# ⚠️ ARCHITECTURE (P-03) : image linux/amd64 UNIQUEMENT. Les URLs ci-dessous
# ciblent x86_64/amd64 et build.yml ne construit que linux/amd64. Pour arm64,
# paramétrer via TARGETARCH et valider les 5 binaires (voir README §Architecture).
FROM nousresearch/hermes-agent:v0.22.5@sha256:9c5561579f3ffdf333401797094ac3a743738d6c25d40f4331c7bf77b694238d

# Ordre des couches (P-02) : chaque couple `# renovate` + ARG version + ARG
# SHA256 est placé JUSTE avant le RUN qui l'utilise, du plus léger au plus lourd
# (gws → gh → kubectl → devin → go). Ainsi, changer la version d'un outil
# n'invalide QUE sa couche et les suivantes, pas les précédentes.
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
ARG KUBECTL_VERSION=1.37.1
ARG KUBECTL_SHA256=65691ff77eb6fa44c908b77a1082c9f092c3b9733b5cefabec0d1104890e21a8
RUN curl -fsSL -o /tmp/kubectl https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/amd64/kubectl \
    && echo "${KUBECTL_SHA256}  /tmp/kubectl" | sha256sum -c - \
    && install -m 0755 /tmp/kubectl /usr/local/bin/kubectl \
    && rm -f /tmp/kubectl

# --- devin : Devin CLI (agent IA) ---
# Binaire seul (le tar contient bin/devin + share/docs, on n'extrait que bin/)
# Auth: `devin auth login` (device flow) ou `--force-manual-token-flow` (pod headless)
# Credentials → ~/.local/share/devin/credentials.toml (PVC /opt/data, persistant)
# renovate: datasource=custom.devin-cli depName=devin-cli
ARG DEVIN_VERSION=3000.11.3
ARG DEVIN_SHA256=83b3b113c01bf2a3e9e100db08d77e6b086806a7754f091e20831bdfe215157e
RUN curl -fsSL -o /tmp/devin.tar.gz https://static.devin.ai/cli/${DEVIN_VERSION}/devin-${DEVIN_VERSION}-x86_64-unknown-linux.tar.gz \
    && echo "${DEVIN_SHA256}  /tmp/devin.tar.gz" | sha256sum -c - \
    && tar xz -C /tmp -f /tmp/devin.tar.gz \
    && cp /tmp/bin/devin /usr/local/bin/devin \
    && rm -rf /tmp/bin /tmp/share /tmp/devin.tar.gz \
    && chmod +x /usr/local/bin/devin

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

# Les scripts/venvs/skills restent sur le PVC (/opt/data) et les ConfigMaps —
# l'image ne porte que les binaires système/tools.