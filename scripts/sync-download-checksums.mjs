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
// POURQUOI DEUX SOURCES (S-01)
// Pour chaque outil on récupère le checksum PUBLIÉ en amont, puis on télécharge
// l'artefact et on recalcule son SHA-256 nous-mêmes. Aucune valeur n'est écrite
// si les deux ne concordent pas. La valeur commitée reste ainsi une attente
// attestée indépendamment, et non un checksum accordé aveuglément au moment du
// build (c'est précisément ce que perdrait une résolution à la volée dans le
// Dockerfile).
//
// CONTRAINTE : SANS DÉPENDANCE
// Ce script tourne dans le conteneur ghcr.io/renovatebot/renovate, qui embarque
// Node mais ne garantit ni curl ni jq. Il doit donc rester en ESM pur, n'utiliser
// que les modules `node:` et le `fetch` global, et le dépôt ne doit contenir ni
// package.json ni node_modules.
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

async function httpGet(url) {
  const res = await fetch(url, { redirect: 'follow', headers: { 'user-agent': USER_AGENT } });
  if (!res.ok) {
    throw new Error(`HTTP ${res.status} ${res.statusText} sur ${url}`);
  }
  return res;
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

/** SHA-256 calculé en flux : l'archive Go fait ~300 Mo, on ne la bufferise pas. */
async function computeSha256(url) {
  const res = await httpGet(url);
  if (!res.body) {
    throw new Error(`Réponse sans corps pour ${url}`);
  }
  const hash = createHash('sha256');
  for await (const chunk of Readable.fromWeb(res.body)) {
    hash.update(chunk);
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

/** Lit version + checksum commité de chaque outil ; échoue si une ligne manque. */
function parseDockerfile(content) {
  const parsed = new Map();
  const missing = [];
  for (const tool of TOOLS) {
    const version = content.match(versionRegex(tool.prefix))?.[1];
    const sha256 = content.match(shaRegex(tool.prefix))?.[1];
    if (!version) missing.push(`ARG ${tool.prefix}_VERSION=`);
    if (sha256 === undefined) missing.push(`ARG ${tool.prefix}_SHA256=`);
    parsed.set(tool.prefix, { version, sha256 });
  }
  if (missing.length > 0) {
    throw new Error(
      `Dockerfile incomplet : ligne(s) introuvable(s) -> ${missing.join(', ')}. ` +
        'Les 5 couples version/SHA256 doivent rester présents et sur une seule ligne ' +
        '(voir AGENTS.md et la disposition des couches P-02).',
    );
  }
  return parsed;
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

async function resolveChecksum(tool, version) {
  const { url, body, value } = await tool.upstream(version, tool);
  if (typeof value !== 'string' || !HEX64.test(value)) {
    throw new Error(
      `Checksum amont invalide pour ${tool.prefix} ${version} : ` +
        `la source ${url} n'a pas fourni 64 caractères hexadécimaux ` +
        `(valeur extraite : ${JSON.stringify(value)}).\n` +
        `Début de la réponse (200 premiers caractères) :\n${String(body).slice(0, 200)}`,
    );
  }

  const artifactUrl = tool.artifact(version);
  const computed = await computeSha256(artifactUrl);
  if (computed !== value) {
    throw new Error(
      `Contre-vérification ÉCHOUÉE pour ${tool.prefix} ${version} (${tool.label}).\n` +
        `  artefact          : ${artifactUrl}\n` +
        `  checksum publié   : ${value} (${url})\n` +
        `  checksum recalculé: ${computed}\n` +
        'Aucune valeur n\'est écrite : les deux sources doivent concorder (S-01).',
    );
  }
  return { value, url: artifactUrl };
}

// --- CLI -------------------------------------------------------------------

const USAGE = `Usage : node scripts/sync-download-checksums.mjs [options]

Synchronise les ARG <OUTIL>_SHA256 du Dockerfile avec les ARG <OUTIL>_VERSION,
en croisant le checksum publié en amont et un SHA-256 recalculé localement.

Options :
  --check          (défaut) ne modifie rien, sort en 1 si un checksum commité
                   diffère de la valeur amont vérifiée
  --write          réécrit la ligne ARG <OUTIL>_SHA256 des outils concernés
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
  const state = parseDockerfile(content);

  let mismatches = 0;
  let rewritten = 0;

  for (const tool of selected) {
    const { version, sha256: committed } = state.get(tool.prefix);
    const { value } = await resolveChecksum(tool, version);

    if (value === committed) {
      console.log(`${tool.prefix.padEnd(8)} ${version.padEnd(10)} OK       ${value}`);
      continue;
    }

    mismatches += 1;
    if (options.mode === 'write') {
      content = rewriteSha(content, tool.prefix, value);
      rewritten += 1;
      console.log(`${tool.prefix.padEnd(8)} ${version.padEnd(10)} MISMATCH réécrit`);
      console.log(`  - Dockerfile : ${committed}`);
      console.log(`  + amont      : ${value}`);
    } else {
      console.log(`${tool.prefix.padEnd(8)} ${version.padEnd(10)} MISMATCH`);
      console.log(`  - Dockerfile : ${committed}`);
      console.log(`  + amont      : ${value}`);
    }
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
    `Résumé : ${selected.length} outil(s) vérifié(s), ${mismatches} écart(s).` +
      (mismatches > 0
        ? ' Relancer `node scripts/sync-download-checksums.mjs --write` pour corriger.'
        : ''),
  );
  return mismatches > 0 ? 1 : 0;
}

try {
  process.exitCode = await main();
} catch (error) {
  console.error(`ERREUR : ${error instanceof Error ? error.message : error}`);
  process.exitCode = 1;
}
