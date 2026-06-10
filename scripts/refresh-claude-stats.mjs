#!/usr/bin/env node
// refresh-claude-stats.mjs
// Recalcule complètement le cache de statistiques (~/.claude/stats-cache.json)
// à partir de tous les fichiers de session JSONL trouvés.
//
// Usage : node refresh-claude-stats.mjs
//
// Sources scannées :
//   - ~/.claude/projects/                    (CLI sessions Mac local)
//   - ~/.claude-island/projects/             (miroir VM via sandbox-sync Mutagen)
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
const CLI_PROJECT_ROOTS = [
  join(CLAUDE_DIR, 'projects'),
  join(homedir(), '.claude-island', 'projects'),
];
const DESKTOP_AGENT_DIR = join(homedir(), 'Library', 'Application Support', 'Claude', 'local-agent-mode-sessions');
const CACHE_FILE = join(CLAUDE_DIR, 'stats-cache.json');
const CACHE_VERSION = 2;

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
  // Une réponse de l'agent qui fait N tool-calls en parallèle est écrite sur
  // N lignes JSONL partageant le même message.id mais des timestamps
  // distincts, et CHAQUE ligne recopie le bloc `usage` complet (mêmes
  // tokens) — sans dédup on recompte N fois la même réponse (jusqu'à ×10
  // d'inflation constatée sur une journée chargée). Les blocs `content`,
  // eux, sont distincts par ligne : tool calls et messages restent comptés
  // par ligne. Clé primaire = message.id, fallback (sessionId, timestamp).
  const seenUsage = new Set();

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
      if (seenUsage.has(key)) continue;
      seenUsage.add(key);

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
        const msgDay = msgDate.toISOString().split('T')[0];
        const dayTokens = dailyModelTokens.get(msgDay) || {};
        dayTokens[model] = (dayTokens[model] || 0) + totalTokens;
        dailyModelTokens.set(msgDay, dayTokens);
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

  // Jours présents uniquement via des tokens subagents/workflows (sessions
  // principales purgées) : créer une entrée d'activité vide pour que la
  // heatmap, construite sur dailyActivity, affiche ces jours orphelins.
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
      .map(([date, tokensByModel]) => ({ date, tokensByModel }))
      .sort((a, b) => a.date.localeCompare(b.date)),
    modelUsage,
    totalSessions,
    totalMessages,
    longestSession,
    firstSessionDate,
    hourCounts: Object.fromEntries(hourCounts),
    totalSpeculationTimeSavedMs,
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
console.log(`→ ${cache.totalSessions} sessions, ${cache.totalMessages} messages, lastComputedDate: ${cache.lastComputedDate}`);
