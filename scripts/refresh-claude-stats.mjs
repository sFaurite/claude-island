#!/usr/bin/env node
// refresh-claude-stats.mjs
// Réplique exacte de la logique interne de Claude Code pour
// recalculer le cache de statistiques (~/.claude/stats-cache.json).
//
// Usage : node refresh-claude-stats.mjs [--force]
//
// Architecture : deux fichiers de cache
//   - stats-cache-base.json : données scellées (jusqu'à hier), mis à jour 1x/jour
//   - stats-cache.json      : base + données du jour, recalculé à chaque exécution

import { readFileSync, writeFileSync, readdirSync, statSync, renameSync, unlinkSync, existsSync, mkdirSync } from 'fs';
import { join, basename } from 'path';
import { homedir } from 'os';
import { randomBytes } from 'crypto';

const CLAUDE_DIR = join(homedir(), '.claude');
const PROJECTS_DIR = join(CLAUDE_DIR, 'projects');
const CACHE_FILE = join(CLAUDE_DIR, 'stats-cache.json');
const BASE_CACHE_FILE = join(CLAUDE_DIR, 'stats-cache-base.json');
const CACHE_VERSION = 2;
const FORCE = process.argv.includes('--force');

// ── Utilitaires dates ──────────────────────────────────────────────

function toDateStr(d) {
  return d.toISOString().split('T')[0];
}

function yesterday() {
  const d = new Date();
  d.setDate(d.getDate() - 1);
  return toDateStr(d);
}

function nextDay(dateStr) {
  const d = new Date(dateStr + 'T00:00:00');
  d.setDate(d.getDate() + 1);
  return toDateStr(d);
}

// ── Découverte des fichiers de session ─────────────────────────────

function findSessionFiles() {
  const files = [];
  let projEntries;
  try { projEntries = readdirSync(PROJECTS_DIR, { withFileTypes: true }); }
  catch { return files; }

  for (const proj of projEntries) {
    if (!proj.isDirectory()) continue;
    const projDir = join(PROJECTS_DIR, proj.name);
    let entries;
    try { entries = readdirSync(projDir, { withFileTypes: true }); }
    catch { continue; }

    for (const entry of entries) {
      if (entry.isFile() && entry.name.endsWith('.jsonl')) {
        files.push(join(projDir, entry.name));
      }
      // Sous-agents
      if (entry.isDirectory()) {
        const subDir = join(projDir, entry.name, 'subagents');
        try {
          for (const sf of readdirSync(subDir, { withFileTypes: true })) {
            if (sf.isFile() && sf.name.endsWith('.jsonl') && sf.name.startsWith('agent-')) {
              files.push(join(subDir, sf.name));
            }
          }
        } catch {}
      }
    }
  }
  return files;
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

// Réplique exacte de isTranscriptMessage (ad) du binaire
function isMessage(entry) {
  return entry.type === 'user' || entry.type === 'assistant' ||
         entry.type === 'attachment' || entry.type === 'system' ||
         entry.type === 'progress';
}

// ── Traitement des sessions (réplique de qyR) ─────────────────────

function processSessionFiles(files, { fromDate, toDate } = {}) {
  const dailyActivity = new Map();
  const dailyModelTokens = new Map();
  const sessionStats = [];
  const hourCounts = new Map();
  const modelUsage = {};
  let totalMessages = 0;
  let totalSpeculationTimeSavedMs = 0;

  for (const file of files) {
    // Optimisation : sauter les fichiers non modifiés depuis fromDate
    if (fromDate) {
      try {
        const mtime = toDateStr(statSync(file).mtime);
        if (mtime < fromDate) continue;
      } catch {}
    }

    const entries = parseSessionFile(file);
    const sessionId = basename(file, '.jsonl');

    // Séparer messages et speculation-accept
    const messages = [];
    for (const e of entries) {
      if (isMessage(e)) messages.push(e);
      else if (e.type === 'speculation-accept' && e.timeSavedMs) {
        totalSpeculationTimeSavedMs += e.timeSavedMs;
      }
    }

    // Filtrer les sidechain
    const main = messages.filter(m => !m.isSidechain);
    if (main.length === 0) continue;

    const first = main[0];
    const last = main[main.length - 1];
    const firstDate = new Date(first.timestamp);
    const lastDate = new Date(last.timestamp);
    const dateStr = toDateStr(firstDate);

    // Filtres de dates
    if (fromDate && dateStr < fromDate) continue;
    if (toDate && toDate < dateStr) continue;

    // Stats de session
    const duration = lastDate.getTime() - firstDate.getTime();
    sessionStats.push({ sessionId, duration, messageCount: main.length, timestamp: first.timestamp });
    totalMessages += main.length;

    // Activité journalière
    const daily = dailyActivity.get(dateStr) || { date: dateStr, messageCount: 0, sessionCount: 0, toolCallCount: 0 };
    daily.sessionCount++;
    daily.messageCount += main.length;
    dailyActivity.set(dateStr, daily);

    // Compteur horaire
    const hour = firstDate.getHours();
    hourCounts.set(hour, (hourCounts.get(hour) || 0) + 1);

    // Messages assistant : tokens + tool calls
    for (const msg of main) {
      if (msg.type !== 'assistant') continue;

      // Tool calls
      const content = msg.message?.content;
      if (Array.isArray(content)) {
        for (const item of content) {
          if (item.type === 'tool_use') daily.toolCallCount++;
        }
      }

      // Token usage
      const usage = msg.message?.usage;
      const model = msg.message?.model;
      if (!usage || !model) continue;

      if (!modelUsage[model]) {
        modelUsage[model] = {
          inputTokens: 0, outputTokens: 0,
          cacheReadInputTokens: 0, cacheCreationInputTokens: 0,
          webSearchRequests: 0, costUSD: 0,
          contextWindow: 0, maxOutputTokens: 0
        };
      }
      const mu = modelUsage[model];
      mu.inputTokens += usage.input_tokens || 0;
      mu.outputTokens += usage.output_tokens || 0;
      mu.cacheReadInputTokens += usage.cache_read_input_tokens || 0;
      mu.cacheCreationInputTokens += usage.cache_creation_input_tokens || 0;

      const totalTokens = (usage.input_tokens || 0) + (usage.output_tokens || 0);
      if (totalTokens > 0) {
        const dayTokens = dailyModelTokens.get(dateStr) || {};
        dayTokens[model] = (dayTokens[model] || 0) + totalTokens;
        dailyModelTokens.set(dateStr, dayTokens);
      }
    }
  }

  return {
    dailyActivity: [...dailyActivity.values()].sort((a, b) => a.date.localeCompare(b.date)),
    dailyModelTokens: [...dailyModelTokens.entries()]
      .map(([date, tokensByModel]) => ({ date, tokensByModel }))
      .sort((a, b) => a.date.localeCompare(b.date)),
    modelUsage, sessionStats,
    hourCounts: Object.fromEntries(hourCounts),
    totalMessages, totalSpeculationTimeSavedMs
  };
}

// ── Fusion cache + nouvelles données (réplique de DuA) ─────────────

function mergeStats(cached, newData, computeDate) {
  // Daily activity
  const dailyMap = new Map();
  for (const d of cached.dailyActivity) dailyMap.set(d.date, { ...d });
  for (const d of newData.dailyActivity) {
    const e = dailyMap.get(d.date);
    if (e) { e.messageCount += d.messageCount; e.sessionCount += d.sessionCount; e.toolCallCount += d.toolCallCount; }
    else dailyMap.set(d.date, { ...d });
  }

  // Daily model tokens
  const tokenMap = new Map();
  for (const d of cached.dailyModelTokens) tokenMap.set(d.date, { ...d.tokensByModel });
  for (const d of newData.dailyModelTokens) {
    const e = tokenMap.get(d.date);
    if (e) { for (const [m, c] of Object.entries(d.tokensByModel)) e[m] = (e[m] || 0) + c; }
    else tokenMap.set(d.date, { ...d.tokensByModel });
  }

  // Model usage
  const mu = { ...cached.modelUsage };
  for (const [model, u] of Object.entries(newData.modelUsage)) {
    if (mu[model]) {
      mu[model] = {
        inputTokens: mu[model].inputTokens + u.inputTokens,
        outputTokens: mu[model].outputTokens + u.outputTokens,
        cacheReadInputTokens: mu[model].cacheReadInputTokens + u.cacheReadInputTokens,
        cacheCreationInputTokens: mu[model].cacheCreationInputTokens + u.cacheCreationInputTokens,
        webSearchRequests: mu[model].webSearchRequests + u.webSearchRequests,
        costUSD: mu[model].costUSD + u.costUSD,
        contextWindow: Math.max(mu[model].contextWindow, u.contextWindow),
        maxOutputTokens: Math.max(mu[model].maxOutputTokens, u.maxOutputTokens)
      };
    } else mu[model] = { ...u };
  }

  // Hour counts
  const hc = { ...cached.hourCounts };
  for (const [h, c] of Object.entries(newData.hourCounts)) {
    const k = parseInt(h, 10);
    hc[k] = (hc[k] || 0) + c;
  }

  // Longest session
  let longest = cached.longestSession;
  for (const s of newData.sessionStats) {
    if (!longest || s.duration > longest.duration) longest = s;
  }

  // First session date
  let firstDate = cached.firstSessionDate;
  for (const s of newData.sessionStats) {
    if (!firstDate || s.timestamp < firstDate) firstDate = s.timestamp;
  }

  return {
    version: CACHE_VERSION,
    lastComputedDate: computeDate,
    dailyActivity: [...dailyMap.values()].sort((a, b) => a.date.localeCompare(b.date)),
    dailyModelTokens: [...tokenMap.entries()]
      .map(([date, tokensByModel]) => ({ date, tokensByModel }))
      .sort((a, b) => a.date.localeCompare(b.date)),
    modelUsage: mu,
    totalSessions: cached.totalSessions + newData.sessionStats.length,
    totalMessages: cached.totalMessages + newData.sessionStats.reduce((s, x) => s + x.messageCount, 0),
    longestSession: longest,
    firstSessionDate: firstDate,
    hourCounts: hc,
    totalSpeculationTimeSavedMs: cached.totalSpeculationTimeSavedMs + newData.totalSpeculationTimeSavedMs
  };
}

// ── Cache I/O ──────────────────────────────────────────────────────

function emptyCache() {
  return {
    version: CACHE_VERSION, lastComputedDate: null,
    dailyActivity: [], dailyModelTokens: [], modelUsage: {},
    totalSessions: 0, totalMessages: 0, longestSession: null,
    firstSessionDate: null, hourCounts: {}, totalSpeculationTimeSavedMs: 0
  };
}

function loadCacheFromFile(path) {
  try {
    const data = JSON.parse(readFileSync(path, 'utf-8'));
    if (data.version !== CACHE_VERSION) return null;
    if (!Array.isArray(data.dailyActivity) || !Array.isArray(data.dailyModelTokens)) return null;
    return data;
  } catch { return null; }
}

function saveCacheToFile(data, path) {
  const dir = CLAUDE_DIR;
  if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
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
if (files.length === 0) { console.log('Aucun fichier de session trouvé.'); process.exit(0); }

const today = toDateStr(new Date());
const yday = yesterday();

// Étape 1 : Mettre à jour le cache de base (données scellées, jusqu'à hier)
let base = loadCacheFromFile(BASE_CACHE_FILE);
if (!base) {
  // Migration : initialiser depuis le cache principal existant
  const existing = loadCacheFromFile(CACHE_FILE);
  if (existing && existing.lastComputedDate && existing.lastComputedDate <= yday) {
    base = existing;
    saveCacheToFile(base, BASE_CACHE_FILE);
    console.log(`Base initialisée depuis le cache existant (${base.lastComputedDate}).`);
  } else {
    base = emptyCache();
  }
}

if (FORCE || !base.lastComputedDate) {
  console.log(`Calcul complet (${files.length} fichiers)...`);
  const data = processSessionFiles(files, { toDate: yday });
  base = data.sessionStats.length > 0
    ? mergeStats(emptyCache(), data, yday)
    : { ...emptyCache(), lastComputedDate: yday };
  saveCacheToFile(base, BASE_CACHE_FILE);

} else if (base.lastComputedDate < yday) {
  const from = nextDay(base.lastComputedDate);
  console.log(`Incrémental base : ${from} → ${yday}...`);
  const data = processSessionFiles(files, { fromDate: from, toDate: yday });
  if (data.sessionStats.length > 0 || data.dailyActivity.length > 0) {
    base = mergeStats(base, data, yday);
  } else {
    base = { ...base, lastComputedDate: yday };
  }
  saveCacheToFile(base, BASE_CACHE_FILE);
}

// Étape 2 : Calculer les données du jour et fusionner avec la base
const todayData = processSessionFiles(files, { fromDate: today, toDate: today });
let live;
if (todayData.sessionStats.length > 0) {
  live = mergeStats(base, todayData, today);
  console.log(`+${todayData.sessionStats.length} sessions aujourd'hui`);
} else {
  live = { ...base, lastComputedDate: today };
}
saveCacheToFile(live, CACHE_FILE);

console.log(`→ ${live.totalSessions} sessions, ${live.totalMessages} messages, lastComputedDate: ${live.lastComputedDate}`);
