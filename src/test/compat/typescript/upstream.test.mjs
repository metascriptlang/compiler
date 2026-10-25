import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, mkdirSync, mkdtempSync, rmSync, chmodSync, readdirSync, copyFileSync, existsSync, realpathSync, symlinkSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import test from 'node:test';
import { loadOracle, oracleCheck } from './run.mjs';
import { verifySnapshot, loadHarness, enumerate, prepareCase } from './upstream.mjs';
import { runCommand, sha256 } from './core.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const pin = JSON.parse(readFileSync(join(here, 'pin.json'), 'utf8'));
const source = resolve(process.env.TS_ORACLE_SOURCE ?? join(here, '../../../../out/compat/typescript/upstream'));
const { ts, identity } = loadOracle();
const snapshot = verifySnapshot(source, pin);
const harness = loadHarness(ts, source);
const entries = enumerate(source, snapshot, harness);

function scratch(t) {
  const root = mkdtempSync(join(tmpdir(), 'ts-oracle-upstream-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  return root;
}

function prepared(text) {
  return prepareCase(ts, harness, text, { file: 'synthetic.ts', configuration: {} });
}

test('full pinned inventory and configurations have independent identities', () => {
  assert.equal(snapshot.cases.length, 12373);
  assert.equal(entries.length, 13672);
  assert.equal(new Set(entries.map(entry => entry.id)).size, entries.length);
  assert.ok(entries.some(entry => entry.file.includes('/types/any/anyAsConstructor.ts')));
  assert.ok(entries.some(entry => entry.file.endsWith('.tsx')));
});

test('upstream Cartesian option expansion is preserved', () => {
  const settings = harness.TestCaseParser.extractCompilerSettings('// @target: es5, es2015\n// @module: commonjs, esnext\n');
  const variants = harness.getFileBasedTestConfigurations(settings, harness.varyBy);
  assert.equal(variants.length, 4);
  assert.deepEqual(new Set(variants.map(value => `${value.target}:${value.module}`)), new Set(['es5:commonjs', 'es5:esnext', 'es2015:commonjs', 'es2015:esnext']));
});

test('star, exclusions and enum aliases use upstream semantics', () => {
  const alias = harness.getFileBasedTestConfigurations({ target: 'es6,es2015,es2020' }, harness.varyBy);
  assert.equal(alias.length, 2);
  const variants = harness.getFileBasedTestConfigurations({ strict: '*,!false' }, harness.varyBy);
  assert.equal(variants.length, 1);
  assert.equal(variants[0].strict, 'true');
});

test('virtual files and options come from the upstream parser', () => {
  const result = prepared('// @strict: true\r\n// @noImplicitReferences: true\r\n// @filename: helper.ts\r\nexport const value = 1;\r\n// @filename: main.ts\r\nimport { value } from "./helper";\r\nconsole.log(value);');
  assert.equal(result.options.strict, true);
  assert.equal(result.files.length, 2);
  assert.equal(result.files[0].content, 'export const value = 1;');
  assert.deepEqual([...result.roots], ['main.ts']);
  assert.deepEqual(result.unsupported, []);
});

for (const [name, text] of [
  ['multiple roots', '// @filename: a.ts\nconst a = 1;\n// @filename: b.ts\nconst b = 2;'],
  ['case-insensitive host', '// @useCaseSensitiveFileNames: false\nconst x = 1;'],
  ['virtual config', '// @filename: tsconfig.json\n{}\n// @filename: main.ts\nconst x = 1;'],
  ['path-dependent options', '// @baseUrl: ./src\nconst x = 1;'],
]) {
  test(`${name} is named unsupported, not silently approximated`, () => {
    assert.ok(prepared(text).unsupported.length > 0);
  });
}

test('unrecognized harness options fail loud', () => {
  assert.throws(() => prepared('// @inventedSetting: true\nconst x = 1;'), /Unknown compiler option/);
});

test('snapshot tampering is rejected before executing upstream code', () => {
  assert.throws(() => verifySnapshot(source, { ...pin, snapshotSha256: '0'.repeat(64) }), /snapshot differs/);
});

test('untrusted module is not executed to discover its version', t => {
  const root = scratch(t);
  const path = join(root, 'typescript.cjs');
  writeFileSync(path, 'throw new Error("should never execute");');
  assert.throws(() => loadOracle(path), /module differs/);
});

for (const name of ['arrayLiteral1', 'arithmeticOnInvalidTypes', 'destructuringTypeGuardFlow']) {
  test(`real oracle agrees with direct pinned tsc diagnostics for ${name}`, async t => {
    const root = scratch(t);
    const entry = entries.find(item => item.file === `tests/cases/compiler/${name}.ts`);
    const spec = prepareCase(ts, harness, readFileSync(join(source, entry.file), 'utf8'), entry);
    for (const file of spec.files) writeFileSync(join(root, file.name), file.content);
    const observed = oracleCheck({ root, roots: spec.roots, options: spec.options, oracle: identity.path });
    const args = [join(dirname(identity.path), 'tsc.js'), '--pretty', 'false', '--noEmit',
      ...(spec.options.strictNullChecks ? ['--strictNullChecks'] : []), join(root, spec.roots[0])];
    const direct = await runCommand(process.execPath, args, { cwd: root });
    assert.equal(direct.status, 'exited');
    const expectedCodes = [...direct.stdout.matchAll(/error TS(\d+):/g)].map(match => Number(match[1])).sort((a, b) => a - b);
    assert.equal(direct.exit, expectedCodes.length ? 2 : 0);
    assert.deepEqual(observed.diagnostics.map(item => item.code).sort((a, b) => a - b), expectedCodes);
  });
}

test('oracle module resolution keeps virtual files case-sensitive', t => {
  const root = scratch(t);
  writeFileSync(join(root, 'helper.ts'), 'export const value = 1;');
  writeFileSync(join(root, 'main.ts'), 'import { value } from "./Helper"; console.log(value);');
  const result = oracleCheck({ root, roots: ['main.ts'], options: {}, oracle: identity.path });
  assert.ok(result.diagnostics.some(item => item.code === 2307));
  writeFileSync(join(root, 'main.ts'), 'import { value } from "./helper"; console.log(value);');
  assert.deepEqual(oracleCheck({ root, roots: ['main.ts'], options: {}, oracle: identity.path }).diagnostics, []);
});

test('oracle cannot accidentally import a real file outside its virtual project', t => {
  const parent = scratch(t);
  const root = join(parent, 'input');
  mkdirSync(root);
  writeFileSync(join(parent, 'outside.ts'), 'export const value = 1;');
  writeFileSync(join(root, 'main.ts'), 'import { value } from "../outside"; console.log(value);');
  const result = oracleCheck({ root, roots: ['main.ts'], options: {}, oracle: identity.path });
  assert.ok(result.diagnostics.some(item => item.code === 2307));
});

test('upstream roots follow the last-file reference rule', () => {
  const result = prepared('// @filename: helper.ts\nexport const value = 1;\n// @filename: main.ts\nconst helper = require("./helper");');
  assert.deepEqual([...result.roots], ['main.ts']);
  assert.deepEqual(result.unsupported, []);
});

function fakeSubject(root, mode) {
  mkdirSync(join(root, 'std/core/system'), { recursive: true });
  writeFileSync(join(root, 'std/core/system/index.ms'), '');
  mkdirSync(join(root, 'runtime'));
  const binary = join(root, 'subject');
  const action = mode === 'accept' ? 'console.log("OK no type errors in 1 module(s)");'
    : mode === 'reject' ? 'console.error("error: deliberate reject-all control"); process.exit(1);'
    : 'process.kill(process.pid, "SIGTERM");';
  writeFileSync(binary, `#!/usr/bin/env node\nif (process.argv.includes('--version')) { console.log('control'); } else { ${action} }\n`);
  chmodSync(binary, 0o755);
  return binary;
}

test('a positive-only partial survey is not a full green and cannot overwrite evidence', async t => {
  const root = scratch(t);
  const binary = fakeSubject(root, 'accept');
  const out = join(root, 'report');
  const args = [join(here, 'run.mjs'), 'run', '--source', source, '--oracle', identity.path,
    '--msc', binary, '--out', out, '--only', 'tests/cases/compiler/arrayLiteral1.ts'];
  const result = await runCommand(process.execPath, args, { timeout: 30000 });
  assert.equal(result.exit, 1, result.stderr);
  const original = readFileSync(join(out, 'report.json'), 'utf8');
  const report = JSON.parse(original);
  assert.equal(report.counts['diagnostics-match'], 1);
  assert.equal(report.counts['not-run'], 13671);
  const repeat = await runCommand(process.execPath, args, { timeout: 30000 });
  assert.equal(repeat.exit, 2);
  assert.equal(readFileSync(join(out, 'report.json'), 'utf8'), original);
});

for (const filename of ['tsc.js', '_tsc.js']) {
  test(`oracle CLI tampering in ${filename} is refused before execution`, t => {
    const root = scratch(t);
    const lib = join(root, 'lib');
    mkdirSync(lib);
    for (const name of readdirSync(dirname(identity.path))) {
      if (name.endsWith('.d.ts') || ['typescript.js', 'tsc.js', '_tsc.js'].includes(name)) {
        copyFileSync(join(dirname(identity.path), name), join(lib, name));
      }
    }
    writeFileSync(join(lib, filename), 'throw new Error("must not execute");');
    assert.throws(() => loadOracle(join(lib, 'typescript.js')), /oracle CLI differs/);
  });
}

test('resolution tracing cannot contaminate the JSON oracle receipt', async t => {
  const root = scratch(t);
  const binary = fakeSubject(root, 'accept');
  const out = join(root, 'report');
  const id = 'tests/cases/compiler/libReplacement.ts#libReplacement=true';
  const result = await runCommand(process.execPath, [join(here, 'run.mjs'), 'run', '--source', source, '--oracle', identity.path,
    '--msc', binary, '--out', out, '--only', id], { timeout: 30000 });
  assert.equal(result.exit, 1, result.stderr);
  const receipt = JSON.parse(readFileSync(join(out, 'cases', sha256(id), 'oracle-process.json'), 'utf8'));
  const checked = JSON.parse(receipt.stdout);
  assert.equal(checked.status, 'checked');
  assert.ok(checked.traces.length > 0);
});

test('oracle timeout has infrastructure exit status and preserves the comparison plan', async t => {
  const root = scratch(t);
  const binary = fakeSubject(root, 'accept');
  const out = join(root, 'report');
  const result = await runCommand(process.execPath, [join(here, 'run.mjs'), 'run', '--source', source, '--oracle', identity.path,
    '--msc', binary, '--out', out, '--only', 'tests/cases/compiler/arrayLiteral1.ts', '--timeout', '1'], { timeout: 30000 });
  assert.equal(result.exit, 2, result.stderr);
  const report = JSON.parse(readFileSync(join(out, 'report.json'), 'utf8'));
  const plan = JSON.parse(readFileSync(join(out, 'plan.json'), 'utf8'));
  assert.equal(report.counts['oracle-timeout'], 1);
  assert.equal(plan.subject.binarySha256, report.subject.binarySha256);
  assert.equal(plan.selected.length, 1);
});

test('subject provenance ignores incomplete adjacent support directories', async t => {
  const root = scratch(t);
  const original = fakeSubject(root, 'accept');
  const bin = join(root, 'a/b/c');
  mkdirSync(join(bin, 'std'), { recursive: true });
  mkdirSync(join(bin, 'runtime'));
  const binary = join(bin, 'subject');
  copyFileSync(original, binary);
  chmodSync(binary, 0o755);
  const out = join(root, 'report');
  const result = await runCommand(process.execPath, [join(here, 'run.mjs'), 'run', '--source', source, '--oracle', identity.path,
    '--msc', binary, '--out', out, '--only', 'tests/cases/compiler/arrayLiteral1.ts'], { timeout: 30000 });
  assert.equal(result.exit, 1, result.stderr);
  const report = JSON.parse(readFileSync(join(out, 'report.json'), 'utf8'));
  assert.equal(report.subject.support, realpathSync(root));
});

test('ambient subject project configuration cannot fabricate a diagnostic match', async t => {
  const root = scratch(t);
  const binary = fakeSubject(root, 'accept');
  writeFileSync(join(root, 'build.ms'), 'export default { globalImports: ["outside"] };');
  const out = join(root, 'report');
  const result = await runCommand(process.execPath, [join(here, 'run.mjs'), 'run', '--source', source, '--oracle', identity.path,
    '--msc', binary, '--out', out, '--only', 'tests/cases/compiler/arrayLiteral1.ts'], { timeout: 30000 });
  assert.equal(result.exit, 1, result.stderr);
  const report = JSON.parse(readFileSync(join(out, 'report.json'), 'utf8'));
  assert.equal(report.counts['harness-unsupported'], 1);
  assert.match(report.results[0].reasons[0], /ambient project config/);
  assert.equal(report.counts['diagnostics-match'] ?? 0, 0);
});

test('stdin import is not mistaken for a CLI entry', { timeout: 5000 }, async t => {
  const child = spawn(process.execPath, ['--input-type=module', '-']);
  const closed = once(child, 'close');
  t.after(() => child.kill('SIGKILL'));
  let stdout = '';
  let stderr = '';
  child.stdout.on('data', data => { stdout += data; });
  child.stderr.on('data', data => { stderr += data; });
  child.stdin.end(`await import(${JSON.stringify(new URL('./run.mjs', import.meta.url).href)});`);
  const [exit] = await closed;
  assert.equal(exit, 0, stderr);
  assert.equal(stdout, '');
});

test('invoking the CLI through a symlink still executes its command', async t => {
  const root = scratch(t);
  const link = join(root, 'oracle.mjs');
  symlinkSync(join(here, 'run.mjs'), link);
  const out = join(root, 'inventory');
  const result = await runCommand(process.execPath, [link, 'inventory', '--source', source, '--oracle', identity.path, '--out', out], { timeout: 30000 });
  assert.equal(result.exit, 0, result.stderr);
  assert.equal(existsSync(join(out, 'inventory.json')), true);
});

test('changing harness bytes mid-run invalidates the verdict', async t => {
  const root = scratch(t);
  const copied = join(root, 'copied/src/test/compat/typescript');
  mkdirSync(copied, { recursive: true });
  for (const name of ['core.mjs', 'upstream.mjs', 'run.mjs', 'pin.json']) copyFileSync(join(here, name), join(copied, name));
  const binary = fakeSubject(root, 'accept');
  writeFileSync(binary, `#!/usr/bin/env node\nif (process.argv.includes('--version')) console.log('control'); else { require('node:fs').appendFileSync(${JSON.stringify(join(copied, 'core.mjs'))}, '\\n'); console.log('OK no type errors in 1 module(s)'); }\n`);
  const out = join(root, 'report');
  const result = await runCommand(process.execPath, [join(copied, 'run.mjs'), 'run', '--source', source, '--oracle', identity.path,
    '--msc', binary, '--out', out, '--only', 'tests/cases/compiler/arrayLiteral1.ts'], { timeout: 30000 });
  assert.equal(result.exit, 2, result.stderr);
  assert.match(result.stderr, /harness changed/);
  assert.equal(existsSync(join(out, 'report.json')), false);
  assert.equal(existsSync(join(out, 'plan.json')), true);
});

for (const [mode, positive, negative] of [
  ['accept', 'diagnostics-match', 'false-accept'],
  ['reject', 'false-reject', 'both-reject-unverified'],
  ['crash', 'subject-crash', 'subject-crash'],
]) {
  test(`end-to-end ${mode} control cannot fabricate compatibility`, async t => {
    const root = scratch(t);
    const binary = fakeSubject(root, mode);
    const out = join(root, 'report');
    const result = await runCommand(process.execPath, [join(here, 'run.mjs'), 'run', '--source', source, '--oracle', identity.path,
      '--msc', binary, '--out', out, '--only', 'tests/cases/compiler/arrayLiteral1.ts',
      '--only', 'tests/cases/conformance/types/any/anyAsConstructor.ts'], { timeout: 30000 });
    assert.equal(result.status, 'exited', result.stderr);
    assert.equal(result.exit, 1, result.stderr);
    const report = JSON.parse(readFileSync(join(out, 'report.json'), 'utf8'));
    assert.equal(report.totalVariants, 13672);
    assert.equal(report.selectedVariants, 2);
    assert.equal(report.selectionComplete, true);
    assert.equal(report.fullSweep, false);
    assert.equal(report.counts['not-run'], 13670);
    assert.equal(report.results.find(item => item.file.endsWith('arrayLiteral1.ts')).status, positive);
    assert.equal(report.results.find(item => item.file.endsWith('anyAsConstructor.ts')).status, negative);
    assert.equal(report.diagnosticMatchFraction, mode === 'accept' ? 1 / 13672 : 0);
  });
}
