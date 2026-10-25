import { createHash } from 'node:crypto';
import { lstatSync, readdirSync, readFileSync, realpathSync, existsSync } from 'node:fs';
import { isAbsolute, relative, resolve, sep, dirname, join } from 'node:path';
import { spawn } from 'node:child_process';

export function sha256(value) {
  return createHash('sha256').update(value).digest('hex');
}

export function safePath(root, name) {
  if (!name || name.includes('\\') || name.includes('\0') || isAbsolute(name) || /^[a-z]:/i.test(name)) {
    throw new Error(`unsafe virtual path: ${JSON.stringify(name)}`);
  }
  const path = resolve(root, name);
  const rel = relative(resolve(root), path);
  if (!rel || rel === '..' || rel.startsWith(`..${sep}`) || isAbsolute(rel)) {
    throw new Error(`virtual path escapes sandbox: ${name}`);
  }
  return path;
}

export function fingerprint(root, entries) {
  root = realpathSync(root);
  const files = new Map();
  function visit(name) {
    const path = safePath(root, name);
    const stat = lstatSync(path);
    if (stat.isSymbolicLink() || realpathSync(path) !== path) throw new Error(`snapshot symlink: ${name}`);
    if (stat.isDirectory()) {
      for (const child of readdirSync(path).sort()) visit(`${name}/${child}`);
    } else if (stat.isFile()) {
      if (files.has(name)) throw new Error(`duplicate snapshot entry: ${name}`);
      files.set(name, sha256(readFileSync(path)));
    } else throw new Error(`unsupported snapshot entry: ${name}`);
  }
  for (const entry of entries) visit(entry);
  const sorted = [...files].sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0);
  return { sha256: sha256(sorted.map(([name, hash]) => `${name}\0${hash}\n`).join('')), files: Object.fromEntries(sorted) };
}

export function findSupportRoot(binary) {
  let base = dirname(realpathSync(binary));
  for (let i = 0; i < 4; i++, base = dirname(base)) {
    if (existsSync(join(base, 'std/core/system/index.ms'))) return base;
  }
  throw new Error('compiler support marker not found in four binary ancestors; cwd-only installs cannot run in isolated cases');
}

export function ambientProjectConfig(entry, cwd) {
  for (const start of [dirname(entry), cwd]) {
    let dir = resolve(start);
    for (let i = 0; i < 20; i++, dir = dirname(dir)) {
      const config = join(dir, 'build.ms');
      if (existsSync(config)) return config;
      if (dirname(dir) === dir) break;
    }
  }
  return null;
}

const activeChildren = new Map();
let cancelled;

const TERMINATION_GRACE_MS = 500;

function terminateGroup(pid, force = false) {
  const state = activeChildren.get(pid);
  const signal = force ? 'SIGKILL' : 'SIGTERM';
  if (!state || state.signal === 'SIGKILL' || state.signal === signal) return;
  state.signal = signal;
  try { process.kill(-pid, signal); }
  catch (error) { if (error.code !== 'ESRCH') throw error; return; }
  if (!force) state.escalation = setTimeout(() => terminateGroup(pid, true), TERMINATION_GRACE_MS);
}

for (const [signal, code] of [['SIGINT', 130], ['SIGTERM', 143]]) {
  process.on(signal, () => {
    cancelled = code;
    for (const pid of activeChildren.keys()) terminateGroup(pid);
    if (activeChildren.size === 0) process.exit(code);
  });
}

export function runCommand(command, args, options = {}) {
  if (process.platform === 'win32') throw new Error('subprocess tree isolation currently requires a POSIX host');
  const started = performance.now();
  const { timeout = 30000, maxBuffer = 4 * 1024 * 1024, ...spawnOptions } = options;
  return new Promise(resolveResult => {
    const child = spawn(command, args, {
      ...spawnOptions, detached: true, stdio: ['ignore', 'pipe', 'pipe'],
      env: { ...process.env, NO_COLOR: '1', FORCE_COLOR: '0', ...options.env },
    });
    if (child.pid) activeChildren.set(child.pid, {});
    const buffers = { stdout: [], stderr: [] };
    let bytes = 0;
    let status;
    let failure;
    const timer = setTimeout(() => { status ??= 'timeout'; terminateGroup(child.pid); }, timeout);
    for (const stream of ['stdout', 'stderr']) {
      child[stream].on('data', chunk => {
        const remaining = Math.max(0, maxBuffer - bytes);
        buffers[stream].push(chunk.subarray(0, remaining));
        bytes += chunk.length;
        if (bytes > maxBuffer) { status ??= 'output-limit'; terminateGroup(child.pid); }
      });
    }
    child.on('error', error => { failure = error; });
    child.on('exit', () => terminateGroup(child.pid));
    child.on('close', (exit, signal) => {
      clearTimeout(timer);
      clearTimeout(activeChildren.get(child.pid)?.escalation);
      activeChildren.delete(child.pid);
      if (cancelled && activeChildren.size === 0) process.exit(cancelled);
      resolveResult({
        command, args, status: status ?? (failure ? 'execution-error' : signal || exit < 0 ? 'crash' : 'exited'),
        exit, signal, stdout: Buffer.concat(buffers.stdout).toString('utf8'), stderr: Buffer.concat(buffers.stderr).toString('utf8'),
        error: failure?.message ?? null, milliseconds: performance.now() - started,
      });
    });
  });
}

export function subjectOutcome(result) {
  if (result.status && result.status !== 'exited') return { ...result };
  const text = `${result.stdout}\n${result.stderr}`.replace(/\x1b\[[0-9;]*m/g, '');
  const status = result.exit === 0 && !/^\s*(error|warning):/mi.test(text) && /\bOK\s+no type errors in \d+ module\(s\)/.test(text) ? 'accepted'
    : result.exit === 1 && /^error:/m.test(text) ? 'rejected' : 'unrecognized-result';
  return { ...result, status };
}

export function classify(oracle, subject) {
  if (oracle.status !== 'checked') return `oracle-${oracle.status}`;
  if (!Array.isArray(oracle.diagnostics)) throw new Error('oracle diagnostics must be an array');
  if (subject.status !== 'accepted' && subject.status !== 'rejected') return `subject-${subject.status}`;
  if (oracle.diagnostics.length === 0) return subject.status === 'accepted' ? 'diagnostics-match' : 'false-reject';
  return subject.status === 'accepted' ? 'false-accept' : 'both-reject-unverified';
}

const OUTCOMES = new Set([
  'diagnostics-match', 'false-reject', 'false-accept', 'both-reject-unverified', 'harness-unsupported',
  ...['oracle', 'subject'].flatMap(side => ['timeout', 'crash', 'output-limit', 'execution-error', 'unrecognized-result'].map(status => `${side}-${status}`)),
]);

export function summarize(ids, results) {
  const pending = new Set(ids);
  if (pending.size !== ids.length || ids.length === 0) throw new Error('inventory must contain unique, nonempty IDs');
  const counts = {};
  for (const result of results) {
    if (!pending.delete(result.id)) throw new Error(`unknown or duplicate result: ${result.id}`);
    if (!OUTCOMES.has(result.status)) throw new Error(`unknown outcome: ${result.status}`);
    counts[result.status] = (counts[result.status] ?? 0) + 1;
  }
  counts['not-run'] = pending.size;
  return {
    totalVariants: ids.length, attemptedVariants: results.length, counts,
    diagnosticMatchFraction: (counts['diagnostics-match'] ?? 0) / ids.length,
    notRun: [...pending],
  };
}
