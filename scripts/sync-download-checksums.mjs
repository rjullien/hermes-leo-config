#!/usr/bin/env node
// sync-download-checksums.mjs — synchronise les `ARG <OUTIL>_SHA256` du Dockerfile
// avec les `ARG <OUTIL>_VERSION` correspondants.
//
// POURQUOI CE SCRIPT EXISTE
// Le Dockerfile épingle, pour chacun des 5 outils (gws, gh, kubectl, devin, go),
// une version ET le SHA-256 attendu de l'artefact téléchargé (finding S-01 :
// le téléchargement est vérifié AVANT extraction). Renovate sait bumper l'ARG
// version, mais aucune des datasources utilisées (github-releases, github-tags,
// golang-version, custom) ne sait fournir le SHA-256 d'une archive sous forme de
// `currentDigest` : Renovate échoue, abandonne la recherche, ou écrit un SHA de
// commit git sans rapport. Le SHA-256 restait donc périmé et le build cassait sur
// `sha256sum -c`. Ce script est le maillon manquant : c'est lui qui recalcule le
// SHA-256 après un bump de version (voir renovate.json postUpgradeTasks) et c'est
// lui qui vérifie l'accord version/checksum en CI (mode --check).
//
// POURQUOI DEUX SOURCES, ET CE QUE ÇA NE COUVRE PAS (S-01)
// Avant d'écrire une valeur, on récupère le checksum PUBLIÉ en amont, puis on
// télécharge l'artefact et on recalcule son SHA-256 nous-mêmes ; rien n'est
// écrit si les deux ne concordent pas. Attention à la portée réelle de cette
// contre-vérification : pour un outil donné, le checksum publié et l'artefact
// viennent du MÊME éditeur, sur le MÊME domaine et la même chaîne TLS. Elle
// attrape un téléchargement tronqué, un cache/miroir divergent, une publication
// incohérente — PAS un éditeur qui publierait un artefact malveillant avec le
// checksum correspondant (compromission de compte de release). Ce qui reste
// acquis vs une résolution à la volée dans le Dockerfile : la valeur est figée
// dans le dépôt, relisible dans le diff de la PR, et rejouée au build contre le
// CDN. Le seul délai humain sur ce chemin est `minimumReleaseAge` (3 jours).
//
// MODES ET CODES DE SORTIE
// --check : un écart entre le checksum commité et le checksum publié en amont
//   sort 1 (c'est le seul cas que la garde doit faire échouer). Un amont
//   injoignable (5xx, asset retiré, throttling) est retenté puis signalé en
//   AVERTISSEMENT sans faire échouer le job : une indisponibilité amont ne doit
//   pas rendre `main` non mergeable alors que l'image reste construisible.
//   Chemin OK : aucun artefact n'est retéléchargé, le `sha256sum -c` du build
//   recalcule déjà le hash de l'archive réellement téléchargée. L'artefact n'est
//   téléchargé que si un écart est détecté, pour trancher lequel des deux a
//   raison avant d'échouer.
// --write : tout échec est fatal (exit 1, rien n'est écrit) pour que Renovate
//   remonte un `artifactErrors` visible dans la PR plutôt qu'un checksum faux.
//
// CONTRAINTE : SANS DÉPENDANCE
// Ce script tourne dans le conteneur ghcr.io/renovatebot/renovate, qui embarque
// Node mais ne garantit ni curl ni jq. Il doit donc rester en ESM pur, n'utiliser
// que les modules `node:` et le `fetch` global, et le dépôt ne doit contenir ni
// package.json ni node_modules.
//
// TABLE `TOOLS` ↔ LIGNES `RUN` DU DOCKERFILE
// La table ci-dessous duplique les URLs d'artefacts des `RUN curl` du Dockerfile.
// Une divergence (renommage d'asset amont, passage de gws en -musl…) donnerait
// une garde verte et un build rouge. Pour fermer la boucle, chaque URL est
// recroisée avec le Dockerfile AVANT tout appel réseau : l'URL modèle
// (`${<OUTIL>_VERSION}` en place de la version) doit apparaître telle quelle
// dans le Dockerfile, sinon on échoue en nommant les deux valeurs. Corollaire
// assumé : retirer un outil de l'image (règle 4 d'AGENTS.md) impose d'éditer
// cette table dans le même commit.
//
// PIÈGE GO : https://go.dev/dl/goX.Y.Z.linux-amd64.tar.gz.sha256 N'EXISTE PAS en
// tant que checksum : cette URL renvoie une page HTML. Le checksum Go se lit sur
// https://go.dev/dl/?mode=json&include=all. Tout checksum extrait est validé
// contre /^[0-9a-f]{64}$/ avant usage, pour qu'une réponse HTML ne puisse jamais
// finir dans le Dockerfile.
//
// Usage : node scripts/sync-download-checksums.mjs [--check|--write] [--only=<outil>]

import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import process from 'node:process';
import { Readable } from 'node:stream';
import { fileURLToPath } from 'node:url';

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const DOCKERFILE = join(SCRIPT_DIR, '..', 'Dockerfile');
const HEX64 = /^[0-9a-f]{64}$/;
const USER_AGENT = 'hermes-leo-config-sync-download-checksums';
const HTTP_TIMEOUT_MS = 60_000;
const HTTP_ATTEMPTS = 3;
const HTTP_RETRY_DELAY_MS = 2_000;
// Statuts qui décrivent une indisponibilité passagère, donc retentables.
// Un 404 ne l'est pas : l'asset n'existe pas (encore), retenter est inutile.
const RETRYABLE_STATUS = new Set([408, 425, 429, 500, 502, 503, 504]);

// --- Table des outils ------------------------------------------------------
// `prefix`  : préfixe des ARG dans le Dockerfile (ARG <prefix>_VERSION / _SHA256)
// `aliases` : noms acceptés par --only, y compris les depName Renovate
// `artifact`: URL de l'artefact réellement téléchargé par le Dockerfile
// `upstream`: résolution du checksum publié en amont -> { url, body, value }
const TOOLS = [
  {
    prefix: 'GWS',
    label: 'Google Workspace CLI',
    aliases: ['gws', 'googleworkspace/cli', 'google-workspace-cli'],
    artifact: (v) =>
      `https://github.com/googleworkspace/cli/releases/download/v${v}/google-workspace-cli-x86_64-unknown-linux-gnu.tar.gz`,
    // Corps de la forme « <hex>  <nom de fichier> » : on prend le premier champ.
    upstream: async (v, tool) => {
      const url = `${tool.artifact(v)}.sha256`;
      const body = await httpText(url);
      return { url, body, value: body.trim().split(/\s+/)[0] };
    },
  },
  {
    prefix: 'GH',
    label: 'GitHub CLI',
    aliases: ['gh', 'cli/cli', 'github-cli'],
    artifact: (v) =>
      `https://github.com/cli/cli/releases/download/v${v}/gh_${v}_linux_amd64.tar.gz`,
    // Le fichier liste aussi les .deb et .rpm : on compare le nom de fichier
    // à l'identique, jamais par sous-chaîne.
    upstream: async (v) => {
      const url = `https://github.com/cli/cli/releases/download/v${v}/gh_${v}_checksums.txt`;
      const body = await httpText(url);
      const wanted = `gh_${v}_linux_amd64.tar.gz`;
      let value;
      for (const line of body.split('\n')) {
        const [hex, file] = line.trim().split(/\s+/);
        if (file === wanted) {
          value = hex;
          break;
        }
      }
      return { url, body, value };
    },
  },
  {
    prefix: 'KUBECTL',
    label: 'kubectl',
    aliases: ['kubectl', 'kubernetes/kubernetes', 'kubernetes'],
    // Binaire nu, pas une archive : le checksum porte sur le binaire lui-même.
    artifact: (v) => `https://dl.k8s.io/release/v${v}/bin/linux/amd64/kubectl`,
    // Hex brut, sans nom de fichier et sans garantie de saut de ligne final.
    upstream: async (v, tool) => {
      const url = `${tool.artifact(v)}.sha256`;
      const body = await httpText(url);
      return { url, body, value: body.trim() };
    },
  },
  {
    prefix: 'DEVIN',
    label: 'Devin CLI',
    aliases: ['devin', 'devin-cli'],
    artifact: (v) =>
      `https://static.devin.ai/cli/${v}/devin-${v}-x86_64-unknown-linux.tar.gz`,
    // Manifeste de LA version demandée (pas /cli/current/manifest.json, qui
    // renvoie toujours la plus récente).
    upstream: async (v) => {
      const url = `https://static.devin.ai/cli/${v}/manifest.json`;
      const body = await httpText(url);
      return { url, body, value: parseJson(body)?.platforms?.['x86_64-unknown-linux']?.sha256 };
    },
  },
  {
    prefix: 'GO',
    label: 'toolchain Go',
    aliases: ['go', 'golang', 'golang-version'],
    artifact: (v) => `https://go.dev/dl/go${v}.linux-amd64.tar.gz`,
    // go.dev ne publie PAS de .sha256 par archive : l'index JSON est la seule
    // source fiable.
    upstream: async (v) => {
      const url = 'https://go.dev/dl/?mode=json&include=all';
      const body = await httpText(url);
      const releases = parseJson(body);
      const release = Array.isArray(releases)
        ? releases.find((r) => r?.version === `go${v}`)
        : undefined;
      const file = release?.files?.find(
        (f) => f?.os === 'linux' && f?.arch === 'amd64' && f?.kind === 'archive',
      );
      return { url, body, value: file?.sha256 };
    },
  },
];

// --- Utilitaires réseau / parsing -----------------------------------------

/**
 * Échec imputable à l'amont (injoignable, 5xx, asset retiré, réponse illisible),
 * par opposition à un écart de checksum. `--check` le signale en avertissement,
 * `--write` le traite comme fatal. Voir l'en-tête « MODES ET CODES DE SORTIE ».
 */
class UpstreamError extends Error {
  constructor(message) {
    super(message);
    this.name = 'UpstreamError';
  }
}

function sleep(ms) {
  return new Promise((resolve) => {
    setTimeout(resolve, ms);
  });
}

function warn(message) {
  // Annotation GitHub Actions en CI, ligne lisible ailleurs.
  if (process.env.GITHUB_ACTIONS === 'true') {
    console.log(`::warning::${message.replace(/\n/g, ' ')}`);
  }
  console.warn(`AVERTISSEMENT : ${message}`);
}

/** GET avec timeout par tentative et retry sur erreur réseau / statut passager. */
async function httpGet(url) {
  let lastError;
  for (let attempt = 1; attempt <= HTTP_ATTEMPTS; attempt += 1) {
    let res;
    try {
      res = await fetch(url, {
        redirect: 'follow',
        headers: { 'user-agent': USER_AGENT },
        signal: AbortSignal.timeout(HTTP_TIMEOUT_MS),
      });
    } catch (error) {
      lastError = new UpstreamError(
        `${url} injoignable (${error instanceof Error ? error.message : error})`,
      );
      if (attempt < HTTP_ATTEMPTS) {
        await sleep(HTTP_RETRY_DELAY_MS * attempt);
        continue;
      }
      throw lastError;
    }

    if (res.ok) return res;

    // Corps non consommé : on le libère avant de retenter.
    await res.body?.cancel().catch(() => {});
    lastError = new UpstreamError(`HTTP ${res.status} ${res.statusText} sur ${url}`);
    if (RETRYABLE_STATUS.has(res.status) && attempt < HTTP_ATTEMPTS) {
      await sleep(HTTP_RETRY_DELAY_MS * attempt);
      continue;
    }
    throw lastError;
  }
  throw lastError;
}

async function httpText(url) {
  return (await httpGet(url)).text();
}

function parseJson(body) {
  try {
    return JSON.parse(body);
  } catch {
    return undefined;
  }
}

/** SHA-256 calculé en flux : l'archive Go fait 70 Mo, on ne la bufferise pas. */
async function computeSha256(url) {
  const res = await httpGet(url);
  if (!res.body) {
    throw new UpstreamError(`Réponse sans corps pour ${url}`);
  }
  const hash = createHash('sha256');
  try {
    for await (const chunk of Readable.fromWeb(res.body)) {
      hash.update(chunk);
    }
  } catch (error) {
    // Flux coupé en cours de route : amont, pas écart de checksum.
    throw new UpstreamError(
      `Téléchargement interrompu pour ${url} (${error instanceof Error ? error.message : error})`,
    );
  }
  return hash.digest('hex');
}

// --- Dockerfile ------------------------------------------------------------

function readDockerfile() {
  return readFileSync(DOCKERFILE, 'utf8');
}

function versionRegex(prefix) {
  return new RegExp(`^ARG ${prefix}_VERSION=(\\S*)$`, 'm');
}

function shaRegex(prefix) {
  return new RegExp(`^ARG ${prefix}_SHA256=(\\S*)$`, 'm');
}

/**
 * Lit version + checksum commité des outils DEMANDÉS (pas des cinq) : sous
 * `--only=golang`, un outil retiré de l'image ne doit pas faire échouer la
 * synchro de Go. La liste complète reste exigée par `--check` sans `--only`,
 * ce qui est le comportement fail-closed voulu : retirer un outil du Dockerfile
 * impose d'éditer la table TOOLS dans le même commit (AGENTS.md, règles 4 et 5).
 */
function parseDockerfile(content, tools) {
  const parsed = new Map();
  const missing = [];
  for (const tool of tools) {
    const version = content.match(versionRegex(tool.prefix))?.[1];
    const sha256 = content.match(shaRegex(tool.prefix))?.[1];
    if (!version) missing.push(`ARG ${tool.prefix}_VERSION=`);
    if (sha256 === undefined) missing.push(`ARG ${tool.prefix}_SHA256=`);
    parsed.set(tool.prefix, { version, sha256 });
  }
  if (missing.length > 0) {
    throw new Error(
      `Dockerfile incomplet : ligne(s) introuvable(s) -> ${missing.join(', ')}. ` +
        'Chaque outil géré doit garder son couple version/SHA256, chacun sur une ' +
        'seule ligne (voir AGENTS.md et la disposition des couches P-02). Si ' +
        "l'outil a été retiré de l'image, le retirer aussi de la table TOOLS de " +
        'ce script, dans le même commit.',
    );
  }
  return parsed;
}

/** URLs d'artefacts (avec `${<OUTIL>_VERSION}` non substitué) lues dans le Dockerfile. */
function dockerfileArtifactUrls(content, prefix) {
  const re = new RegExp(`https://\\S*\\$\\{${prefix}_VERSION\\}\\S*`, 'g');
  return [...content.matchAll(re)].map((m) => m[0]);
}

/**
 * Recroise l'URL de la table TOOLS avec celle réellement téléchargée par le
 * Dockerfile. Sans ça, une divergence donnerait une garde verte et un build
 * rouge sur `sha256sum -c` (exactement le symptôme opaque que ce script existe
 * pour supprimer). Vérifié avant tout appel réseau.
 */
function assertArtifactUrlMatchesDockerfile(content, tool) {
  const expected = tool.artifact(`\${${tool.prefix}_VERSION}`);
  const found = dockerfileArtifactUrls(content, tool.prefix);
  if (found.includes(expected)) return;
  throw new Error(
    `URL d'artefact divergente pour ${tool.prefix} (${tool.label}) :\n` +
      `  table TOOLS du script : ${expected}\n` +
      `  Dockerfile            : ${found.length > 0 ? found.join('\n                          ') : '(aucune URL trouvée)'}\n` +
      'Le script recalculerait le checksum d\'un autre fichier que celui que le ' +
      'build télécharge. Aligner la table TOOLS sur le `RUN curl` du Dockerfile.',
  );
}

/** Réécrit UNIQUEMENT la ligne ARG <prefix>_SHA256= ; le reste est intact. */
function rewriteSha(content, prefix, value) {
  const re = shaRegex(prefix);
  if (!re.test(content)) {
    throw new Error(`Impossible de réécrire ARG ${prefix}_SHA256= : ligne introuvable`);
  }
  return content.replace(re, `ARG ${prefix}_SHA256=${value}`);
}

// --- Résolution + contre-vérification -------------------------------------

/** Checksum publié en amont pour cette version. Échec = UpstreamError. */
async function fetchPublishedChecksum(tool, version) {
  const { url, body, value } = await tool.upstream(version, tool);
  if (typeof value !== 'string' || !HEX64.test(value)) {
    throw new UpstreamError(
      `Checksum amont invalide pour ${tool.prefix} ${version} : ` +
        `la source ${url} n'a pas fourni 64 caractères hexadécimaux ` +
        `(valeur extraite : ${JSON.stringify(value)}).\n` +
        `Début de la réponse (200 premiers caractères) :\n${String(body).slice(0, 200)}`,
    );
  }
  return { value, url };
}

/**
 * Contre-vérification S-01 : retélécharge l'artefact et recalcule son SHA-256.
 * Appelée dès que la valeur à retenir diffère de celle commitée, donc toujours
 * avant une écriture. Une divergence ici n'est PAS un simple problème d'amont :
 * c'est fatal dans les deux modes.
 */
async function verifyAgainstArtifact(tool, version, published, publishedUrl) {
  const artifactUrl = tool.artifact(version);
  const computed = await computeSha256(artifactUrl);
  if (computed !== published) {
    throw new Error(
      `Contre-vérification ÉCHOUÉE pour ${tool.prefix} ${version} (${tool.label}).\n` +
        `  artefact          : ${artifactUrl}\n` +
        `  checksum publié   : ${published} (${publishedUrl})\n` +
        `  checksum recalculé: ${computed}\n` +
        'Aucune valeur n\'est écrite : les deux sources doivent concorder (S-01).',
    );
  }
  return artifactUrl;
}

// --- CLI -------------------------------------------------------------------

const USAGE = `Usage : node scripts/sync-download-checksums.mjs [options]

Synchronise les ARG <OUTIL>_SHA256 du Dockerfile avec les ARG <OUTIL>_VERSION,
en croisant le checksum publié en amont et un SHA-256 recalculé localement.

Options :
  --check          (défaut) ne modifie rien, sort en 1 si un checksum commité
                   diffère du checksum publié en amont. Un amont injoignable
                   (5xx, asset retiré, throttling) est retenté puis signalé en
                   AVERTISSEMENT, sans faire échouer la commande.
  --write          réécrit la ligne ARG <OUTIL>_SHA256 des outils concernés.
                   Tout échec est fatal et n'écrit rien.
  --only=<outil>   limite le traitement à un outil. Accepte gws, gh, kubectl,
                   devin, go ainsi que les depName Renovate (googleworkspace/cli,
                   cli/cli, kubernetes/kubernetes, devin-cli, golang). Une valeur
                   inconnue sort en 0 sans rien écrire.
  --help           affiche cette aide

Outils gérés : ${TOOLS.map((t) => t.prefix).join(', ')}
`;

function parseArgs(argv) {
  const options = { mode: 'check', only: null, help: false };
  for (const arg of argv) {
    if (arg === '--check') options.mode = 'check';
    else if (arg === '--write') options.mode = 'write';
    else if (arg === '--help' || arg === '-h') options.help = true;
    else if (arg.startsWith('--only=')) options.only = arg.slice('--only='.length).trim();
    else throw new Error(`Option inconnue : ${arg}\n\n${USAGE}`);
  }
  return options;
}

function selectTools(only) {
  if (!only) return TOOLS;
  const needle = only.toLowerCase();
  return TOOLS.filter(
    (t) => t.prefix.toLowerCase() === needle || t.aliases.includes(needle),
  );
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  if (options.help) {
    process.stdout.write(USAGE);
    return 0;
  }

  const selected = selectTools(options.only);
  if (selected.length === 0) {
    // Cas normal en postUpgradeTasks : Renovate a bumpé une Action ou l'image de
    // base, aucun de nos 5 outils n'est concerné. Ce n'est pas une erreur.
    console.log(
      `--only=${options.only} ne correspond à aucun outil géré ` +
        `(${TOOLS.map((t) => t.aliases[0]).join(', ')}) : rien à faire.`,
    );
    return 0;
  }

  let content = readDockerfile();
  const state = parseDockerfile(content, selected);

  let mismatches = 0;
  let rewritten = 0;
  let unreachable = 0;

  for (const tool of selected) {
    const { version, sha256: committed } = state.get(tool.prefix);
    const label = `${tool.prefix.padEnd(8)} ${version.padEnd(10)}`;

    // Garde-fou hors réseau : la table TOOLS doit décrire l'artefact que le
    // Dockerfile télécharge réellement.
    assertArtifactUrlMatchesDockerfile(content, tool);

    let published;
    try {
      published = await fetchPublishedChecksum(tool, version);
    } catch (error) {
      if (options.mode === 'check' && error instanceof UpstreamError) {
        unreachable += 1;
        console.log(`${label} AMONT KO (checksum non vérifié)`);
        warn(`${tool.prefix} ${version} : ${error.message}`);
        continue;
      }
      throw error;
    }

    if (published.value === committed) {
      // Pas de retéléchargement : le `sha256sum -c` du Dockerfile recalcule
      // déjà le hash de l'artefact réellement téléchargé, à chaque build.
      console.log(`${label} OK       ${published.value}`);
      continue;
    }

    // Écart : on tranche avec l'artefact avant d'échouer ou d'écrire (S-01).
    try {
      await verifyAgainstArtifact(tool, version, published.value, published.url);
    } catch (error) {
      if (options.mode === 'check' && error instanceof UpstreamError) {
        unreachable += 1;
        console.log(`${label} AMONT KO (écart non tranché)`);
        warn(`${tool.prefix} ${version} : ${error.message}`);
        continue;
      }
      throw error;
    }

    mismatches += 1;
    if (options.mode === 'write') {
      content = rewriteSha(content, tool.prefix, published.value);
      rewritten += 1;
      console.log(`${label} MISMATCH réécrit`);
    } else {
      console.log(`${label} MISMATCH`);
    }
    console.log(`  - Dockerfile : ${committed}`);
    console.log(`  + amont      : ${published.value}`);
  }

  if (rewritten > 0) {
    writeFileSync(DOCKERFILE, content);
  }

  if (options.mode === 'write') {
    console.log(
      `Résumé : ${selected.length} outil(s) vérifié(s), ` +
        `${rewritten} ligne(s) ARG _SHA256 réécrite(s), Dockerfile ` +
        `${rewritten > 0 ? 'modifié' : 'inchangé'}.`,
    );
    return 0;
  }

  console.log(
    `Résumé : ${selected.length} outil(s) vérifié(s), ${mismatches} écart(s), ` +
      `${unreachable} amont(s) injoignable(s).` +
      (mismatches > 0
        ? ' Relancer `node scripts/sync-download-checksums.mjs --write` pour corriger.'
        : ''),
  );
  // Un amont injoignable ne fait pas échouer la garde : l'image reste
  // construisible et le `sha256sum -c` du build reste le filet final.
  return mismatches > 0 ? 1 : 0;
}

try {
  process.exitCode = await main();
} catch (error) {
  console.error(`ERREUR : ${error instanceof Error ? error.message : error}`);
  process.exitCode = 1;
}
