#!/usr/bin/env node
// maj-tarifs.mjs
// Vérifie chaque semaine les tarifs de l'API et le taux USD → EUR, et corrige
// le bloc <tarifs> de refresh-claude-stats.mjs quand ils ont changé.
//
// Usage : node maj-tarifs.mjs [--dry-run] [--retroactif]
//
// Un modèle dont le prix change reçoit une nouvelle période (`since` = jour de la
// détection) : le passé reste au prix d'alors. Un modèle nouveau vaut depuis toujours.
// --retroactif : le nouveau prix remplace l'ancien sur tout l'historique — pour
// réparer une erreur de la table, pas pour un vrai changement de tarif.
//
// Sources :
//   - tarifs : platform.claude.com/docs/en/about-claude/pricing.md (table « Model pricing »,
//     recherche web, contrôle du mode rapide ×2)
//   - taux   : API de la BCE, moyenne des cotations USD/EUR des 3 derniers mois, arrondie
//     au centième (la règle de Claude Island)
//
// Effets, seulement en cas de changement :
//   1. réécrit le bloc <tarifs> dans la copie du dépôt ET dans la copie exécutée
//      (~/.claude/scripts/refresh-claude-stats.mjs) ;
//   2. relance refresh-claude-stats.mjs : tout l'historique est recalculé avec la
//      nouvelle grille (les transcriptions sont gardées), et stats-cache.json porte
//      la grille et le taux que lisent Claude Island et le mod « fil » ;
//   3. prévient par une notification macOS.
// En cas d'échec ou de lecture douteuse : notification d'erreur, rien n'est modifié.
// Journal : ~/.claude-island/tarifs-hebdo.log
//
// LaunchAgent : ~/Library/LaunchAgents/com.claude.tarifs-hebdo.plist (lundi 8 h)

import { readFileSync, writeFileSync, appendFileSync, copyFileSync, mkdirSync } from 'fs';
import { join } from 'path';
import { homedir, tmpdir } from 'os';
import { execFileSync } from 'child_process';

const DRY = process.argv.includes('--dry-run');
const RETROACTIF = process.argv.includes('--retroactif');
const HOME = homedir();
// TARIFS_CIBLES (chemins séparés par « : », la copie exécutée en dernier) : tester sur des copies.
const CIBLES = process.env.TARIFS_CIBLES ? process.env.TARIFS_CIBLES.split(':') : [
  join(HOME, 'Outils', 'ClaudeIsland', 'claude-island', 'scripts', 'refresh-claude-stats.mjs'),
  join(HOME, '.claude', 'scripts', 'refresh-claude-stats.mjs'),
];
const EXECUTEE = CIBLES.at(-1);
const JOURNAL = join(HOME, '.claude-island', 'tarifs-hebdo.log');
const URL_TARIFS = 'https://platform.claude.com/docs/en/about-claude/pricing.md';
const URL_BCE = 'https://data-api.ecb.europa.eu/service/data/EXR/D.USD.EUR.SP00.A';

const aujourdhui = new Date().toISOString().slice(0, 10);

function journal(ligne) {
  const texte = `${new Date().toISOString()} ${ligne}`;
  console.log(texte);
  if (DRY) return;
  try { mkdirSync(join(HOME, '.claude-island'), { recursive: true }); appendFileSync(JOURNAL, texte + '\n'); } catch {}
}

function notifier(titre, message) {
  if (DRY) return;
  const q = s => JSON.stringify(s.slice(0, 230));
  try { execFileSync('osascript', ['-e', `display notification ${q(message)} with title ${q(titre)}`]); } catch {}
}

async function lire(url) {
  const r = await fetch(url, { headers: { 'User-Agent': 'claude-island-tarifs/1.0' }, signal: AbortSignal.timeout(30_000) });
  if (!r.ok) throw new Error(`${url} : HTTP ${r.status}`);
  return r.text();
}

// ── Taux BCE ──────────────────────────────────────────────────────────
async function tauxBce() {
  const debut = new Date(Date.now() - 92 * 86400_000).toISOString().slice(0, 10);
  const csv = await lire(`${URL_BCE}?startPeriod=${debut}&format=csvdata`);
  const lignes = csv.trim().split('\n');
  const tete = lignes.shift().split(',');
  const iD = tete.indexOf('TIME_PERIOD'), iV = tete.indexOf('OBS_VALUE');
  const obs = lignes.map(l => l.split(',')).map(c => ({ date: c[iD], v: Number(c[iV]) })).filter(o => o.v > 0);
  if (obs.length < 40) throw new Error(`BCE : ${obs.length} cotations seulement`);
  const moyenne = obs.reduce((s, o) => s + 1 / o.v, 0) / obs.length;
  return {
    taux: Math.round(moyenne * 100) / 100,
    source: `moyenne BCE du ${obs[0].date} au ${obs.at(-1).date} (${moyenne.toFixed(4)}, ${obs.length} cotations)`,
  };
}

// ── Grille de prix ────────────────────────────────────────────────────
const prix = cellule => {
  const m = /\$\s*([\d.,]+)/.exec(cellule);
  return m ? Number(m[1].replace(/,/g, '')) : NaN;
};

function tableApres(md, titre) {
  const i = md.indexOf(titre);
  if (i < 0) throw new Error(`section « ${titre} » introuvable`);
  const lignes = md.slice(i).split('\n');
  const debut = lignes.findIndex(l => l.startsWith('|'));
  const table = [];
  for (const l of lignes.slice(debut)) { if (!l.startsWith('|')) break; table.push(l); }
  return table.slice(2).map(l => l.split('|').slice(1, -1).map(c => c.trim()));
}

function motif(nom) {
  return nom.replace(/\([^)]*\)/g, '').replace(/^Claude\s+/i, '').trim().toLowerCase().replace(/[\s.]+/g, '-');
}

function grilleDuSite(md) {
  const modeles = new Map();
  for (const [nom, input, w5m, w1h, read, output] of tableApres(md, '## Model pricing')) {
    const p = { input: prix(input), write5m: prix(w5m), write1h: prix(w1h), read: prix(read), output: prix(output) };
    const long = /for prompts over ([\d,]+) tokens/i.exec(nom);
    const m = motif(nom.replace(/\(\[[^\]]*\]\([^)]*\)\)/g, ''));
    if (long) {
      const base = modeles.get(m);
      if (!base) throw new Error(`palier long sans palier de base : ${nom}`);
      base.long = { above: Number(long[1].replace(/,/g, '')), ...p };
    } else modeles.set(m, p);
  }
  const ws = /\$([\d.]+) USD per 1,000 searches/.exec(md);
  // Mode rapide : Claude Island compte ×2 ; on vérifie seulement que c'est toujours vrai.
  const alertes = [];
  try {
    for (const [nom, input, output] of tableApres(md, '### Fast mode pricing')) {
      for (const m of nom.split('/').map(n => motif(n))) {
        const b = modeles.get(m);
        if (b && (prix(input) !== 2 * b.input || prix(output) !== 2 * b.output))
          alertes.push(`mode rapide de ${m} : ${prix(input)}/${prix(output)} au lieu de ×2`);
      }
    }
  } catch (e) { alertes.push(`table du mode rapide illisible (${e.message})`); }
  return { modeles, webSearch: ws ? Number(ws[1]) / 1000 : NaN, alertes };
}

// ── Bloc <tarifs> ─────────────────────────────────────────────────────
const OUVRE = '// <tarifs>\n', FERME = '// </tarifs>';

function blocActuel(source) {
  const i = source.indexOf(OUVRE), j = source.indexOf(FERME);
  if (i < 0 || j < i) throw new Error('balises <tarifs> introuvables dans refresh-claude-stats.mjs');
  const corps = source.slice(i + OUVRE.length, j);
  // Le bloc ne contient que des constantes littérales écrites par ce script.
  const v = new Function(`${corps}; return { PRICING_SOURCE, USD_TO_EUR, USD_TO_EUR_SOURCE, WEB_SEARCH_USD, PRICING };`)();
  return { i, j, ...v };
}

const nombre = n => String(Math.round(n * 10000) / 10000);
const valeur = v => (typeof v === 'object' ? objet(v) : typeof v === 'string' ? `'${v}'` : nombre(v));
const objet = p => `{ ${Object.entries(p).map(([k, v]) => `${k}: ${valeur(v)}`).join(', ')} }`;
/** Le tarif seul, sans sa date : ce qui se compare au site. */
const tarif = ({ since, ...p }) => p;
/** Le plus long motif d'abord, puis la période la plus récente d'abord (sans `since` en dernier). */
const ordre = (a, b) =>
  b[0].length - a[0].length || a[0].localeCompare(b[0]) || (b[1].since ?? '').localeCompare(a[1].since ?? '');

function ecrireBloc({ source, taux, tauxSource, webSearch, grille }) {
  const lignes = [...grille].sort(ordre);
  return [
    `const PRICING_SOURCE = '${source}';`,
    `const USD_TO_EUR = ${nombre(taux)};`,
    `const USD_TO_EUR_SOURCE = '${tauxSource}';`,
    `const WEB_SEARCH_USD = ${nombre(webSearch * 1000)} / 1000;`,
    'const PRICING = [',
    ...lignes.map(([m, p]) => `  ['${m}', ${objet(p)}],`),
    '];',
    '',
  ].join('\n');
}

function verifier(modeles, webSearch, taux) {
  const probleme = [];
  if (modeles.size < 10) probleme.push(`${modeles.size} modèles lus seulement`);
  if (!modeles.has('opus-5-5')) probleme.push('Opus 5.5 absent de la table');
  for (const [m, p] of modeles) {
    for (const t of [p, p.long].filter(Boolean))
      for (const k of ['input', 'write5m', 'write1h', 'read', 'output'])
        if (!(t[k] > 0 && t[k] < 1000)) probleme.push(`${m}.${k} illisible (${t[k]})`);
    if (p.read >= p.input || p.output <= p.input) probleme.push(`${m} : grille incohérente`);
  }
  if (!(webSearch > 0 && webSearch < 1)) probleme.push(`recherche web illisible (${webSearch})`);
  if (!(taux > 0.5 && taux < 1.5)) probleme.push(`taux invraisemblable (${taux})`);
  return probleme;
}

// ── Principal ─────────────────────────────────────────────────────────
try {
  const [md, bce] = await Promise.all([lire(URL_TARIFS), tauxBce()]);
  const site = grilleDuSite(md);
  const probleme = verifier(site.modeles, site.webSearch, bce.taux);
  if (probleme.length) throw new Error(`lecture douteuse, rien modifié : ${probleme.join(' ; ')}`);

  const source = readFileSync(CIBLES[0], 'utf-8');
  const actuel = blocActuel(source);
  let grille = [...actuel.PRICING].sort(ordre);
  const changements = [];
  for (const [m, p] of site.modeles) {
    const avant = grille.find(([x]) => x === m)?.[1];
    if (!avant) {
      changements.push(`nouveau modèle ${m}`);
      grille.push([m, p]);
    } else if (JSON.stringify(tarif(avant)) !== JSON.stringify(p)) {
      if (RETROACTIF) {
        changements.push(`${m} (rétroactif) : ${objet(tarif(avant))} → ${objet(p)}`);
        grille = grille.filter(([x]) => x !== m);
        grille.push([m, p]);
      } else {
        changements.push(`${m} à partir du ${aujourdhui} : ${objet(tarif(avant))} → ${objet(p)}`);
        grille = grille.filter(([x, q]) => x !== m || q.since !== aujourdhui);
        grille.push([m, { ...p, since: aujourdhui }]);
      }
    }
  }
  if (site.webSearch !== actuel.WEB_SEARCH_USD) changements.push(`recherche web : ${actuel.WEB_SEARCH_USD} → ${site.webSearch} $`);
  const tauxChange = bce.taux !== actuel.USD_TO_EUR;
  if (tauxChange) changements.push(`taux USD → EUR : ${actuel.USD_TO_EUR} → ${bce.taux}`);
  for (const a of site.alertes) journal(`ALERTE ${a}`);
  if (site.alertes.length) notifier('Tarifs Claude : à vérifier', site.alertes.join(' ; '));

  if (changements.length === 0) {
    journal(`RAS - grille et taux inchangés (BCE ${bce.source})`);
    process.exit(0);
  }

  const bloc = ecrireBloc({
    source: `platform.claude.com/docs/en/about-claude/pricing (${aujourdhui})`,
    taux: bce.taux,
    tauxSource: tauxChange ? bce.source : actuel.USD_TO_EUR_SOURCE,
    webSearch: site.webSearch,
    grille,
  });
  const nouveau = source.slice(0, actuel.i + OUVRE.length) + bloc + source.slice(actuel.j);
  // Le fichier réécrit doit rester du JavaScript valide avant de remplacer quoi que ce soit.
  const essai = join(tmpdir(), `refresh-claude-stats-${process.pid}.mjs`);
  writeFileSync(essai, nouveau);
  execFileSync(process.execPath, ['--check', essai]);
  blocActuel(nouveau);

  if (DRY) {
    console.log(changements.join('\n'));
    console.log(bloc);
    process.exit(0);
  }
  for (const cible of CIBLES) {
    copyFileSync(cible, `${cible}.bak-${aujourdhui}`);
    writeFileSync(cible, nouveau);
  }
  const sortie = execFileSync(process.execPath, [EXECUTEE], { encoding: 'utf-8' }).trim();
  for (const c of changements) journal(`CORRIGÉ ${c}`);
  journal(`recalcul : ${sortie}`);
  notifier('Tarifs Claude mis à jour', `${changements.length} changement(s) : ${changements.join(' ; ')}`);
} catch (e) {
  journal(`ERREUR ${e.message}`);
  notifier('Tarifs Claude : échec de la vérification', e.message);
  process.exit(1);
}
