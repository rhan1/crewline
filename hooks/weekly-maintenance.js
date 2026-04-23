#!/usr/bin/env node
'use strict';

// Weekly maintenance (SessionStart hook)
// Runs lightweight housekeeping tasks on a 7-day cadence:
//   1. Rotate dispatch logs older than 30 days (prevents ~/.claude/logs/ growth)
//   2. Refresh the Gemini model cache (catches preview model rotations early)
//
// All tasks fire in the background (`child.unref()`) so session startup is
// never blocked. A marker file records the last run; if <7 days old, the
// hook is a no-op.
//
// Exit 0 always — maintenance must never block session start.

const { spawn } = require('child_process');
const fs = require('fs');
const path = require('path');

const HOME = process.env.HOME || '/tmp';
const MARKER = path.join(HOME, '.claude/.weekly-maintenance-last-run');
const SEVEN_DAYS_MS = 7 * 24 * 60 * 60 * 1000;

function isStale() {
  try {
    const stat = fs.statSync(MARKER);
    return Date.now() - stat.mtimeMs > SEVEN_DAYS_MS;
  } catch {
    return true; // marker missing → first run
  }
}

function fireBackground(cmd, args) {
  try {
    const child = spawn(cmd, args, {
      stdio: 'ignore',
      detached: true,
    });
    child.unref();
  } catch {
    // Never surface failures — maintenance is best-effort
  }
}

function main() {
  // Always pass stdin through (hook contract for SessionStart)
  let raw = '';
  process.stdin.setEncoding('utf8');
  process.stdin.on('data', c => { raw += c; });
  process.stdin.on('end', () => {
    if (isStale()) {
      fireBackground(path.join(HOME, '.claude/scripts/rotate-logs.sh'), ['--quiet']);
      fireBackground(path.join(HOME, '.claude/scripts/gemini-refresh-model-cache.sh'), ['--quiet']);
      // Touch marker. Do this synchronously so subsequent starts within the
      // same session reflect that we kicked off maintenance.
      try { fs.writeFileSync(MARKER, new Date().toISOString() + '\n'); } catch {}
    }
    process.stdout.write('{}');
    process.exit(0);
  });
}

main();
