import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, symlinkSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { safePath, fingerprint, classify, summarize, runCommand, subjectOutcome } from './core.mjs';

function scratch(t) {
  const root = mkdtempSync(join(tmpdir(), 'ts-oracle-test-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  return root;
}

for (const name of ['../escape.ts', '/absolute.ts', 'C:/windows.ts', 'a\\b.ts', 'a/../../escape.ts', '']) {
  test(`virtual path refuses ${JSON.stringify(name)}`, () => {
    assert.throws(() => safePath('/sandbox', name));
  });
}

test('virtual file remains inside the sandbox', () => {
  assert.equal(safePath('/sandbox', 'src/a.ts'), '/sandbox/src/a.ts');
});

test('fingerprint detects changed, missing and extra source files', t => {
  const root = scratch(t);
  mkdirSync(join(root, 'cases'));
  writeFileSync(join(root, 'cases', 'a.ts'), 'const x = 1;\r\n');
  const original = fingerprint(root, ['cases']);
  writeFileSync(join(root, 'cases', 'a.ts'), 'const x = 1;\n');
  assert.notEqual(fingerprint(root, ['cases']).sha256, original.sha256);
  writeFileSync(join(root, 'cases', 'a.ts'), 'const x = 1;\r\n');
  assert.equal(fingerprint(root, ['cases']).sha256, original.sha256);
  writeFileSync(join(root, 'cases', 'b.ts'), '');
  assert.notEqual(fingerprint(root, ['cases']).sha256, original.sha256);
  rmSync(join(root, 'cases', 'a.ts'));
  assert.notEqual(fingerprint(root, ['cases']).sha256, original.sha256);
});

test('fingerprint refuses a symlink rather than reading outside the snapshot', t => {
  const root = scratch(t);
  mkdirSync(join(root, 'cases'));
  symlinkSync(import.meta.filename, join(root, 'cases', 'link.ts'));
  assert.throws(() => fingerprint(root, ['cases']), /symlink/);
});

test('fingerprint refuses symlink ancestors of selected roots', t => {
  const root = scratch(t);
  mkdirSync(join(root, 'real'));
  writeFileSync(join(root, 'real', 'case.ts'), '');
  symlinkSync(join(root, 'real'), join(root, 'alias'));
  assert.throws(() => fingerprint(root, ['alias/case.ts']), /symlink/);
});

test('a missing snapshot root is not an empty passing inventory', t => {
  assert.throws(() => fingerprint(scratch(t), ['missing']));
});

const accepted = { status: 'checked', diagnostics: [] };
const rejected = { status: 'checked', diagnostics: [{ code: 2347, file: 'main.ts', line: 2, column: 1, message: 'bad call' }] };

test('accepting a valid case matches the pre-emit diagnostic surface only', () => {
  assert.equal(classify(accepted, { status: 'accepted' }), 'diagnostics-match');
});

test('reject-all compiler is caught on positive cases', () => {
  assert.equal(classify(accepted, { status: 'rejected' }), 'false-reject');
});

test('accept-all compiler is caught on negative cases', () => {
  assert.equal(classify(rejected, { status: 'accepted' }), 'false-accept');
});

test('two failures do not prove diagnostic agreement', () => {
  assert.equal(classify(rejected, { status: 'rejected' }), 'both-reject-unverified');
});

for (const status of ['timeout', 'crash', 'output-limit', 'execution-error', 'unrecognized-result']) {
  test(`subject ${status} never passes a negative test`, () => {
    assert.equal(classify(rejected, { status }), `subject-${status}`);
  });
}

test('oracle infrastructure failure is not a subject diagnostic', () => {
  assert.equal(classify({ status: 'timeout' }, { status: 'accepted' }), 'oracle-timeout');
});

test('selection preserves the full denominator and explicitly unrun IDs', () => {
  const report = summarize(['a', 'b', 'c'], [{ id: 'b', status: 'diagnostics-match' }]);
  assert.equal(report.totalVariants, 3);
  assert.equal(report.attemptedVariants, 1);
  assert.equal(report.counts['not-run'], 2);
  assert.deepEqual(report.notRun, ['a', 'c']);
  assert.equal(report.diagnosticMatchFraction, 1 / 3);
});

test('an unsupported adapter remains in the denominator', () => {
  const report = summarize(['a', 'b'], [{ id: 'a', status: 'harness-unsupported' }]);
  assert.equal(report.totalVariants, 2);
  assert.equal(report.diagnosticMatchFraction, 0);
  assert.equal(report.counts['harness-unsupported'], 1);
});

for (const results of [
  [{ id: 'a', status: 'diagnostics-match' }, { id: 'a', status: 'false-reject' }],
  [{ id: 'unknown', status: 'diagnostics-match' }],
  [{ id: 'a', status: 'invented-pass' }],
]) {
  test(`invalid result accounting refuses ${JSON.stringify(results)}`, () => {
    assert.throws(() => summarize(['a'], results));
  });
}

test('duplicate inventory IDs fail loud', () => {
  assert.throws(() => summarize(['a', 'a'], []));
});

test('exit zero without a checker success receipt is not acceptance', () => {
  assert.equal(subjectOutcome({ exit: 0, stdout: '', stderr: '' }).status, 'unrecognized-result');
});

test('a success receipt alongside an error is not acceptance', () => {
  assert.equal(subjectOutcome({ exit: 0, stdout: 'OK no type errors in 1 module(s)', stderr: 'error: broken invariant' }).status, 'unrecognized-result');
});

test('nonzero without diagnostics is not a correct rejection', () => {
  assert.equal(subjectOutcome({ exit: 1, stdout: '', stderr: 'internal failure' }).status, 'unrecognized-result');
});

test('checker error receipt is recognized but not claimed equivalent to the oracle', () => {
  assert.equal(subjectOutcome({ exit: 1, stdout: '', stderr: 'error: bad type\n' }).status, 'rejected');
});

test('real subprocess controls distinguish success, failure and a crash', () => {
  assert.equal(runCommand(process.execPath, ['-e', 'console.log("ok")']).exit, 0);
  assert.equal(runCommand(process.execPath, ['-e', 'process.exit(1)']).exit, 1);
  const result = runCommand(process.execPath, ['-e', 'process.kill(process.pid, "SIGTERM")']);
  assert.equal(result.status, 'crash');
});

test('a real timeout cannot count as a negative agreement', () => {
  const result = runCommand(process.execPath, ['-e', 'setInterval(() => {}, 1000)'], { timeout: 100 });
  assert.equal(result.status, 'timeout');
  assert.equal(classify(rejected, subjectOutcome(result)), 'subject-timeout');
});

test('output overflow is named, not silently truncated into a success', () => {
  const result = runCommand(process.execPath, ['-e', 'console.log("x".repeat(100000))'], { maxBuffer: 100 });
  assert.equal(result.status, 'output-limit');
});
