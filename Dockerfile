# Image custom Hermes Léo — image officielle + outils Google Workspace (gws)
# Pattern: rjullien/nullclaw-lea-config (image custom agent + Renovate)
#
# gws = Google Workspace CLI officiel (Gmail, Tasks, Calendar, Drive...)
# - remplace l'ancien gws-axi 0.6.1 (sans support Tasks)
# - la version est trackée par Renovate (regex manager dans renovate.json)
#
# Base: image officielle hermes-agent (debian:13.4, glibc → binaire gnu, PAS musl)

FROM nousresearch/hermes-agent:v2026.8.16

# Pinned versions (Renovate auto-updates via regex manager)
# renovate: datasource=github-releases depName=googleworkspace/cli
ARG GWS_VERSION=0.22.5

USER root

# Google Workspace CLI (gws) — remplace mcp-gsuite + himalaya
# Binaire glibc (debian) — NE PAS utiliser -musl (image Alpine uniquement)
RUN curl -fsSL https://github.com/googleworkspace/cli/releases/download/v${GWS_VERSION}/google-workspace-cli-x86_64-unknown-linux-gnu.tar.gz \
    | tar xz -C /usr/local/bin --strip-components=0 ./gws \
    && chmod +x /usr/local/bin/gws

# Retour à l'utilisateur standard Hermes (vérifier le USER final de l'image
# officielle avant de figer; s6-overlay gère les process en UID 10000)