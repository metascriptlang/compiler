import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { accessSync, constants, mkdirSync, readFileSync, realpathSync, statSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { loadOracle } from '../../src/test/compat/typescript/run.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const repo = resolve(here, '../..');
const pins = { vite: '6.3.5', rollup: '4.67.5+metascript.2', webpack: '5.99.9' };
const nativeFiles = ['compilerCore', 'sourceDeclarations', 'vite', 'rollup', 'webpack']
  .map(name => `tools/bundler-plugin/${name}.test.js`);
const consumerFile = 'src/test/js/declarationBundlers/run.mjs';
const provision = `Prerequisites must be provisioned before the gate; this wrapper never installs or repairs them.
Coordinate dependency setup before running (not a measured safe automation recipe):
  npm ci --prefix tools/bundler-plugin/harness --ignore-scripts --prefer-offline --no-audit --no-fund
  rm -rf tools/bundler-plugin/node_modules && ln -s harness/node_modules tools/bundler-plugin/node_modules
The harness pins vite@6.3.5 rollup@4.67.5+metascript.2 (vendor/rollup4.tgz) webpack@5.99.9 magic-string@0.30.17 typescript@5.9.2; harness/package-lock.json pins every transitive package. The link lets the adapters and their .d.ts resolve bare imports from their own directory.
The root override selects that Rollup for Vite too; app roots must select their host dependency explicitly.
Then explicitly set existing module paths, for example after that layout is verified:
  MSC="$PWD/out/gate/msc" VITE_MODULE="$PWD/tools/bundler-plugin/harness/node_modules/vite/dist/node/index.js" ROLLUP_MODULE="$PWD/tools/bundler-plugin/harness/node_modules/rollup/dist/es/rollup.js" WEBPACK_MODULE="$PWD/tools/bundler-plugin/harness/node_modules/webpack/lib/index.js" TS_ORACLE_MODULE="$PWD/tools/bundler-plugin/harness/node_modules/typescript/lib/typescript.js" node tools/bundler-plugin/test.mjs
MagicString must also resolve by bare ESM import from tools/bundler-plugin/vite.js; NODE_PATH is insufficient.
Node >=24 is required for test tooling only; use a pre-provisioned Node 24+ executable.
Missing candidate: include the gate build lane (manual build: msc build src/index.ms --danger --lto=off --output=out/gate/msc).`;

export function checkCandidate(candidate) {
  if (!candidate) throw new Error('MSC must explicitly name the gate candidate; no PATH or ./msc fallback');
  const path = realpathSync(resolve(candidate));
  accessSync(path, constants.X_OK);
  if (!statSync(path).isFile()) throw new Error(`MSC is not a file: ${path}`);
  return path;
}

export async function pinnedFramework(name, modulePath) {
  if (!modulePath) throw new Error(`${name.toUpperCase()}_MODULE must explicitly name an existing ${name} module`);
  const path = realpathSync(resolve(modulePath));
  const module = await import(pathToFileURL(path).href);
  const version = module.version ?? module.VERSION ?? module.default?.version;
  if (version !== pins[name]) throw new Error(`${name} version ${version}, expected ${pins[name]}: ${path}`);
  return { path, version };
}

async function prerequisites() {
  if (Number(process.versions.node.split('.')[0]) < 24) throw new Error(`Node >=24 required, got ${process.version}`);
  const msc = checkCandidate(process.env.MSC);
  const modules = {};
  const frameworks = {};
  for (const name of Object.keys(pins)) {
    const key = `${name.toUpperCase()}_MODULE`;
    frameworks[name] = await pinnedFramework(name, process.env[key]);
    modules[key] = frameworks[name].path;
  }
  // This module and vite.js share the same bare-ESM lookup location.
  const magicPath = realpathSync(fileURLToPath(import.meta.resolve('magic-string')));
  await import(pathToFileURL(magicPath).href);
  let directory = dirname(magicPath);
  let magic;
  while (true) {
    try {
      const pkg = JSON.parse(readFileSync(join(directory, 'package.json'), 'utf8'));
      if (pkg.name === 'magic-string') { magic = pkg; break; }
    } catch (error) { if (error.code !== 'ENOENT') throw error; }
    const parent = dirname(directory);
    if (parent === directory) throw new Error(`magic-string package identity not found: ${magicPath}`);
    directory = parent;
  }
  if (magic.version !== '0.30.17') throw new Error(`magic-string version ${magic.version}, expected 0.30.17: ${magicPath}`);
  if (!process.env.TS_ORACLE_MODULE) throw new Error('TS_ORACLE_MODULE must explicitly name the pinned TypeScript 5.9.2 module');
  const { identity: oracle } = loadOracle(process.env.TS_ORACLE_MODULE);
  modules.TS_ORACLE_MODULE = oracle.path;
  const receipt = { node: process.version, msc,
    compilerSha256: createHash('sha256').update(readFileSync(msc)).digest('hex'),
    frameworks, magicString: { path: magicPath, version: magic.version }, oracle };
  return { env: { ...process.env, ...modules, MSC: msc }, receipt };
}

export function checkSummary(output, expectedTests) {
  const counts = {};
  for (const key of ['tests', 'pass', 'fail', 'cancelled', 'skipped', 'todo']) {
    const matches = [...output.matchAll(new RegExp(`^# ${key} (\\d+)\\r?$`, 'gm'))];
    if (matches.length !== 1) throw new Error(`missing or duplicate TAP summary: ${key}`);
    counts[key] = Number(matches[0][1]);
  }
  const plans = [...output.matchAll(/^1\.\.(\d+)\r?$/gm)];
  if (plans.length !== 1 || Number(plans[0][1]) === 0) throw new Error('missing, empty or duplicate TAP plan');
  if (!counts.tests || counts.pass !== counts.tests || counts.fail || counts.cancelled || counts.skipped || counts.todo) {
    throw new Error(`incomplete or non-passing TAP result: ${JSON.stringify(counts)}`);
  }
  if (expectedTests !== undefined && (counts.tests !== expectedTests || Number(plans[0][1]) !== expectedTests)) {
    throw new Error(`expected all ${expectedTests} consumer cells: ${JSON.stringify(counts)}`);
  }
  return counts;
}

export function runInterfaces(env, out, spawn = spawnSync) {
  const results = [];
  for (const [name, files, expected] of [
    ['native', nativeFiles, undefined], ['consumers', [consumerFile], 7],
  ]) {
    const child = spawn(process.execPath,
      ['--test', '--test-concurrency=1', '--test-reporter=tap', ...files],
      { cwd: repo, env, encoding: 'utf8', maxBuffer: 32 * 1024 * 1024 });
    const output = (child.stdout ?? '') + (child.stderr ?? '');
    writeFileSync(join(out, `${name}.log`), output);
    process.stdout.write(output);
    const result = { name, status: child.status, signal: child.signal, error: child.error?.message };
    try {
      result.counts = checkSummary(child.stdout ?? '', expected);
      if (child.error || child.status !== 0 || child.signal) throw new Error('test process did not exit successfully');
      result.ok = true;
    } catch (error) { result.ok = false; result.failure = error.message; }
    console.log(`native-adapters ${name}: ${JSON.stringify(result)}`);
    results.push(result);
  }
  writeFileSync(join(out, 'statuses.json'), `${JSON.stringify(results, null, 2)}\n`);
  return results.every(result => result.ok);
}

async function main() {
  let checked;
  try { checked = await prerequisites(); }
  catch (error) {
    console.error(`FAIL native-adapters prerequisites: ${error.message}\n${provision}`);
    process.exitCode = 1;
    return;
  }
  const out = join(repo, 'out/gate/native-adapters');
  mkdirSync(out, { recursive: true });
  writeFileSync(join(out, 'identity.json'), `${JSON.stringify(checked.receipt, null, 2)}\n`);
  console.log(`native-adapters identity: ${JSON.stringify(checked.receipt)}`);
  if (!runInterfaces(checked.env, out)) process.exitCode = 1;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch(error => { console.error(`FAIL native-adapters wrapper: ${error.stack ?? error}`); process.exitCode = 1; });
}
