#!/usr/bin/env node
// fable-usage-refresh.mjs — writes the weekly FABLE allowance to ~/.claude/fable-usage.json for the status line.
//
// WHY a separate fetch: the status line's stdin carries only the all-model 5h and 7d percentages. On plans
// that include Fable, Fable has its OWN weekly bucket (a share of the week) and stops when that bucket is
// full even though "7d" still looks half empty. Only the account usage endpoint that `/usage` reads reports it:
//   GET https://api.anthropic.com/api/oauth/usage  ->  limits[] { kind: "weekly_scoped",
//       scope.model.display_name: "Fable", percent, resets_at }  (+ weekly_scoped_shares[].allowance_percent_of_weekly)
// This endpoint is undocumented: if its shape changes, or your plan has no Fable row, this writes nothing and
// the status line simply shows its normal 7d meter.
//
// Rules: read Claude Code's OAuth token (macOS Keychain, else ~/.claude/.credentials.json) and use it as-is.
// NEVER refresh it here — Claude Code owns the refresh, and a second refresher would invalidate its token.
// Expired or rejected -> exit quietly; the next tick picks up the token Claude Code has renewed. The token is
// sent only to api.anthropic.com and is never printed or written anywhere.
// Kicked by statusline.sh when the cache is > 5 min old (at most one attempt per 2 min).
// Seams (tests only): FABLE_USAGE_CACHE (output path), FABLE_USAGE_FIXTURE (a saved response instead of
// credentials + network).
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const CACHE = process.env.FABLE_USAGE_CACHE || path.join(os.homedir(), '.claude', 'fable-usage.json');
const note = (msg) => { try { fs.writeFileSync(CACHE + '.err', JSON.stringify({ ts: Math.floor(Date.now() / 1000), error: msg }) + '\n'); } catch { /* best-effort */ } };

// Claude Code keeps its login in the macOS Keychain; elsewhere (or if that read fails) in ~/.claude/.credentials.json.
export function readOauth() {
  let raw = '';
  if (process.platform === 'darwin') {
    try { raw = execFileSync('security', ['find-generic-password', '-s', 'Claude Code-credentials', '-w'], { encoding: 'utf8', timeout: 5000, stdio: ['ignore', 'pipe', 'ignore'] }).trim(); } catch { /* fall through to the file */ }
  }
  if (!raw) { try { raw = fs.readFileSync(path.join(os.homedir(), '.claude', '.credentials.json'), 'utf8'); } catch { /* none */ } }
  try { return (JSON.parse(raw) || {}).claudeAiOauth || {}; } catch { return {}; }
}

async function fetchUsage() {
  if (process.env.FABLE_USAGE_FIXTURE) return JSON.parse(fs.readFileSync(process.env.FABLE_USAGE_FIXTURE, 'utf8'));
  const o = readOauth();
  if (!o.accessToken) throw new Error('no Claude Code OAuth token found');
  if (o.expiresAt && o.expiresAt < Date.now()) throw new Error('token expired; waiting for Claude Code to renew it');
  const ctl = new AbortController(); const t = setTimeout(() => ctl.abort(), 10000);
  try {
    const r = await fetch('https://api.anthropic.com/api/oauth/usage', {
      signal: ctl.signal,
      headers: { Authorization: `Bearer ${o.accessToken}`, 'anthropic-beta': 'oauth-2025-04-20', Accept: 'application/json', 'User-Agent': 'claude-cli (external, cli)' },
    });
    if (!r.ok) throw new Error(`usage endpoint answered ${r.status}`);
    return await r.json();
  } finally { clearTimeout(t); }
}

export function extract(d) {
  const limits = Array.isArray(d && d.limits) ? d.limits : [];
  const idx = limits.findIndex((l) => l && l.kind === 'weekly_scoped' && /fable/i.test(String(l.scope?.model?.display_name || '')));
  if (idx < 0) return null;
  const l = limits[idx]; const pct = Number(l.percent);
  if (!Number.isFinite(pct)) return null;
  const reset = Date.parse(l.resets_at || '');
  const share = (Array.isArray(d.weekly_scoped_shares) ? d.weekly_scoped_shares : []).find((s) => s && s.limit_index === idx);
  const all = limits.find((x) => x && x.kind === 'weekly_all');
  return {
    ts: Math.floor(Date.now() / 1000),
    fable_pct: pct,
    fable_resets_at: Number.isFinite(reset) ? Math.floor(reset / 1000) : null,
    fable_allowance_pct_of_week: share ? share.allowance_percent_of_weekly ?? null : null,
    week_all_pct: all && Number.isFinite(Number(all.percent)) ? Number(all.percent) : null,
    model: l.scope.model.display_name,
  };
}

// Run only when executed, not when imported by a test. Compare REAL paths: this file is usually reached through a
// symlink (~/.claude/scripts -> the checkout) or a /var -> /private/var path, where a plain URL compare is never equal.
const isMain = (() => { try { return fs.realpathSync(process.argv[1]) === fs.realpathSync(fileURLToPath(import.meta.url)); } catch { return false; } })();
if (isMain) {
  try {
    const out = extract(await fetchUsage());
    if (!out) { note('no Fable weekly row in the usage response'); process.exit(0); }
    const tmp = `${CACHE}.${process.pid}.tmp`;
    fs.writeFileSync(tmp, JSON.stringify(out) + '\n'); fs.renameSync(tmp, CACHE);
    try { fs.unlinkSync(CACHE + '.err'); } catch { /* none */ }
    if (process.argv.includes('--print')) console.log(JSON.stringify(out));
  } catch (e) { note(String(e && e.message ? e.message : e).slice(0, 200)); }
  process.exit(0);
}
