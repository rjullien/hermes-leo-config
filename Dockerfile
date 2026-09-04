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
FROM nousresearch/hermes-agent:v2026.8.16@sha256:f8f548d87d16634d1ad9e3777280f3f577ba2358703f04e18e74007ffd3621bf

# Ordre des couches (P-02) : chaque couple `# renovate` + ARG version + ARG
# SHA256 est placé JUSTE avant le RUN qui l'utilise, du plus léger au plus lourd
# (gws → gh → kubectl → devin → go). Ainsi, changer la version d'un outil
# n'invalide QUE sa couche et les suivantes, pas les précédentes.
# Chaque outil a un SHA-256 attendu (S-01) : téléchargement vérifié AVANT
# extraction. Renovate maintient version + digest (voir renovate.json).
USER root

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
ARG GH_VERSION=2.99.0
ARG GH_SHA256=ed4960225d2833e04a61590d9fa2b5773d147f3aa375459e5466a40c102f3832
RUN curl -fsSL -o /tmp/gh.tar.gz https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_amd64.tar.gz \
    && echo "${GH_SHA256}  /tmp/gh.tar.gz" | sha256sum -c - \
    && tar xz -C /tmp -f /tmp/gh.tar.gz \
    && cp /tmp/gh_${GH_VERSION}_linux_amd64/bin/gh /usr/local/bin/gh \
    && rm -rf /tmp/gh_${GH_VERSION}_linux_amd64 /tmp/gh.tar.gz \
    && chmod +x /usr/local/bin/gh

# --- kubectl : debug cluster ---
# renovate: datasource=github-tags depName=kubernetes/kubernetes
ARG KUBECTL_VERSION=1.37.0
ARG KUBECTL_SHA256=6129359f4e1f3848a5572ccb0b26cf28b8ca08cef38c95a765b2f64a2c961a2f
RUN curl -fsSL -o /tmp/kubectl https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/amd64/kubectl \
    && echo "${KUBECTL_SHA256}  /tmp/kubectl" | sha256sum -c - \
    && install -m 0755 /tmp/kubectl /usr/local/bin/kubectl \
    && rm -f /tmp/kubectl

# --- devin : Devin CLI (agent IA) ---
# Binaire seul (le tar contient bin/devin + share/docs, on n'extrait que bin/)
# Auth: `devin auth login` (device flow) ou `--force-manual-token-flow` (pod headless)
# Credentials → ~/.local/share/devin/credentials.toml (PVC /opt/data, persistant)
# renovate: datasource=custom depName=devin-cli
ARG DEVIN_VERSION=3000.6.7
ARG DEVIN_SHA256=f88edacea692553910d72f275515bd0b52b5d271d55250981b0c41011142d27b
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
ARG GO_VERSION=1.27.1
ARG GO_SHA256=675c26c449cbb18fc24b74650de1eabbae6e16f64326fd85a283fb3b58280685
RUN curl -fsSL -o /tmp/go.tar.gz https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz \
    && echo "${GO_SHA256}  /tmp/go.tar.gz" | sha256sum -c - \
    && tar xz -C /usr/local -f /tmp/go.tar.gz \
    && rm -f /tmp/go.tar.gz \
    && ln -s /usr/local/go/bin/go /usr/local/bin/go \
    && ln -s /usr/local/go/bin/gofmt /usr/local/bin/gofmt

# Les scripts/venvs/skills restent sur le PVC (/opt/data) et les ConfigMaps —
# l'image ne porte que les binaires système/tools.