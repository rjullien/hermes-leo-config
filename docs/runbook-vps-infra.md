# Runbook — actions à mener dans BaptTF/vps-infra (F-03, S-04)

Deux constats d'audit ne se corrigent PAS dans ce dépôt : ils concernent le
manifeste Kubernetes du pod `hermes-leo`, qui vit dans
[`BaptTF/vps-infra`](https://github.com/BaptTF/vps-infra)
(`workloads/agents/hermes-leo/hermes-leo-deployment.yaml`), déployé par ArgoCD.

Ce dépôt n'a que des droits `pull` sur `BaptTF/vps-infra` ; un changement doit
passer par une PR cross-fork mergée par Baptiste. Ce runbook décrit les
modifications à appliquer et les vérifications d'acceptation. Les valeurs
proposées sont à valider par un smoke test du runtime Hermes complet, pas
seulement des 5 outils.

## F-03 — Persistance des credentials Devin

**Problème.** L'image utilise `HOME=/root`, mais Devin écrit ses credentials
sous `~/.local/share/devin/credentials.toml`. Le volume persistant est
`/opt/data`. Sans configuration explicite, les credentials ne survivent pas à la
recréation du pod, et en non-root `/opt/data` n'est pas inscriptible par défaut.

**À faire dans le deployment :**

1. Vérifier le chemin réellement écrit par la version de Devin installée
   (`devin auth status` puis inspection du fichier), plutôt que de le supposer.
2. Faire pointer la persistance de ce chemin vers `/opt/data`, au choix :
   - définir `HOME=/opt/data` (ou un sous-dossier) via `env:` ; ou
   - monter le PVC sur le chemin exact de credentials Devin.
3. Aligner `securityContext.fsGroup` et le propriétaire du PVC avec l'UID/GID
   d'exécution (voir S-04) pour que l'écriture soit possible.

**Acceptation :**

- `devin auth status` reste `Logged in` après suppression/recréation du pod ;
- l'écriture des credentials ne nécessite pas root ;
- aucun credential n'apparaît dans une couche d'image ni dans les logs.

## S-04 — Durcissement du securityContext et RBAC

**Problème.** L'image (et sa base) s'exécutent en root. Le smoke test d'audit a
montré que les 5 outils fonctionnent avec un contexte durci ; le runtime Hermes
complet doit être validé de la même façon.

**securityContext cible (à tester d'abord en non bloquant) :**

```yaml
securityContext:
  allowPrivilegeEscalation: false
  capabilities:
    drop: ["ALL"]
  readOnlyRootFilesystem: true
  seccompProfile:
    type: RuntimeDefault
  # Étape suivante, après préparation des permissions du PVC :
  # runAsNonRoot: true
  # runAsUser: <UID non-root>
  # runAsGroup: <GID>
  # fsGroup: <GID>   # pour que /opt/data soit inscriptible
```

Migration recommandée en deux temps : d'abord capabilities/seccomp/rootfs
read-only en gardant root, puis bascule non-root une fois `/opt/data` préparé.

**RBAC kubectl :** l'audit note un usage « read-only » annoncé. Vérifier que le
`ServiceAccount` du pod ne dispose que des verbes de lecture nécessaires
(`get`/`list`/`watch` sur pods, logs), sans droits d'écriture/suppression, et
pas de `cluster-admin`.

**NetworkPolicies :** restreindre les flux sortants aux seules destinations
nécessaires (API GitHub, Google, static.devin.ai, API k8s), si la politique du
cluster le permet.

**Acceptation :**

- Hermes et les 5 outils passent un smoke test sous le securityContext cible ;
- `/opt/data` est la seule zone d'écriture persistante nécessaire ;
- le ServiceAccount ne peut pas modifier/supprimer de ressources si l'usage est
  read-only ;
- aucun mount hôte sensible n'est exposé.

## Rappels de contexte (mémoire projet)

- Le cluster lit **exclusivement** `BaptTF/vps-infra` ; `rjullien/vps-infra` est
  un fork sans effet sur la prod. Ne pas diagnostiquer la prod via le fork.
- Ne jamais annoncer « déployé » sur la base d'un merge dans le fork : le
  maximum vérifiable côté ce dépôt est « image publiée sur GHCR + CI verte ».
- Le gateway Hermes lit `API_SERVER_KEY` depuis `/opt/data/.env` sur le PVC, pas
  depuis les variables d'env K8s — en tenir compte lors des changements de
  montage `/opt/data` (F-03) pour ne pas casser cette lecture.
