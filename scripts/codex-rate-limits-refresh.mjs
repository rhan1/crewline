#!/usr/bin/env node

import { spawn } from "node:child_process";
import { mkdir, rename, rm, stat, writeFile } from "node:fs/promises";
import path from "node:path";

const home = process.env.HOME;

if (!home) {
  throw new Error("HOME is required");
}

const cachePath = path.join(home, ".claude", "codex-rate-limits.json");
const lockPath = path.join(home, ".claude", "codex-rate-limits.lock");
const codexBinary = process.env.CODEX_BIN || "/opt/homebrew/bin/codex";
const cacheTtlMs = 45_000;
const lockTtlMs = 120_000;

async function isFresh() {
  try {
    const cache = await stat(cachePath);
    return Date.now() - cache.mtimeMs < cacheTtlMs;
  } catch {
    return false;
  }
}

async function acquireLock() {
  try {
    await mkdir(lockPath, { mode: 0o700 });
    return true;
  } catch (error) {
    if (error.code !== "EEXIST") {
      throw error;
    }
  }

  try {
    const lock = await stat(lockPath);
    if (Date.now() - lock.mtimeMs < lockTtlMs) {
      return false;
    }
    await rm(lockPath, { recursive: true, force: true });
    await mkdir(lockPath, { mode: 0o700 });
    return true;
  } catch (error) {
    if (error.code === "EEXIST" || error.code === "ENOENT") {
      return false;
    }
    throw error;
  }
}

function normalizeWindow(window) {
  if (!window || typeof window !== "object") {
    return null;
  }

  const usedPercent = Number(window.usedPercent);
  const windowDurationMins = Number(window.windowDurationMins);
  const resetsAt = Number(window.resetsAt);

  if (![usedPercent, windowDurationMins, resetsAt].every(Number.isFinite)) {
    return null;
  }

  return {
    used_percent: Math.round(usedPercent),
    window_duration_mins: Math.round(windowDurationMins),
    resets_at: Math.round(resetsAt),
  };
}

function fetchRateLimits() {
  return new Promise((resolve, reject) => {
    const child = spawn(codexBinary, ["app-server", "--stdio"], {
      stdio: ["pipe", "pipe", "pipe"],
    });
    let buffer = "";
    let stderr = "";
    let finished = false;
    const timeout = setTimeout(() => {
      fail(new Error("Timed out reading Codex rate limits"));
    }, 15_000);

    function send(message) {
      child.stdin.write(`${JSON.stringify(message)}\n`);
    }

    function fail(error) {
      if (finished) {
        return;
      }
      finished = true;
      clearTimeout(timeout);
      child.kill("SIGTERM");
      reject(error);
    }

    function succeed(rateLimits) {
      if (finished) {
        return;
      }
      finished = true;
      clearTimeout(timeout);
      child.stdin.end();
      child.kill("SIGTERM");
      resolve(rateLimits);
    }

    function handleMessage(message) {
      if (message.id === 1) {
        if (message.error) {
          fail(new Error(message.error.message || "Codex app-server initialization failed"));
          return;
        }
        send({ method: "initialized" });
        send({ method: "account/rateLimits/read", id: 2 });
        return;
      }

      if (message.id === 2) {
        if (message.error) {
          fail(new Error(message.error.message || "Codex rate-limit request failed"));
          return;
        }
        if (!message.result?.rateLimits) {
          fail(new Error("Codex did not return rate-limit data"));
          return;
        }
        succeed(message.result.rateLimits);
      }
    }

    child.on("error", fail);
    child.on("exit", (code, signal) => {
      if (!finished) {
        fail(new Error(`Codex app-server exited before responding (${code ?? signal ?? "unknown"})${stderr ? `: ${stderr.trim()}` : ""}`));
      }
    });
    child.stderr.setEncoding("utf8");
    child.stderr.on("data", (chunk) => {
      stderr += chunk;
    });
    child.stdout.setEncoding("utf8");
    child.stdout.on("data", (chunk) => {
      buffer += chunk;
      let newlineIndex = buffer.indexOf("\n");
      while (newlineIndex !== -1) {
        const line = buffer.slice(0, newlineIndex).trim();
        buffer = buffer.slice(newlineIndex + 1);
        newlineIndex = buffer.indexOf("\n");
        if (!line) {
          continue;
        }
        try {
          handleMessage(JSON.parse(line));
        } catch (error) {
          fail(new Error(`Invalid Codex app-server response: ${error.message}`));
        }
      }
    });

    send({
      method: "initialize",
      id: 1,
      params: {
        clientInfo: {
          name: "claude_statusline",
          title: "Claude status line",
          version: "1.0.0",
        },
      },
    });
  });
}

async function main() {
  await mkdir(path.dirname(cachePath), { recursive: true, mode: 0o700 });

  if (await isFresh()) {
    return;
  }

  if (!(await acquireLock())) {
    return;
  }

  try {
    if (await isFresh()) {
      return;
    }

    const rateLimits = await fetchRateLimits();
    const snapshot = {
      fetched_at: new Date().toISOString(),
      rate_limits: {
        primary: normalizeWindow(rateLimits.primary),
        secondary: normalizeWindow(rateLimits.secondary),
        reached_type: rateLimits.rateLimitReachedType ?? null,
      },
    };
    const temporaryPath = path.join(path.dirname(cachePath), `.${path.basename(cachePath)}.${process.pid}.tmp`);
    await writeFile(temporaryPath, `${JSON.stringify(snapshot)}\n`, { mode: 0o600 });
    await rename(temporaryPath, cachePath);
  } finally {
    await rm(lockPath, { recursive: true, force: true });
  }
}

main().catch((error) => {
  process.stderr.write(`${error.message}\n`);
  process.exitCode = 1;
});
