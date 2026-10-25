import { createRequire } from 'node:module';
import { parseArgs } from 'node:util';
import { dirname, join, resolve, delimiter, relative, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { existsSync, readFileSync, readdirSync, realpathSync, mkdirSync, writeFileSync, mkdtempSync, renameSync, rmSync, appendFileSync } from 'node:fs';
import { sha256, safePath, fingerprint, runCommand, subjectOutcome, classify, summarize, findSupportRoot, ambientProjectConfig } from './core.mjs';
import { verifySnapshot, loadHarness, enumerate, prepareCase } from './upstream.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const repo = resolve(here, '../../../..');
const pin = JSON.parse(readFileSync(join(here, 'pin.json'), 'utf8'));
const defaultSource = join(repo, 'out/compat/typescript/upstream');
const defaultOracle = join(repo, 'out/compat/typescript/oracle/lib/typescript.js');
const require = createRequire(import.meta.url);

function json(path, value) {
  writeFileSync(path, `${JSON.stringify(value, null, 2)}\n`, { flag: 'wx' });
}

function executable(name) {
  if (name.includes('/') || name.includes('\\')) return realpathSync(name);
  for (const dir of (process.env.PATH ?? '').split(delimiter)) {
    for (const ext of process.platform === 'win32' ? ['', '.exe', '.cmd'] : ['']) {
      const path = join(dir, name + ext);
      if (existsSync(path)) return realpathSync(path);
    }
  }
  throw new Error(`executable not found: ${name}`);
}

export function loadOracle(modulePath) {
  const path = realpathSync(modulePath ?? process.env.TS_ORACLE_MODULE ??
    (existsSync(defaultOracle) ? defaultOracle : join(dirname(executable('tsc')), '../lib/typescript.js')));
  const moduleSha256 = sha256(readFileSync(path));
  if (moduleSha256 !== pin.oracleModuleSha256) throw new Error(`oracle module differs from pinned ${pin.version}: ${path}`);
  const lib = dirname(path);
  const libraries = readdirSync(lib).filter(name => name.endsWith('.d.ts')).sort();
  const librarySha256 = sha256(libraries.map(name => `${name}\0${sha256(readFileSync(join(lib, name)))}\n`).join(''));
  if (librarySha256 !== pin.oracleLibrarySha256) throw new Error('oracle standard library differs from pin');
  const cliSha256 = {};
  for (const [name, expected] of Object.entries(pin.oracleCliSha256)) {
    const actual = sha256(readFileSync(join(lib, name)));
    if (actual !== expected) throw new Error(`oracle CLI differs from pin: ${name}`);
    cliSha256[name] = actual;
  }
  const ts = require(path);
  if (ts.version !== pin.version) throw new Error(`oracle version ${ts.version}, expected ${pin.version}`);
  return { ts, identity: { path, version: ts.version, moduleSha256, librarySha256, cliSha256 } };
}

function diagnosticRecord(ts, diagnostic, root) {
  const position = diagnostic.file && diagnostic.start !== undefined
    ? diagnostic.file.getLineAndCharacterOfPosition(diagnostic.start) : undefined;
  return {
    code: diagnostic.code, category: ts.DiagnosticCategory[diagnostic.category],
    file: diagnostic.file ? relative(root, diagnostic.file.fileName).split(sep).join('/') : null,
    start: diagnostic.start ?? null, length: diagnostic.length ?? null,
    line: position ? position.line + 1 : null, column: position ? position.character + 1 : null,
    message: ts.flattenDiagnosticMessageText(diagnostic.messageText, '\n'),
    relatedInformation: diagnostic.relatedInformation?.map(item => diagnosticRecord(ts, item, root)) ?? [],
  };
}

export function oracleCheck(request) {
  const { ts } = loadOracle(request.oracle);
  const root = realpathSync(request.root);
  const libraryRoot = dirname(realpathSync(request.oracle));
  const files = new Map();
  const directories = new Set();
  function include(path) {
    files.set(resolve(path), readFileSync(path, 'utf8'));
    for (let dir = dirname(path); !directories.has(dir); dir = dirname(dir)) {
      directories.add(dir);
      if (dirname(dir) === dir) break;
    }
  }
  function visit(dir) {
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      const path = join(dir, entry.name);
      if (entry.isDirectory()) visit(path);
      else if (entry.isFile()) include(path);
      else throw new Error(`unexpected sandbox entry: ${path}`);
    }
  }
  visit(root);
  for (const name of readdirSync(libraryRoot).filter(name => name.endsWith('.d.ts'))) include(join(libraryRoot, name));
  const traces = [];
  const host = ts.createCompilerHost(request.options);
  host.trace = text => traces.push(text);
  host.getCurrentDirectory = () => root;
  host.useCaseSensitiveFileNames = () => true;
  host.getCanonicalFileName = path => path;
  host.fileExists = path => files.has(resolve(path));
  host.readFile = path => files.get(resolve(path));
  host.directoryExists = path => directories.has(resolve(path));
  host.getDirectories = path => [...directories].filter(dir => dirname(dir) === resolve(path) && dir !== dirname(dir)).map(dir => relative(path, dir));
  host.realpath = path => path;
  host.getSourceFile = (path, languageVersion) => {
    const text = files.get(resolve(path));
    return text === undefined ? undefined : ts.createSourceFile(path, text, languageVersion, true);
  };
  host.writeFile = () => { throw new Error('pre-emit oracle must not write output'); };
  const program = ts.createProgram(request.roots.map(name => safePath(root, name)), request.options, host);
  return { status: 'checked', diagnostics: ts.getPreEmitDiagnostics(program).map(item => diagnosticRecord(ts, item, root)), traces };
}

async function subjectIdentity(binary) {
  const path = executable(binary);
  const support = findSupportRoot(path);
  const tree = fingerprint(support, ['std', 'runtime']);
  const version = await runCommand(path, ['--version'], { timeout: 5000 });
  if (version.status !== 'exited' || version.exit !== 0) throw new Error('subject --version failed');
  return { path, binarySha256: sha256(readFileSync(path)), support, supportSha256: tree.sha256, version };
}

async function checkCase(entry, source, harness, oracle, subject, out, timeout) {
  const dir = join(out, 'cases', sha256(entry.id));
  mkdirSync(dir, { recursive: true });
  json(join(dir, 'entry.json'), entry);
  const text = readFileSync(join(source, entry.file), 'utf8');
  let prepared;
  let paths;
  const root = join(dir, 'input');
  try {
    prepared = prepareCase(oracle.ts, harness, text, entry);
    if (prepared.unsupported.length) return { ...entry, status: 'harness-unsupported', reasons: prepared.unsupported };
    paths = prepared.files.map(file => safePath(root, file.name));
    if (new Set(paths).size !== paths.length) throw new Error('duplicate virtual file paths');
    if (prepared.files.some(file => file.name.split('/').at(-1) === 'build.ms')) throw new Error('fixture project manifest is not an isolated CLI input');
    const config = ambientProjectConfig(safePath(root, prepared.roots[0]), root);
    if (config) throw new Error(`ambient project config would affect subject: ${config}`);
  } catch (error) {
    return { ...entry, status: 'harness-unsupported', reasons: [error.message] };
  }
  mkdirSync(root);
  for (const [index, file] of prepared.files.entries()) {
    mkdirSync(dirname(paths[index]), { recursive: true });
    writeFileSync(paths[index], file.content, { flag: 'wx' });
  }
  json(join(dir, 'request.json'), { oracle: oracle.identity.path, root, roots: prepared.roots, options: prepared.options });
  json(join(dir, 'settings.json'), prepared.settings);
  const requestPath = join(dir, 'request.json');
  const request = JSON.parse(readFileSync(requestPath, 'utf8'));
  const rawOracle = await runCommand(process.execPath, [fileURLToPath(import.meta.url), 'oracle', requestPath], { timeout });
  json(join(dir, 'oracle-process.json'), rawOracle);
  let expected = { status: rawOracle.status };
  if (rawOracle.status === 'exited') {
    try {
      expected = JSON.parse(rawOracle.stdout);
      if (rawOracle.exit !== 0 || expected.status !== 'checked' || !Array.isArray(expected.diagnostics)) throw new Error('invalid oracle receipt');
    } catch {
      expected = { status: 'unrecognized-result' };
    }
  }
  json(join(dir, 'oracle.json'), expected);
  if (expected.status !== 'checked') return { ...entry, status: classify(expected, {}) };
  const actual = subjectOutcome(await runCommand(subject.path, ['check', safePath(request.root, prepared.roots[0])], { cwd: request.root, timeout }));
  json(join(dir, 'subject.json'), actual);
  return { ...entry, status: classify(expected, actual), oracleDiagnostics: expected.diagnostics.length,
    subjectStatus: actual.status, milliseconds: rawOracle.milliseconds + actual.milliseconds };
}

async function fetchArchive(source, url, hash, entries, verify) {
  if (existsSync(source)) {
    verify(source);
    console.log(`Verified existing artifact: ${source}`);
    return;
  }
  mkdirSync(dirname(source), { recursive: true });
  const work = mkdtempSync(join(dirname(source), '.fetch-'));
  const response = await fetch(url, { signal: AbortSignal.timeout(120000) });
  if (!response.ok) throw new Error(`upstream fetch: HTTP ${response.status}`);
  const archive = Buffer.from(await response.arrayBuffer());
  if (sha256(archive) !== hash) throw new Error(`archive checksum mismatch: ${url}`);
  const archivePath = join(work, 'source.tar.gz');
  writeFileSync(archivePath, archive, { flag: 'wx' });
  const extracted = join(work, 'source');
  mkdirSync(extracted);
  const result = await runCommand('tar', ['-xzf', archivePath, '-C', extracted, '--strip-components=1',
    ...entries], { timeout: 120000 });
  if (result.exit !== 0 || result.status !== 'exited') throw new Error(`upstream extract failed: ${result.stderr}`);
  verify(extracted);
  renameSync(extracted, source);
  rmSync(work, { recursive: true });
  console.log(`Fetched verified artifact: ${source}`);
}

export async function main(argv) {
  const command = argv[0];
  if (command === 'oracle') {
    if (argv.length !== 2) throw new Error('oracle requires one request');
    console.log(JSON.stringify(oracleCheck(JSON.parse(readFileSync(argv[1], 'utf8')))));
    return;
  }
  if (!['fetch', 'inventory', 'run'].includes(command)) {
    throw new Error('usage: node run.mjs fetch|inventory|run [--source DIR] [--oracle MODULE] [--msc BINARY] [--only PATH ... | --limit N | --all] [--out DIR]');
  }
  const { values } = parseArgs({ args: argv.slice(1), options: {
    source: { type: 'string' }, oracle: { type: 'string' }, msc: { type: 'string' },
    out: { type: 'string' }, only: { type: 'string', multiple: true }, limit: { type: 'string' },
    all: { type: 'boolean' }, timeout: { type: 'string' },
  } });
  const source = resolve(values.source ?? defaultSource);
  if (command === 'fetch') {
    await fetchArchive(source, pin.archiveUrl, pin.archiveSha256,
      pin.snapshotEntries.map(name => `TypeScript-${pin.commit}/${name}`), root => verifySnapshot(root, pin));
    if (values.oracle) loadOracle(values.oracle);
    else await fetchArchive(dirname(dirname(defaultOracle)), pin.oracleArchiveUrl, pin.oracleArchiveSha256,
      ['package/lib', 'package/LICENSE.txt', 'package/ThirdPartyNoticeText.txt', 'package/package.json'],
      root => loadOracle(join(root, 'lib/typescript.js')));
    return;
  }
  const harnessHash = () => fingerprint(here, ['core.mjs', 'upstream.mjs', 'run.mjs', 'pin.json']).sha256;
  const harnessSha256 = harnessHash();
  const oracle = loadOracle(values.oracle);
  const snapshot = verifySnapshot(source, pin);
  const harness = loadHarness(oracle.ts, source);
  const entries = enumerate(source, snapshot, harness);
  if (entries.length !== pin.caseVariants) throw new Error(`upstream variants: expected ${pin.caseVariants}, found ${entries.length}`);
  const out = resolve(values.out ?? join(repo, 'out/compat/typescript', `${command}-${Date.now()}`));
  mkdirSync(out, { recursive: true });
  const identity = { pin, snapshotSha256: snapshot.sha256, oracle: oracle.identity, node: process.version,
    platform: `${process.platform}-${process.arch}`, harnessSha256,
    environmentSha256: sha256(JSON.stringify(Object.entries(process.env).sort())) };
  json(join(out, 'inventory.json'), { ...identity, totalFiles: snapshot.cases.length, totalVariants: entries.length, entries });
  if (command === 'inventory') {
    console.log(`${snapshot.cases.length} files · ${entries.length} variants · ${out}`);
    return;
  }
  if ([values.all, values.only?.length > 0, values.limit !== undefined].filter(Boolean).length > 1) throw new Error('choose only one of --all, --only or --limit');
  const timeout = Number(values.timeout ?? 30000);
  const limit = Number(values.limit ?? 10);
  if (!Number.isSafeInteger(timeout) || timeout < 1 || !Number.isSafeInteger(limit) || limit < 1) throw new Error('timeout and limit must be positive integers');
  const selected = values.all ? entries : values.only ? entries.filter(entry => values.only.includes(entry.file) || values.only.includes(entry.id)) : entries.slice(0, limit);
  for (const name of values.only ?? []) if (!selected.some(entry => entry.file === name || entry.id === name)) throw new Error(`selection not in pinned inventory: ${name}`);
  const subject = await subjectIdentity(values.msc ?? process.env.MSC ?? (existsSync(join(repo, 'msc')) ? join(repo, 'msc') : 'msc'));
  json(join(out, 'plan.json'), { ...identity, subject, timeout, selected: selected.map(entry => entry.id) });
  const results = [];
  const journal = join(out, 'results.jsonl');
  writeFileSync(journal, '', { flag: 'wx' });
  const started = performance.now();
  for (const entry of selected) {
    const result = await checkCase(entry, source, harness, oracle, subject, out, timeout);
    appendFileSync(journal, `${JSON.stringify(result)}\n`);
    results.push(result);
    console.log(`${result.status}\t${entry.id}`);
  }
  const finalSubject = await subjectIdentity(subject.path);
  const finalSnapshot = verifySnapshot(source, pin);
  if (finalSubject.binarySha256 !== subject.binarySha256 || finalSubject.supportSha256 !== subject.supportSha256) {
    throw new Error('subject changed during run; journal is incomplete evidence');
  }
  if (finalSnapshot.sha256 !== snapshot.sha256) throw new Error('upstream changed during run');
  loadOracle(oracle.identity.path);
  if (harnessHash() !== harnessSha256) throw new Error('harness changed during run; journal is incomplete evidence');
  const report = {
    schema: 'typescript-oracle.v1', measurement: 'pre-emit diagnostics; no types/symbols, emit or runtime parity claim',
    ...identity, subject, selectedVariants: selected.length, selectionComplete: true, fullSweep: selected.length === entries.length,
    milliseconds: performance.now() - started,
    ...summarize(entries.map(entry => entry.id), results), results,
  };
  json(join(out, 'report.json'), report);
  console.log(JSON.stringify({ ...report.counts, totalVariants: report.totalVariants, selectedVariants: selected.length }));
  console.log(`Report: ${join(out, 'report.json')}`);
  if (results.some(result => result.status.startsWith('oracle-'))) process.exitCode = 2;
  else if (report.counts['not-run'] > 0 || results.some(result => result.status !== 'diagnostics-match')) process.exitCode = 1;
}

if (process.argv[1] && process.argv[1] !== '-' && realpathSync(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main(process.argv.slice(2)).catch(error => { console.error(error.stack ?? error); process.exitCode = 2; });
}
