#!/usr/bin/env node
// refresh-claude-stats.mjs
// Recalcule complètement le cache de statistiques (~/.claude/stats-cache.json)
// à partir de tous les fichiers de session JSONL trouvés.
//
// Usage : node refresh-claude-stats.mjs
//
// Sources scannées :
//   - ~/.claude/projects/                    (CLI sessions Mac local)
//   - ~/.claude-island/archive/              (archive additive du miroir VM Mutagen,
//     alimentée par claude-stats-scheduler.sh ; repli sur projects/ si absente)
//   - ~/Library/.../local-agent-mode-sessions/ (Desktop agent mode)
//
// Le scan complet (~17k fichiers) prend ~1-2s. Conçu pour tourner via launchd
// toutes les heures. La stratégie "scellement par jour" a été abandonnée car
// la sync Mutagen asynchrone livre les sessions VM avec un délai variable —
// figer une journée trop tôt produisait des totaux fortement sous-estimés.
//
// Correctifs portés depuis claude-stats.py (sandbox Cerema, 2026-06) :
//   1. Scan récursif complet des projects/ — inclut les transcripts des
//      subagents (<session>/subagents/) et des workflows
//      (subagents/workflows/wf_*/), et les tokens des messages
//      isSidechain=true entrent dans les compteurs de tokens.
//   2. Dédup des blocs usage par message.id — une réponse multi-tool-calls
//      est écrite sur N lignes recopiant le même usage.

import { readFileSync, writeFileSync, readdirSync, statSync, renameSync, unlinkSync, existsSync, mkdirSync } from 'fs';
import { join, basename } from 'path';
import { homedir } from 'os';
import { randomBytes } from 'crypto';

const CLAUDE_DIR = join(homedir(), '.claude');
// Le miroir Mutagen (~/.claude-island/projects) réplique les purges de la VM
// (cleanupPeriodDays 30 j côté sandbox — propagées malgré le mode one-way-safe,
// qui n'empêche que l'écrasement de modifications beta) : le total all-time
// BAISSAIT à chaque purge (17/07 : −18 sessions). On scanne donc l'archive
// additive alimentée par claude-stats-scheduler.sh (rsync sans suppression),
// avec repli sur le miroir tant que l'archive n'a pas encore été créée.
// Ne JAMAIS scanner les deux : les tokens sont dédupliqués globalement par
// message.id mais sessions/messages sont comptés par fichier (double compte).
const VM_MIRROR_DIR = join(homedir(), '.claude-island', 'projects');
const VM_ARCHIVE_DIR = join(homedir(), '.claude-island', 'archive');
const CLI_PROJECT_ROOTS = [
  join(CLAUDE_DIR, 'projects'),
  existsSync(VM_ARCHIVE_DIR) ? VM_ARCHIVE_DIR : VM_MIRROR_DIR,
];
// Snapshot d'usage exporté depuis la VM (auto-snapshot.json reformaté) :
// restitue les tokens des sessions VM purgées AVANT la mise en place de
// l'archive additive (2026-07-18), dont plus aucun transcript n'existe.
// Absent → ingestion silencieusement sautée. Format attendu :
//   { "version": 1, "events": [ { "ts": "ISO-8601", "sid": "...",
//     "input": N, "output": N, "model": "claude-..." (optionnel) } ] }
const VM_SNAPSHOT_FILE = join(homedir(), '.claude-island', 'vm-usage-snapshot.json');
const DESKTOP_AGENT_DIR = join(homedir(), 'Library', 'Application Support', 'Claude', 'local-agent-mode-sessions');
// CLAUDE_STATS_OUT : écrire ailleurs (tests) sans toucher au cache lu par l'app.
const CACHE_FILE = process.env.CLAUDE_STATS_OUT || join(CLAUDE_DIR, 'stats-cache.json');
// v3 (2026-09-23) : dailyModelTokens = input + cache_creation + output
// (intensité : tout ce qui entre neuf dans le modèle, sans les relectures de
// cache) au lieu de input + output ; ajout du coût équivalent API (USD).
const CACHE_VERSION = 3;

// ── Tarifs API (USD / million de tokens) ───────────────────────────
// Source : platform.claude.com/docs/en/about-claude/pricing, relevé le
// 2026-09-23. SOURCE UNIQUE : la table est recopiée dans stats-cache.json
// (champ `pricing`), où l'app la lit pour chiffrer le compteur live.
// Ordre significatif : le 1er motif contenu dans l'id du modèle l'emporte
// (opus-5-5 avant opus-5, fable-5-1 avant fable-5).
const PRICING = [
  ['fable-5-1',  { input: 10,  write5m: 12.5,  write1h: 20,  read: 0.25, output: 50 }],
  ['mythos-5-1', { input: 10,  write5m: 12.5,  write1h: 20,  read: 0.25, output: 50 }],
  ['fable-5',    { input: 10,  write5m: 12.5,  write1h: 20,  read: 1,    output: 50 }],
  ['mythos-5',   { input: 10,  write5m: 12.5,  write1h: 20,  read: 1,    output: 50 }],
  ['opus-5-5',   { input: 4,   write5m: 5,     write1h: 8,   read: 0.2,  output: 20 }],
  ['opus-5',     { input: 5,   write5m: 6.25,  write1h: 10,  read: 0.5,  output: 25 }],
  ['opus-4-8',   { input: 5,   write5m: 6.25,  write1h: 10,  read: 0.5,  output: 25 }],
  ['opus-4-7',   { input: 5,   write5m: 6.25,  write1h: 10,  read: 0.5,  output: 25 }],
  ['opus-4-6',   { input: 5,   write5m: 6.25,  write1h: 10,  read: 0.5,  output: 25 }],
  ['opus-4-5',   { input: 5,   write5m: 6.25,  write1h: 10,  read: 0.5,  output: 25 }],
  ['opus-4',     { input: 15,  write5m: 18.75, write1h: 30,  read: 1.5,  output: 75 }],
  ['sonnet-5',   { input: 2,   write5m: 2.5,   write1h: 4,   read: 0.2,  output: 10 }],
  ['sonnet-4',   { input: 3,   write5m: 3.75,  write1h: 6,   read: 0.3,  output: 15 }],
  ['haiku-4-5',  { input: 1,   write5m: 1.25,  write1h: 2,   read: 0.1,  output: 5 }],
  ['haiku-3-5',  { input: 0.8, write5m: 1,     write1h: 1.6, read: 0.08, output: 4 }],
];
const WEB_SEARCH_USD = 10 / 1000;
const unpricedModels = new Set();

function priceFor(model) {
  for (const [pattern, p] of PRICING) if (model.includes(pattern)) return p;
  if (model !== '<synthetic>') unpricedModels.add(model);
  return null;
}

// Coût USD d'un bloc usage. `outputOnly` : ligne ultérieure d'un même
// message.id, dont seul le delta d'output est neuf.
function usageCost(model, usage, outputTokens, outputOnly) {
  const p = priceFor(model);
  if (!p) return 0;
  // Fast mode : tarif ×2 sur toutes les catégories (Opus 5.5 / 5 / 4.8).
  const k = usage.speed === 'fast' ? 2 : 1;
  let usd = outputTokens * p.output;
  if (!outputOnly) {
    const cc = usage.cache_creation_input_tokens || 0;
    // Répartition par TTL ; absente sur les très vieux transcripts → 5 min.
    const w1h = usage.cache_creation?.ephemeral_1h_input_tokens || 0;
    const w5m = Math.max(0, cc - w1h);
    usd += (usage.input_tokens || 0) * p.input
         + w5m * p.write5m + w1h * p.write1h
         + (usage.cache_read_input_tokens || 0) * p.read;
    usd += (usage.server_tool_use?.web_search_requests || 0) * WEB_SEARCH_USD * 1e6;
  }
  return usd * k / 1e6;
}

// ── Découverte des fichiers de session ─────────────────────────────

function findSessionFiles() {
  const files = [];
  for (const root of CLI_PROJECT_ROOTS) scanCliRoot(root, files);
  findDesktopAgentFiles(DESKTOP_AGENT_DIR, files);
  return files;
}

// Walk récursif complet : les transcripts des subagents (tool Agent) vivent
// sous <projet>/<session>/subagents/, et ceux des workflows encore plus bas
// (subagents/workflows/wf_*/agent-*.jsonl) — un scan à profondeur fixe les
// ratait entièrement (≈1M tokens/jour sur les grosses journées workflow).
// Les dossiers subagents/ survivent parfois à la purge du .jsonl parent
// (cleanupPeriodDays), donc le récursif récupère aussi des jours orphelins.
function scanCliRoot(rootDir, files) {
  let entries;
  try { entries = readdirSync(rootDir, { withFileTypes: true }); }
  catch { return; }
  for (const entry of entries) {
    const full = join(rootDir, entry.name);
    if (entry.isFile() && entry.name.endsWith('.jsonl')) files.push(full);
    else if (entry.isDirectory()) scanCliRoot(full, files);
  }
}

function findDesktopAgentFiles(dir, files) {
  let entries;
  try { entries = readdirSync(dir, { withFileTypes: true }); }
  catch { return; }
  for (const entry of entries) {
    const full = join(dir, entry.name);
    if (entry.isFile() && entry.name.endsWith('.jsonl')) files.push(full);
    else if (entry.isDirectory()) findDesktopAgentFiles(full, files);
  }
}

// ── Parsing JSONL ──────────────────────────────────────────────────

function parseSessionFile(filePath) {
  const entries = [];
  const content = readFileSync(filePath, 'utf-8');
  for (const line of content.split('\n')) {
    if (!line.trim()) continue;
    try { entries.push(JSON.parse(line)); } catch {}
  }
  return entries;
}

// Réplique exacte de isTranscriptMessage du binaire Claude Code
function isMessage(entry) {
  return entry.type === 'user' || entry.type === 'assistant' ||
         entry.type === 'attachment' || entry.type === 'system' ||
         entry.type === 'progress';
}

// ── Calcul des statistiques (réplique de qyR / DuA combinés) ──────

function computeStats(files) {
  const dailyActivity = new Map();
  const dailyModelTokens = new Map();
  const hourCounts = new Map();
  const modelUsage = {};
  let totalSessions = 0;
  let totalMessages = 0;
  let totalSpeculationTimeSavedMs = 0;
  let firstSessionDate = null;
  let longestSession = null;
  // Dédup globale des blocs usage, partagée entre tous les fichiers du scan.
  // Une réponse de l'agent est écrite sur PLUSIEURS lignes JSONL partageant le
  // même message.id, sous deux formes :
  //   a) tool-calls parallèles → chaque ligne recopie le bloc `usage` complet
  //      à l'identique (output_tokens constant) ;
  //   b) blocs successifs d'une réponse streamée (texte puis tool_use) → input_tokens
  //      et cache_* restent constants mais output_tokens CROÎT ligne après ligne,
  //      seule la DERNIÈRE ligne porte l'usage final.
  // On garde donc l'usage FINAL = le plus grand output_tokens vu pour la clé :
  // input/cache comptés une seule fois (1re rencontre), puis on ajoute uniquement
  // le delta d'output révélé par les lignes suivantes. « First wins » figeait
  // l'output au tout début (~31 % de sous-comptage un jour chargé de workflows) ;
  // tout sommer recomptait les doublons (jusqu'à ×3 d'inflation). Les blocs
  // `content` restent comptés par ligne (toolCallCount). Clé = message.id,
  // fallback (sessionId, timestamp). Valeur = output_tokens déjà comptabilisé.
  const seenUsage = new Map();
  // Par jour, sur les transcripts scannés : input+output, écritures de cache
  // et coût — ratios servant à estimer au prorata le snapshot VM (sans cache).
  const dayProfile = new Map();

  for (const file of files) {
    const entries = parseSessionFile(file);
    const sessionId = basename(file, '.jsonl');

    const messages = [];
    for (const e of entries) {
      if (isMessage(e)) messages.push(e);
      else if (e.type === 'speculation-accept' && e.timeSavedMs) {
        totalSpeculationTimeSavedMs += e.timeSavedMs;
      }
    }

    // ── Tokens : tous les messages assistant, sidechains inclus ──
    // Les transcripts subagents/workflows portent isSidechain=true sur
    // toutes leurs lignes ; les exclure ferait perdre leurs tokens.
    for (const msg of messages) {
      if (msg.type !== 'assistant') continue;
      const usage = msg.message?.usage;
      const model = msg.message?.model;
      if (!usage || !model) continue;
      const msgDate = new Date(msg.timestamp);
      if (isNaN(msgDate.getTime())) continue;

      const mid = msg.message?.id;
      const key = mid ? `msg:${mid}` : `${msg.sessionId || sessionId}|${msg.timestamp}`;
      const out = usage.output_tokens || 0;
      const prevOut = seenUsage.get(key);
      // Doublon strict ou état antérieur du streaming → rien de neuf à compter.
      if (prevOut !== undefined && out <= prevOut) continue;

      if (!modelUsage[model]) {
        modelUsage[model] = {
          inputTokens: 0, outputTokens: 0,
          cacheReadInputTokens: 0, cacheCreationInputTokens: 0,
          webSearchRequests: 0, costUSD: 0,
          contextWindow: 0, maxOutputTokens: 0
        };
      }
      const mu = modelUsage[model];

      // 1re rencontre : compter input + cache une fois, et l'output vu.
      // Lignes suivantes (output plus grand) : n'ajouter que le delta d'output.
      const firstSeen = prevOut === undefined;
      const addedInput = firstSeen ? (usage.input_tokens || 0) : 0;
      const addedCacheCreation = firstSeen ? (usage.cache_creation_input_tokens || 0) : 0;
      const addedOutput = firstSeen ? out : out - prevOut;
      if (firstSeen) {
        mu.cacheReadInputTokens += usage.cache_read_input_tokens || 0;
        mu.cacheCreationInputTokens += addedCacheCreation;
        mu.webSearchRequests += usage.server_tool_use?.web_search_requests || 0;
      }
      mu.inputTokens += addedInput;
      mu.outputTokens += addedOutput;
      const addedCost = usageCost(model, usage, addedOutput, !firstSeen);
      mu.costUSD += addedCost;
      seenUsage.set(key, out);

      // Intensité : input + écritures de cache + output (lectures exclues).
      const addedTotal = addedInput + addedCacheCreation + addedOutput;
      if (addedTotal > 0 || addedCost > 0) {
        const day = msgDate.toISOString().split('T')[0];
        addDay(dailyModelTokens, day, model, addedTotal, addedCost);
        const prof = dayProfile.get(day) || { io: 0, cacheCreation: 0, cost: 0 };
        prof.io += addedInput + addedOutput;
        prof.cacheCreation += addedCacheCreation;
        prof.cost += addedCost;
        dayProfile.set(day, prof);
      }
    }

    // ── Activité (sessions, messages, heures) : messages principaux ──
    const main = messages.filter(m => !m.isSidechain);
    if (main.length === 0) continue;

    const first = main[0];
    const last = main[main.length - 1];
    const firstDate = new Date(first.timestamp);
    const lastDate = new Date(last.timestamp);
    if (isNaN(firstDate.getTime()) || isNaN(lastDate.getTime())) continue;
    const dateStr = firstDate.toISOString().split('T')[0];

    const duration = lastDate.getTime() - firstDate.getTime();
    if (!longestSession || duration > longestSession.duration) {
      longestSession = { sessionId, duration, messageCount: main.length, timestamp: first.timestamp };
    }
    if (!firstSessionDate || first.timestamp < firstSessionDate) firstSessionDate = first.timestamp;
    totalSessions++;
    totalMessages += main.length;

    const daily = dailyActivity.get(dateStr) || { date: dateStr, messageCount: 0, sessionCount: 0, toolCallCount: 0 };
    daily.sessionCount++;
    daily.messageCount += main.length;
    dailyActivity.set(dateStr, daily);

    hourCounts.set(firstDate.getHours(), (hourCounts.get(firstDate.getHours()) || 0) + 1);

    for (const msg of main) {
      if (msg.type !== 'assistant') continue;
      const content = msg.message?.content;
      if (Array.isArray(content)) {
        for (const item of content) {
          if (item.type === 'tool_use') daily.toolCallCount++;
        }
      }
    }
  }

  // ── Snapshot VM : tokens des sessions purgées avant l'archive locale ──
  // Exclusion par sid : tout sid dont un transcript vivant a été scanné est
  // ignoré (le transcript fait foi → pas de double compte, idempotent, et la
  // VM peut exporter TOUTES ses sessions sans filtrage). N'alimente que les
  // compteurs de TOKENS (modelUsage, dailyModelTokens) : le snapshot ne
  // distingue pas tours principaux et sidechains, donc sessions/messages/
  // heures restent basés sur les seuls transcripts.
  const scannedSids = new Set(files.map(f => basename(f, '.jsonl')));
  const vmSnapshot = ingestVmSnapshot(scannedSids, modelUsage, dailyModelTokens, dayProfile);

  // Jours présents uniquement via des tokens subagents/workflows (sessions
  // principales purgées) : créer une entrée d'activité vide pour que la
  // heatmap, construite sur dailyActivity, affiche ces jours orphelins.
  // (Couvre aussi les jours issus du snapshot VM ci-dessus.)
  for (const date of dailyModelTokens.keys()) {
    if (!dailyActivity.has(date)) {
      dailyActivity.set(date, { date, messageCount: 0, sessionCount: 0, toolCallCount: 0 });
    }
  }

  return {
    version: CACHE_VERSION,
    lastComputedDate: new Date().toISOString().split('T')[0],
    dailyActivity: [...dailyActivity.values()].sort((a, b) => a.date.localeCompare(b.date)),
    dailyModelTokens: [...dailyModelTokens.entries()]
      .map(([date, d]) => ({ date, tokensByModel: d.tokensByModel, costUSD: round2(d.costUSD) }))
      .sort((a, b) => a.date.localeCompare(b.date)),
    modelUsage: Object.fromEntries(Object.entries(modelUsage)
      .map(([m, u]) => [m, { ...u, costUSD: round2(u.costUSD) }])),
    totalCostUSD: round2(Object.values(modelUsage).reduce((s, u) => s + u.costUSD, 0)),
    tokenMetric: 'input+cacheCreation+output',
    pricing: {
      source: 'platform.claude.com/docs/en/about-claude/pricing (2026-09-23)',
      webSearchUSD: WEB_SEARCH_USD,
      models: PRICING.map(([match, p]) => ({ match, ...p })),
    },
    unpricedModels: [...unpricedModels],
    totalSessions,
    totalMessages,
    longestSession,
    firstSessionDate,
    hourCounts: Object.fromEntries(hourCounts),
    totalSpeculationTimeSavedMs,
    // Traçabilité de l'ingestion snapshot VM (champ ignoré par StatsReader).
    vmSnapshotIngested: vmSnapshot,
  };
}

function addDay(dailyModelTokens, day, model, tokens, cost) {
  const d = dailyModelTokens.get(day) || { tokensByModel: {}, costUSD: 0 };
  d.tokensByModel[model] = (d.tokensByModel[model] || 0) + tokens;
  d.costUSD += cost;
  dailyModelTokens.set(day, d);
}

const round2 = x => Math.round(x * 100) / 100;

// ── Ingestion du snapshot d'usage VM ───────────────────────────────

// Le snapshot ne porte que input/output : écritures de cache et coût sont
// estimés au prorata du profil des transcripts scannés le MÊME jour UTC
// (même époque de modèles et d'usage), repli sur le profil agrégé de toute la
// période du snapshot pour les jours trop maigres. Estimation, pas mesure.
const PROFILE_MIN_IO = 100_000;

function ingestVmSnapshot(scannedSids, modelUsage, dailyModelTokens, dayProfile) {
  if (!existsSync(VM_SNAPSHOT_FILE)) return null;
  let snap;
  try {
    snap = JSON.parse(readFileSync(VM_SNAPSHOT_FILE, 'utf-8'));
  } catch (e) {
    console.error(`Snapshot VM illisible (${VM_SNAPSHOT_FILE}) : ${e.message}`);
    return null;
  }
  if (!Array.isArray(snap?.events)) {
    console.error(`Snapshot VM sans tableau "events" (${VM_SNAPSHOT_FILE})`);
    return null;
  }

  // Profil global sur les jours couverts par le snapshot (repli).
  const snapDays = new Set();
  for (const e of snap.events) {
    const d = new Date(e?.ts);
    if (!isNaN(d.getTime())) snapDays.add(d.toISOString().split('T')[0]);
  }
  const global = { io: 0, cacheCreation: 0, cost: 0 };
  for (const day of snapDays) {
    const p = dayProfile.get(day);
    if (p) { global.io += p.io; global.cacheCreation += p.cacheCreation; global.cost += p.cost; }
  }
  const ratios = day => {
    const p = dayProfile.get(day);
    const src = p && p.io >= PROFILE_MIN_IO ? p : global;
    return src.io > 0 ? { cc: src.cacheCreation / src.io, cost: src.cost / src.io } : { cc: 0, cost: 0 };
  };

  const ingestedSids = new Set();
  let events = 0;
  let tokens = 0;
  let estimatedCacheCreation = 0;
  let estimatedCostUSD = 0;
  for (const e of snap.events) {
    if (!e || typeof e.sid !== 'string' || scannedSids.has(e.sid)) continue;
    const date = new Date(e.ts);
    if (isNaN(date.getTime())) continue;
    const input = Number(e.input) || 0;
    const output = Number(e.output) || 0;
    if (input + output <= 0) continue;

    // Le snapshot ne porte pas toujours le modèle : clé de repli explicite,
    // visible comme telle dans modelUsage plutôt que d'inventer un modèle.
    const model = (typeof e.model === 'string' && e.model) ? e.model : 'vm-archive';
    if (!modelUsage[model]) {
      modelUsage[model] = {
        inputTokens: 0, outputTokens: 0,
        cacheReadInputTokens: 0, cacheCreationInputTokens: 0,
        webSearchRequests: 0, costUSD: 0,
        contextWindow: 0, maxOutputTokens: 0
      };
    }
    const day = date.toISOString().split('T')[0];
    const r = ratios(day);
    const cacheCreation = Math.round((input + output) * r.cc);
    const cost = (input + output) * r.cost;
    modelUsage[model].inputTokens += input;
    modelUsage[model].outputTokens += output;
    modelUsage[model].cacheCreationInputTokens += cacheCreation;
    modelUsage[model].costUSD += cost;

    addDay(dailyModelTokens, day, model, input + output + cacheCreation, cost);
    estimatedCacheCreation += cacheCreation;
    estimatedCostUSD += cost;

    ingestedSids.add(e.sid);
    events++;
    tokens += input + output;
  }
  return {
    sessions: ingestedSids.size, events, tokens,
    estimatedCacheCreation, estimatedCostUSD: round2(estimatedCostUSD),
  };
}

// ── Cache I/O ──────────────────────────────────────────────────────

function saveCacheToFile(data, path) {
  if (!existsSync(CLAUDE_DIR)) mkdirSync(CLAUDE_DIR, { recursive: true });
  const tmp = `${path}.${randomBytes(8).toString('hex')}.tmp`;
  try {
    writeFileSync(tmp, JSON.stringify(data, null, 2), { encoding: 'utf-8', mode: 0o600 });
    renameSync(tmp, path);
  } catch (e) {
    try { unlinkSync(tmp); } catch {}
    throw e;
  }
}

// ── Main ──────────────────────────────────────────────────────────

const files = findSessionFiles();
if (files.length === 0) {
  console.log('Aucun fichier de session trouvé.');
  process.exit(0);
}

const cache = computeStats(files);
saveCacheToFile(cache, CACHE_FILE);
const snapInfo = cache.vmSnapshotIngested
  ? `, snapshot VM: +${cache.vmSnapshotIngested.sessions} sids purgés / ${(cache.vmSnapshotIngested.tokens / 1e6).toFixed(2)}M tokens (≈ ${cache.vmSnapshotIngested.estimatedCostUSD.toFixed(0)} $ estimés)`
  : '';
if (cache.unpricedModels.length) {
  console.error(`Modèles sans tarif (coût compté 0) : ${cache.unpricedModels.join(', ')}`);
}
console.log(`→ ${cache.totalSessions} sessions, ${cache.totalMessages} messages, coût API ≈ ${cache.totalCostUSD.toFixed(0)} $, lastComputedDate: ${cache.lastComputedDate}${snapInfo}`);
