import { createHash } from 'node:crypto';
import { lstatSync, readdirSync, readFileSync, realpathSync } from 'node:fs';
import { isAbsolute, relative, resolve, sep } from 'node:path';
import { spawnSync } from 'node:child_process';

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

export function runCommand(command, args, options = {}) {
  const started = performance.now();
  const result = spawnSync(command, args, {
    encoding: 'utf8', timeout: 30000, maxBuffer: 4 * 1024 * 1024,
    ...options, detached: process.platform !== 'win32', killSignal: 'SIGKILL', windowsHide: true,
    env: { ...process.env, NO_COLOR: '1', FORCE_COLOR: '0', ...options.env },
  });
  if (process.platform !== 'win32' && result.pid) {
    try { process.kill(-result.pid, 'SIGKILL'); }
    catch (error) { if (error.code !== 'ESRCH') throw error; }
  }
  const status = result.error?.code === 'ETIMEDOUT' ? 'timeout'
    : result.error?.code === 'ENOBUFS' ? 'output-limit'
    : result.error ? 'execution-error'
    : result.signal || result.status < 0 ? 'crash' : 'exited';
  return {
    command, args, status, exit: result.status, signal: result.signal,
    stdout: result.stdout ?? '', stderr: result.stderr ?? '',
    error: result.error?.message ?? null, milliseconds: performance.now() - started,
  };
}

export function subjectOutcome(result) {
  if (result.status && result.status !== 'exited') return { ...result };
  const text = `${result.stdout}\n${result.stderr}`.replace(/\x1b\[[0-9;]*m/g, '');
  const status = result.exit === 0 && !/^error:/m.test(text) && /\bOK\s+no type errors in \d+ module\(s\)/.test(text) ? 'accepted'
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
