import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import {
  mkdirSync, mkdtempSync, readFileSync, writeFileSync, copyFileSync,
  realpathSync, readdirSync, lstatSync,
} from 'node:fs';
import { dirname, resolve, join, isAbsolute, relative } from 'node:path';
import { fileURLToPath } from 'node:url';
import { loadOracle } from '../../compat/typescript/run.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const repo = resolve(here, '../../../..');
const msc = realpathSync(resolve(process.env.MSC ?? join(repo, 'msc')));
const { identity } = loadOracle(join(repo, 'out/compat/typescript/oracle/lib/typescript.js'));
console.log(`oracle ${JSON.stringify(identity)}`);
const tsc = join(dirname(identity.path), 'tsc.js');
mkdirSync(join(repo, 'out/declarationPackage'), { recursive: true });
const work = mkdtempSync(join(repo, 'out/declarationPackage/run-'));
const src = join(work, 'src');
const generated = join(work, 'generated');
const staging = join(work, 'package');
const consumer = join(work, 'consumer');
const packageName = 'msc-declaration-package-fixture';
const archiveName = `${packageName}-1.0.0.tgz`;
for (const dir of [src, staging, consumer, 'home', 'tmp', 'npm-cache', 'npm-prefix']) {
  mkdirSync(isAbsolute(dir) ? dir : join(work, dir));
}
for (const name of ['api.ms', 'model.ms', 'feature.jms']) {
  copyFileSync(join(here, name), join(src, name));
}
writeFileSync(join(src, 'package.json'), '{"type":"module"}\n');
for (const name of ['npm-user.npmrc', 'npm-global.npmrc']) writeFileSync(join(work, name), '');
const isolatedEnv = Object.fromEntries(Object.entries(process.env).filter(([key]) =>
  !/^npm_/i.test(key) && !/^(NODE_PATH|NODE_OPTIONS|INIT_CWD|PREFIX)$/i.test(key)));
Object.assign(isolatedEnv, {
  HOME: join(work, 'home'), USERPROFILE: join(work, 'home'),
  APPDATA: join(work, 'home'), LOCALAPPDATA: join(work, 'home'),
  TMPDIR: join(work, 'tmp'), TMP: join(work, 'tmp'), TEMP: join(work, 'tmp'),
  NPM_CONFIG_USERCONFIG: join(work, 'npm-user.npmrc'),
  NPM_CONFIG_GLOBALCONFIG: join(work, 'npm-global.npmrc'),
  NPM_CONFIG_CACHE: join(work, 'npm-cache'), NPM_CONFIG_PREFIX: join(work, 'npm-prefix'),
});

function command(binary, args, { cwd = consumer, expected = 0, shell = false, env = isolatedEnv } = {}) {
  const result = spawnSync(binary, args, {
    cwd, env, shell, encoding: 'utf8', timeout: 60000, maxBuffer: 16 * 1024 * 1024,
  });
  const detail = `${binary} ${args.join(' ')}\n${result.stdout ?? ''}${result.stderr ?? ''}`;
  assert.equal(result.error, undefined, detail);
  assert.equal(result.signal, null, detail);
  assert.equal(result.status, expected, detail);
  return { stdout: result.stdout, stderr: result.stderr };
}
function npm(args, cwd) {
  const flags = ['--ignore-scripts', '--no-package-lock', '--no-audit', '--no-fund'];
  assert.ok([...args, ...flags].every(arg => /^[a-zA-Z0-9_./=-]+$/.test(arg)));
  return command(process.platform === 'win32' ? 'npm.cmd' : 'npm', [...args, ...flags], {
    cwd, shell: process.platform === 'win32',
  });
}
function outputPath(root, out) {
  assert.equal(typeof out, 'string');
  assert.ok(!isAbsolute(out) && !out.includes('\\') && !out.includes(':'));
  assert.ok(out.split('/').every(part => part !== '' && part !== '.' && part !== '..'));
  return join(root, out);
}
function fileTree(root, prefix = '') {
  return readdirSync(root).flatMap(name => {
    const path = join(root, name);
    const stat = lstatSync(path);
    assert.ok(!stat.isSymbolicLink(), `package/consumer link: ${path}`);
    assert.ok(stat.isFile() || stat.isDirectory(), `unexpected file kind: ${path}`);
    return stat.isDirectory() ? fileTree(path, prefix + name + '/') : [prefix + name];
  }).sort();
}
function entryRow(rows, source) {
  const matches = rows.filter(row => row.source === realpathSync(join(src, source)));
  assert.equal(matches.length, 1, `one manifest output for ${source}`);
  return matches[0];
}
function typecheck(mode, privateSpecifier) {
  const imports = `import { PackageItem as RootItem, increment, type Label, type Envelope } from '${packageName}';
import { PackageItem as FeatureItem, featureValue, type Label as FeatureLabel, type Envelope as FeatureEnvelope } from '${packageName}/feature';`;
  const positive = `${imports}
const root = new RootItem(4);
const feature = new FeatureItem(5);
const fromFeature: RootItem = feature;
const fromRoot: FeatureItem = root;
const rootConstructor: typeof RootItem = FeatureItem;
const featureConstructor: typeof FeatureItem = RootItem;
const label: Label = ['typed'];
const featureLabel: FeatureLabel = label;
const envelope: Envelope = { value: 'typed' };
const featureEnvelope: FeatureEnvelope = envelope;
const explicit: Label<'ok'> = ['ok'];
const result: number = increment(featureValue(fromRoot)) + fromFeature.add(1);
void [rootConstructor, featureConstructor, featureLabel, featureEnvelope, explicit, result];
`;
  const cases = [
    ["increment('wrong');", 'TS2345'],
    ['increment();', 'TS2554'],
    ["new RootItem('wrong');", 'TS2345'],
    ['new RootItem();', 'TS2554'],
    ["new FeatureItem('wrong');", 'TS2345'],
    ['new FeatureItem();', 'TS2554'],
    ['featureValue(1);', 'TS2345'],
    ['featureValue();', 'TS2554'],
    ['const label: Label = [1];', 'TS2322'],
    ['const envelope: FeatureEnvelope = { value: 1 };', 'TS2322'],
    ['const constraint: FeatureLabel<number> = [1];', 'TS2344'],
    ['const forged: RootItem = { value: 1, add: (amount: number) => amount };', 'TS2739'],
    [`import { missing } from '${packageName}';`, 'TS2305'],
    [`import * as hidden from '${privateSpecifier}';`, 'TS2307'],
  ];
  const config = join(consumer, `${mode}.json`);
  const file = join(consumer, `${mode}.mts`);
  writeFileSync(config, JSON.stringify({ compilerOptions: {
    strict: true, skipLibCheck: false, noEmit: true, target: 'ES2022', types: [],
    module: mode === 'NodeNext' ? 'NodeNext' : 'ESNext', moduleResolution: mode,
  }, files: [file] }));
  writeFileSync(file, positive);
  command(process.execPath, [tsc, '-p', config]);
  writeFileSync(file, `${imports}\n${cases.map(([text]) => text).join('\n')}\n`);
  const failure = command(process.execPath, [tsc, '-p', config], { expected: 2 });
  const errors = failure.stdout + failure.stderr;
  for (const [index, [, code]] of cases.entries()) {
    assert.match(errors, new RegExp(`\\(${index + 3},[0-9]+\\): error ${code}:`), errors);
  }
  writeFileSync(join(consumer, `${mode}-negative.log`), errors);
  writeFileSync(file, positive);
}

test('packed ESM root and subpath retain the complete JS/type graph and shared nominal identity', () => {
  command(msc, ['build', join(src, 'api.ms'), '--target=js', '--split', '--declaration',
    `--js-entry=${join(src, 'feature.jms')}`, `--output=${generated}`], {
    cwd: work, env: { ...process.env, MSC_CACHE_DIR: join(work, 'compiler-cache'), MSC_NO_GLOBAL_CACHE: '1' },
  });
  const tree = JSON.parse(readFileSync(join(generated, '_manifest.json'), 'utf8'));
  assert.deepEqual(tree.entries, ['api.ms', 'feature.jms'].map(name => realpathSync(join(src, name))));
  assert.equal(tree.sourceDeclarations, undefined);
  const outputs = new Set();
  for (const group of [tree.modules, tree.instances, tree.declarations]) {
    assert.ok(Array.isArray(group));
    for (const row of group) {
      assert.equal(typeof row.source, 'string');
      assert.ok(isAbsolute(row.source));
      assert.ok(/\.(?:js|d\.ts)$/.test(row.out), `unexpected produced file: ${row.out}`);
      assert.ok(!outputs.has(row.out), `duplicate output: ${row.out}`);
      outputs.add(row.out);
      const destination = outputPath(join(staging, 'dist'), row.out);
      mkdirSync(dirname(destination), { recursive: true });
      copyFileSync(outputPath(generated, row.out), destination);
    }
  }
  const apiJs = entryRow(tree.modules, 'api.ms').out;
  const apiTypes = entryRow(tree.declarations, 'api.ms').out;
  const featureJs = entryRow(tree.modules, 'feature.jms').out;
  const featureTypes = entryRow(tree.declarations, 'feature.jms').out;
  const privateJs = entryRow(tree.modules, 'model.ms').out;
  const target = out => './dist/' + out;
  const metadata = {
    name: packageName, version: '1.0.0', private: true, type: 'module', types: target(apiTypes),
    exports: {
      '.': { types: target(apiTypes), import: target(apiJs), default: target(apiJs) },
      './feature': { types: target(featureTypes), import: target(featureJs), default: target(featureJs) },
    },
    files: ['dist'],
  };
  writeFileSync(join(staging, 'package.json'), JSON.stringify(metadata, null, 2) + '\n');
  const expectedFiles = ['package.json', ...[...outputs].map(out => 'dist/' + out)].sort();
  assert.deepEqual(fileTree(staging), expectedFiles);
  const packed = npm(['pack', '.', '--json'], staging);
  writeFileSync(join(work, 'pack.json'), packed.stdout);
  const receipts = JSON.parse(packed.stdout);
  assert.equal(receipts.length, 1);
  const receipt = receipts[0];
  assert.equal(receipt.filename, archiveName);
  assert.equal(receipt.id, `${packageName}@1.0.0`);
  assert.equal(receipt.name, packageName);
  assert.equal(receipt.version, '1.0.0');
  assert.deepEqual(receipt.files.map(file => file.path).sort(), expectedFiles);
  const archive = join(staging, archiveName);
  assert.equal(receipt.integrity, 'sha512-' +
    createHash('sha512').update(readFileSync(archive)).digest('base64'));
  const listing = command('tar', ['-tzf', archive], { cwd: work }).stdout;
  writeFileSync(join(work, 'tar-list.txt'), listing);
  const tarFiles = listing.trim().split(/\r?\n/).filter(name => !name.endsWith('/')).sort();
  assert.deepEqual(tarFiles, expectedFiles.map(name => 'package/' + name).sort());
  copyFileSync(archive, join(consumer, 'fixture.tgz'));
  writeFileSync(join(consumer, 'package.json'), JSON.stringify({ name: 'isolated-consumer', private: true, type: 'module' }));
  npm(['install', './fixture.tgz', '--offline'], consumer);
  const installed = join(consumer, 'node_modules', packageName);
  assert.deepEqual(readdirSync(join(consumer, 'node_modules')).sort(), ['.package-lock.json', packageName]);
  const hiddenLock = join(consumer, 'node_modules/.package-lock.json');
  assert.ok(lstatSync(hiddenLock).isFile());
  assert.equal(realpathSync(hiddenLock), hiddenLock);
  assert.deepEqual(JSON.parse(readFileSync(hiddenLock, 'utf8')), {
    lockfileVersion: 3, requires: true,
    packages: { [`node_modules/${packageName}`]: {
      version: '1.0.0', resolved: 'file:fixture.tgz', integrity: receipt.integrity,
    } },
  });
  assert.equal(realpathSync(installed), installed);
  assert.deepEqual(fileTree(installed), expectedFiles);
  assert.deepEqual(JSON.parse(readFileSync(join(installed, 'package.json'), 'utf8')), metadata);
  for (const name of expectedFiles) {
    assert.deepEqual(readFileSync(join(installed, name)), readFileSync(join(staging, name)), name);
  }
  assert.ok(!relative(consumer, installed).startsWith('..'));
  const privateSpecifier = `${packageName}/dist/${privateJs}`;
  for (const mode of ['NodeNext', 'Bundler']) typecheck(mode, privateSpecifier);
  writeFileSync(join(consumer, 'host.mjs'), `import assert from 'node:assert/strict';
import * as root from '${packageName}';
import * as feature from '${packageName}/feature';
const item = new root.PackageItem(4);
assert.equal(root.PackageItem, feature.PackageItem);
assert.ok(item instanceof root.PackageItem);
assert.ok(item instanceof feature.PackageItem);
assert.ok(new feature.PackageItem(5) instanceof root.PackageItem);
assert.equal(item.value, 4);
assert.equal(item.add(3), 7);
assert.equal(root.increment(4), 5);
assert.equal(feature.featureValue(item), 6);
for (const name of ['Label', 'Envelope']) assert.ok(!Object.hasOwn(root, name));
await assert.rejects(import(${JSON.stringify(privateSpecifier)}), { code: 'ERR_PACKAGE_PATH_NOT_EXPORTED' });
console.log('packed root and feature ready');
`);
  const runtime = command(process.execPath, ['host.mjs']);
  assert.equal(runtime.stdout, 'packed root and feature ready\n');
  assert.equal(runtime.stderr, '');
  console.log(`packed ${archiveName}: ${expectedFiles.length} files; NodeNext, Bundler, Node bare imports`);
});
