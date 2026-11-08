import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';
import { checkCandidate, checkSummary, pinnedFramework, runInterfaces } from './test.mjs';

const repo = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
function fixture(t) {
  const dir = mkdtempSync(join(tmpdir(), 'native-gate-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  return dir;
}
function tap(tests = 7) {
  return `TAP version 13\n1..${tests}\n# tests ${tests}\n# pass ${tests}\n# fail 0\n# cancelled 0\n# skipped 0\n# todo 0\n`;
}

test('candidate is explicit, existing, executable and never a PATH fallback', t => {
  const dir = fixture(t);
  assert.throws(() => checkCandidate(), /explicitly.*candidate/);
  assert.throws(() => checkCandidate(join(dir, 'missing')), /ENOENT/);
  assert.throws(() => checkCandidate(dir), /not a file/);
  const candidate = join(dir, 'candidate');
  writeFileSync(candidate, 'fixture');
  assert.throws(() => checkCandidate(candidate), /EACCES/);
  chmodSync(candidate, 0o755);
  assert.equal(checkCandidate(candidate), candidate);
});

test('framework preflight rejects absent modules and wrong exact versions', async t => {
  const dir = fixture(t);
  await assert.rejects(pinnedFramework('vite'), /VITE_MODULE.*explicitly/);
  await assert.rejects(pinnedFramework('rollup', join(dir, 'missing.mjs')), /ENOENT/);
  for (const name of ['vite', 'rollup', 'webpack']) {
    const module = join(dir, `${name}.mjs`);
    writeFileSync(module, 'export const version = "0.0.0";');
    await assert.rejects(pinnedFramework(name, module), new RegExp(`${name} version 0.0.0, expected`));
  }
});

test('prerequisite failure is nonzero, named and provides pinned provisioning guidance', t => {
  const dir = fixture(t);
  const child = spawnSync(process.execPath, ['tools/bundler-plugin/test.mjs'], {
    cwd: repo, encoding: 'utf8', env: { ...process.env, MSC: join(dir, 'missing') },
  });
  assert.equal(child.status, 1);
  assert.match(child.stderr, /FAIL native-adapters prerequisites:.*ENOENT/);
  assert.match(child.stderr, /npm ci --prefix tools\/bundler-plugin --ignore-scripts/);
  for (const pin of ['vite@6.3.5', 'rollup@4.67.5+metascript.2', 'webpack@5.99.9', 'magic-string@0.30.17', 'typescript@5.9.2']) {
    assert.ok(child.stderr.includes(pin));
  }
  assert.match(child.stderr, /no measured|not a measured safe automation/);
  assert.doesNotMatch(child.stdout, /native-adapters (native|consumers):/);
});

test('TAP acceptance rejects skips, todos, cancellation, failures and partial summaries', () => {
  assert.equal(checkSummary(tap(), 7).pass, 7);
  for (const key of ['fail', 'cancelled', 'skipped', 'todo']) {
    assert.throws(() => checkSummary(tap().replace(`# ${key} 0`, `# ${key} 1`), 7), /non-passing/);
  }
  for (const key of ['tests', 'pass', 'fail', 'cancelled', 'skipped', 'todo']) {
    assert.throws(() => checkSummary(tap().replace(new RegExp(`# ${key} \\d+\\n`), '')), /summary/);
  }
  for (const output of ['', tap(0), tap() + '# pass 7\n', tap().replace('1..7', '1..0')]) {
    assert.throws(() => checkSummary(output));
  }
  assert.throws(() => checkSummary(tap(6), 7), /all 7 consumer cells/);
  assert.throws(() => checkSummary(tap().replace('# pass 7', '# pass 6')), /non-passing/);
});

test('both complete serial commands run and persist actual statuses even after native failure', t => {
  const out = fixture(t);
  const calls = [];
  const env = { MSC: '/explicit/gate/candidate' };
  const spawn = (executable, args, options) => {
    calls.push({ executable, args, options });
    return { status: calls.length === 1 ? 1 : 0, signal: null, stdout: tap(), stderr: 'fixture log\n' };
  };
  assert.equal(runInterfaces(env, out, spawn), false);
  assert.equal(calls.length, 2);
  assert.deepEqual(calls[0].args, ['--test', '--test-concurrency=1', '--test-reporter=tap',
    ...['compilerCore', 'sourceDeclarations', 'vite', 'rollup', 'webpack'].map(name => `tools/bundler-plugin/${name}.test.js`)]);
  assert.deepEqual(calls[1].args, ['--test', '--test-concurrency=1', '--test-reporter=tap', 'src/test/js/declarationBundlers/run.mjs']);
  for (const call of calls) {
    assert.equal(call.executable, process.execPath);
    assert.equal(call.options.env.MSC, env.MSC);
    assert.equal(call.options.cwd, repo);
  }
  const statuses = JSON.parse(readFileSync(join(out, 'statuses.json')));
  assert.deepEqual(statuses.map(result => [result.name, result.status, result.ok]), [['native', 1, false], ['consumers', 0, true]]);
  assert.match(readFileSync(join(out, 'native.log'), 'utf8'), /fixture log/);
  assert.match(readFileSync(join(out, 'consumers.log'), 'utf8'), /fixture log/);
});

test('zero exit cannot conceal a skipped interface or a signalled process', t => {
  const out = fixture(t);
  let calls = 0;
  assert.equal(runInterfaces({}, out, () => ++calls === 1
    ? { status: 0, signal: null, stdout: tap().replace('# skipped 0', '# skipped 1') }
    : { status: null, signal: 'SIGTERM', stdout: tap() }), false);
  assert.equal(calls, 2);
  assert.deepEqual(JSON.parse(readFileSync(join(out, 'statuses.json'))).map(result => result.ok), [false, false]);
});

for (const [name, npmStatus] of [
  ['tools lane provisions once, invokes wrapper with CAND and names its red', 0],
  ['tools lane names a prerequisite red and never runs the wrapper after install failure', 2],
]) test(name, t => {
  const dir = fixture(t);
  mkdirSync(join(dir, 'bin'));
  writeFileSync(join(dir, 'why'), 'tools\ttools/bundler-plugin/vite.js\ntools\ttools/bundler-plugin/test.mjs\ntools\tsrc/test/js/declarationBundlers/run.mjs\n');
  const node = join(dir, 'bin/node');
  writeFileSync(node, '#!/usr/bin/env bash\ncase "$*" in "-e "*) exit 0 ;; esac\nprintf "%s|%s\\n" "$MSC" "$*" >>"$CALLS"\ncase "$*" in tools/bundler-plugin/test.mjs) printf "%s\\n" "$VITE_MODULE" "$ROLLUP_MODULE" "$WEBPACK_MODULE" "$TS_ORACLE_MODULE" >"$CALLS.env"; exit 3 ;; esac\n');
  chmodSync(node, 0o755);
  const npm = join(dir, 'bin/npm');
  writeFileSync(npm, '#!/usr/bin/env bash\nprintf "%s\\n" "$*" >>"$CALLS.npm"\nexit "$NPM_STATUS"\n');
  chmodSync(npm, 0o755);
  const source = readFileSync(join(repo, 'tools/gate.sh'), 'utf8');
  const body = source.match(/^run_tools_lane\(\) \{\n[\s\S]*?^\}/m)?.[0];
  assert.ok(body, 'tools lane definition must remain discoverable');
  const child = spawnSync('bash', ['-c', `${body}\nrun_tools_lane`], {
    cwd: repo, encoding: 'utf8', env: { ...process.env, TOP: repo, OUT: dir, CAND: '/actual/gate/candidate', MSC: '/wrong/inherited/compiler',
      PATH: `${join(dir, 'bin')}:${process.env.PATH}`, CALLS: join(dir, 'calls'), NPM_STATUS: String(npmStatus) },
  });
  assert.equal(child.status, 1, child.stderr);
  assert.ok(child.stdout.includes('FAIL tools/bundler-plugin/test.mjs: check'));
  if (npmStatus) assert.match(child.stdout, /dependency provisioning failed; wrapper was not run/);
  const reds = source.match(/^reds_of\(\) \{\n[\s\S]*?^\}/m)?.[0];
  assert.ok(reds);
  const log = join(dir, 'tools.log');
  writeFileSync(log, child.stdout);
  const parsed = spawnSync('bash', ['-c', `${reds}\nreds_of tools "$1" 1`, '--', log], { cwd: repo, encoding: 'utf8' });
  assert.equal(parsed.status, 0, parsed.stderr);
  assert.equal(parsed.stdout, 'tools/bundler-plugin/test.mjs\n');
  assert.equal(readFileSync(join(dir, 'calls.npm'), 'utf8'), 'ci --prefix tools/bundler-plugin --ignore-scripts --prefer-offline --no-audit --no-fund\n');
  const calls = readFileSync(join(dir, 'calls'), 'utf8').trim().split('\n');
  assert.equal(calls.length, npmStatus ? 1 : 2);
  if (!npmStatus) {
    assert.equal(calls[1], '/actual/gate/candidate|tools/bundler-plugin/test.mjs');
    assert.deepEqual(readFileSync(join(dir, 'calls.env'), 'utf8').trim().split('\n'), [
      'vite/dist/node/index.js', 'rollup/dist/es/rollup.js', 'webpack/lib/index.js', 'typescript/lib/typescript.js',
    ].map(file => join(repo, 'tools/bundler-plugin/node_modules', file)));
  }
});
