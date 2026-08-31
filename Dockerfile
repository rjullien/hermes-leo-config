# Image custom Hermes Léo — image officielle + outils agents
# Pattern: rjullien/nullclaw-lea-config (image custom agent + Renovate)
#
# Outils ajoutés (tous absents de l'image officielle hermes-agent) :
#   - gws      : Google Workspace CLI (Gmail, Tasks, Calendar, Drive) — remplace gws-axi 0.6.1 ET himalaya
#   - gh       : GitHub CLI (issues, PRs, releases)
#   - kubectl  : debug cluster (lecture pods/logs)
#
# Base: image officielle hermes-agent (debian:13.4, glibc → binaires gnu, PAS musl)

FROM nousresearch/hermes-agent:v2026.8.19

# Pinned versions (Renovate auto-updates via regex manager, voir renovate.json)
# renovate: datasource=github-releases depName=googleworkspace/cli
ARG GWS_VERSION=0.22.5
# renovate: datasource=github-releases depName=cli/cli
ARG GH_VERSION=2.98.0
# renovate: datasource=github-tags depName=kubernetes/kubernetes
ARG KUBECTL_VERSION=1.31.0

USER root

# --- gws : Google Workspace CLI (glibc/debian, pas de -musl) ---
# Remplace himalaya pour tout le Gmail automatisé (API native, OAuth standard)
RUN curl -fsSL https://github.com/googleworkspace/cli/releases/download/v${GWS_VERSION}/google-workspace-cli-x86_64-unknown-linux-gnu.tar.gz \
    | tar xz -C /usr/local/bin --strip-components=0 ./gws \
    && chmod +x /usr/local/bin/gws

# --- gh : GitHub CLI ---
RUN curl -fsSL https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_amd64.tar.gz \
    | tar xz -C /tmp \
    && cp /tmp/gh_${GH_VERSION}_linux_amd64/bin/gh /usr/local/bin/gh \
    && rm -rf /tmp/gh_${GH_VERSION}_linux_amd64 \
    && chmod +x /usr/local/bin/gh

# --- kubectl : debug cluster ---
RUN curl -fsSL -o /usr/local/bin/kubectl https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/amd64/kubectl \
    && chmod +x /usr/local/bin/kubectl

# Les scripts/venvs/skills restent sur le PVC (/opt/data) et les ConfigMaps —
# l'image ne porte que les binaires système/tools.