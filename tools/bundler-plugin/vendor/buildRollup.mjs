import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { execFileSync, spawnSync } from 'node:child_process';
import { createRequire } from 'node:module';
import { copyFileSync, existsSync, lstatSync, mkdirSync, readFileSync, readdirSync, readlinkSync, writeFileSync } from 'node:fs';
import { dirname, isAbsolute, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { gzipSync } from 'node:zlib';

const vendor = dirname(fileURLToPath(import.meta.url));
const pin = JSON.parse(readFileSync(join(vendor, 'rollup4.json')));
const digest = (bytes, algorithm = 'sha256', encoding = 'hex') => createHash(algorithm).update(bytes).digest(encoding);
const hash = file => digest(readFileSync(file));
const info = file => ({ sha256: hash(file), bytes: lstatSync(file).size, mode: lstatSync(file).mode & 0o7777 });
const json = (file, value) => writeFileSync(file, JSON.stringify(value, null, 2) + '\n');
function tree(root, exclude = new Set()) {
 const out = {};
 function visit(dir, prefix) {
  for (const name of readdirSync(dir).sort()) {
   const relative = prefix + name;
   if (exclude.has(relative)) continue;
   const file = join(dir, name), stat = lstatSync(file);
   out[relative] = stat.isSymbolicLink() ? { type: 'symlink', target: readlinkSync(file), mode: stat.mode & 0o7777 }
    : stat.isDirectory() ? { type: 'directory', mode: stat.mode & 0o7777 } : { type: 'file', ...info(file) };
   if (stat.isDirectory()) visit(file, relative + '/');
  }
 }
 visit(root, '');
 return out;
}
const delta = (before, after) => Object.fromEntries([...new Set([...Object.keys(before), ...Object.keys(after)])].sort()
 .filter(k => JSON.stringify(before[k]) !== JSON.stringify(after[k])).map(k => [k, { before: before[k], after: after[k] }]));

export function packageTar(root, files) {
 const blocks = [];
 for (const name of files.sort()) {
  assert.ok(!name.startsWith('/') && !name.split('/').includes('..'));
  const path = 'package/' + name, bytes = readFileSync(join(root, name));
  assert.ok(Buffer.byteLength(path) < 100);
  const header = Buffer.alloc(512);
  const text = (offset, size, value) => header.write(value, offset, size, 'ascii');
  const octal = (offset, size, value) => text(offset, size, value.toString(8).padStart(size - 1, '0') + '\0');
  text(0, 100, path); octal(100, 8, name === 'dist/bin/rollup' ? 0o755 : 0o644);
  octal(108, 8, 0); octal(116, 8, 0); octal(124, 12, bytes.length); octal(136, 12, 0);
  header.fill(32, 148, 156); text(156, 1, '0'); text(257, 6, 'ustar\0'); text(263, 2, '00');
  const checksum = header.reduce((a, b) => a + b, 0);
  text(148, 8, checksum.toString(8).padStart(6, '0') + '\0 ');
  blocks.push(header, bytes, Buffer.alloc((512 - bytes.length % 512) % 512));
 }
 blocks.push(Buffer.alloc(1024));
 return gzipSync(Buffer.concat(blocks), { level: 9, mtime: 0 });
}

async function main() {
 const [workArg, outputArg] = process.argv.slice(2);
 assert.ok(workArg && isAbsolute(workArg), 'usage: node buildRollup.mjs /fresh/absolute/work [/output/rollup4.tgz]');
 const [major, minor] = process.versions.node.split('.').map(Number);
 assert.ok(major > 24 || major === 24 && minor >= 12, 'build requires Node >=24.12.0; runtime floor is separate');
 assert.ok(!existsSync(workArg), 'work directory must be fresh');
 const work = resolve(workArg); mkdirSync(work, { recursive: true });
 const evidence = join(work, 'evidence'); mkdirSync(evidence);
 const steps = [], env = { ...process.env, PATH: dirname(process.execPath) + ':' + process.env.PATH, SOURCE_DATE_EPOCH: '0', NODE_OPTIONS: '' };
 function run(name, args, cwd) {
  const row = { name, args, cwd, startMs: Date.now() }; steps.push(row); json(join(evidence, 'steps.json'), steps);
  try {
   const result = spawnSync(args[0], args.slice(1), { cwd, env, encoding: 'utf8', maxBuffer: 32 * 1024 * 1024 });
   row.rc = result.status; row.signal = result.signal;
   writeFileSync(join(evidence, name + '.stdout'), result.stdout ?? '');
   writeFileSync(join(evidence, name + '.stderr'), result.stderr ?? String(result.error ?? ''));
   assert.equal(result.error, undefined); assert.equal(result.status, 0, name); assert.equal(result.signal, null);
   return result.stdout;
  } finally { row.seconds = (Date.now() - row.startMs) / 1000; json(join(evidence, 'steps.json'), steps); }
 }
 const npm = resolve(dirname(process.execPath), '../lib/node_modules/npm/bin/npm-cli.js');
 assert.ok(existsSync(npm), 'use an official Node distribution with npm');
 json(join(evidence, 'toolchain.json'), { node: process.version, executable: process.execPath, nodeIdentity: info(process.execPath), npm: info(npm) });
 for (const [name, expected] of Object.entries(pin.patches)) assert.equal(hash(join(vendor, name)), expected, name);
 async function download(name, spec) {
  const response = await fetch(spec.url); assert.equal(response.status, 200, spec.url);
  const bytes = Buffer.from(await response.arrayBuffer());
  assert.equal(digest(bytes), spec.sha256);
  assert.equal('sha512-' + digest(bytes, 'sha512', 'base64'), spec.integrity);
  const file = join(work, name); writeFileSync(file, bytes); return file;
 }
 const sourceTar = await download('source.tgz', pin.source), publishedTar = await download('published.tgz', pin.published);
 const unpack = join(work, 'source');
 run('extract-source', ['python3', join(vendor, 'extractRollup.py'), sourceTar, unpack, join(evidence, 'source.extraction.json'), '--allow-links']);
 const stage = join(unpack, 'rollup-' + pin.baseGit);
 assert.ok(!existsSync(join(stage, '.git')));
 let enclosingGit = false;
 try { execFileSync('git', ['rev-parse', 'HEAD'], { cwd: stage, stdio: 'ignore' }); enclosingGit = true; } catch {}
 assert.equal(enclosingGit, false, 'build work must be outside any Git tree (banner must remain honest)');
 assert.equal(hash(join(stage, 'package-lock.json')), pin.lockSHA256);
 const original = tree(stage); json(join(evidence, 'source.original.json'), original);
 assert.equal(JSON.parse(readFileSync(join(stage, 'package.json'))).version, pin.baseVersion);
 const semver = createRequire(npm)('semver');
 const engines = Object.entries(JSON.parse(readFileSync(join(stage, 'package-lock.json'))).packages).filter(([, p]) => !p.optional).flatMap(([name, p]) => {
  let engine = p.engines;
  if (Array.isArray(engine)) engine = { node: engine.find(s => s.startsWith('node '))?.slice(5) };
  return engine?.node ? [{ name, engine: engine.node, ok: semver.satisfies(process.version, engine.node) }] : [];
 });
 json(join(evidence, 'locked-engines.json'), engines);
 assert.ok(engines.length > 0 && engines.every(e => e.ok), 'locked dependency engine mismatch');
 run('npm-ci', [process.execPath, npm, 'ci', '--ignore-scripts', '--no-audit', '--no-fund'], stage);
 assert.equal(hash(join(stage, 'package-lock.json')), pin.lockSHA256);
 const beforePatch = tree(stage); json(join(evidence, 'installed.baseline.json'), beforePatch);
 run('bootstrap-identity', [process.execPath, '--input-type=module', '-e', `
  import assert from 'node:assert/strict';
  import {createRequire} from 'node:module';
  import {readFileSync,realpathSync} from 'node:fs';
  import {createHash} from 'node:crypto';
  import {dirname,join} from 'node:path';
  const require=createRequire(${JSON.stringify(join(stage, 'package.json'))});
  const rollup=require(${JSON.stringify(join(stage, 'node_modules/rollup/dist/rollup.js'))}),meta=JSON.parse(readFileSync(${JSON.stringify(join(stage, 'node_modules/rollup/package.json'))}));
  const binaries=process.report.getReport().sharedObjects.filter(p=>p.endsWith('.node')).map(p=>({path:realpathSync(p),sha256:createHash('sha256').update(readFileSync(p)).digest('hex'),owner:JSON.parse(readFileSync(join(dirname(p),'package.json')))}));
  assert.equal(rollup.VERSION,'4.65.1');assert.equal(meta.version,'4.65.1');assert.equal(binaries.length,1);assert.equal(binaries[0].owner.version,'4.65.1');
  console.log(JSON.stringify({VERSION:rollup.VERSION,packageVersion:meta.version,binaries}));
 `], stage);
 const names = Object.keys(pin.canonicalSources);
 for (const phase of ['before', 'after']) {
  if (phase === 'after') {
   copyFileSync(join(vendor, 'chokidar.patch'), join(stage, 'patches/chokidar+3.6.0.patch'));
   run('check-chokidar', ['git', 'apply', '--check', join(vendor, 'chokidar.patch')], stage);
   run('prepare-patch', [process.execPath, npm, 'run', 'prepare:patch'], stage);
   run('check-rollup', ['git', 'apply', '--check', join(vendor, 'rollup4.patch')], stage);
   run('apply-rollup', ['git', 'apply', join(vendor, 'rollup4.patch')], stage);
  }
  for (const name of names) {
   const dest = join(evidence, 'sources', phase, name); mkdirSync(dirname(dest), { recursive: true });
   copyFileSync(join(stage, name), dest);
   if (phase === 'after') {
    assert.equal(hash(dest), pin.canonicalSources[name].sha256, name);
    assert.equal(lstatSync(dest).size, pin.canonicalSources[name].bytes, name);
   }
  }
 }
 assert.equal(readFileSync(join(stage, 'node_modules/chokidar/lib/nodefs-handler.js'), 'utf8').split("this.fsw._throttle('readdir', directory, 1000)").length, 2);
 const patched = tree(stage); json(join(evidence, 'patch.delta.json'), delta(beforePatch, patched));
 const preparedSource = tree(stage, new Set(['node_modules']));
 const intentional = delta(original, preparedSource);
 assert.deepEqual(Object.keys(intentional).sort(), ['package.json', 'patches/chokidar+3.6.0.patch', ...names.filter(n => !n.startsWith('node_modules/'))].sort());
 run('typecheck', [process.execPath, join(stage, 'node_modules/.bin/tsc'), '--noEmit', '-p', '.'], stage);
 assert.deepEqual(delta(patched, tree(stage)), {});
 run('build-js-node', [process.execPath, npm, 'run', 'build:js:node'], stage);
 const buildDelta = delta(patched, tree(stage)); json(join(evidence, 'build.delta.json'), buildDelta);
 assert.ok(Object.keys(buildDelta).every(n => n === 'LICENSE.md' || n === 'dist' || n.startsWith('dist/')));
 assert.equal(hash(join(stage, 'package-lock.json')), pin.lockSHA256);
 run('extract-published', ['python3', join(vendor, 'extractRollup.py'), publishedTar, join(work, 'published'), join(evidence, 'published.extraction.json')]);
 const pkg = join(work, 'published/package'), contract = tree(pkg);
 const runtime = Object.keys(contract).filter(n => contract[n].type === 'file' && n.startsWith('dist/'));
 assert.equal(runtime.length, 25);
 for (const name of runtime) { assert.ok(existsSync(join(stage, name)), name); copyFileSync(join(stage, name), join(pkg, name)); }
 copyFileSync(join(stage, 'LICENSE.md'), join(pkg, 'LICENSE.md'));
 const meta = JSON.parse(readFileSync(join(pkg, 'package.json'))), originalMeta = structuredClone(meta);
 meta.version = pin.version;
 assert.ok(Object.entries(meta.optionalDependencies).filter(([n]) => n.startsWith('@rollup/')).every(([, v]) => v === pin.nativeABI));
 json(join(pkg, 'package.json'), meta);
 assert.deepEqual({ ...meta, version: originalMeta.version }, originalMeta);
 const files = Object.keys(contract).filter(n => contract[n].type === 'file');
 assert.deepEqual(Object.keys(tree(pkg)).sort(), Object.keys(contract).sort());
 const archive = packageTar(pkg, files), output = resolve(outputArg ?? join(work, 'rollup4.tgz'));
 if (pin.artifactSHA256) assert.equal(digest(archive), pin.artifactSHA256, 'rebuild differs from pinned artifact');
 writeFileSync(output, archive);
 json(join(evidence, 'delivery.json'), { version: pin.version, nativeABI: pin.nativeABI, baseGit: pin.baseGit, artifact: info(output), package: tree(pkg), publishedRuntimeFiles: runtime, buildOnlyMaps: Object.keys(tree(join(stage, 'dist'))).filter(n => n.endsWith('.map')), reproducibleTarFraming: digest(packageTar(pkg, files)) === digest(archive), banner: pin.banner });
 console.log(JSON.stringify({ output, sha256: digest(archive), version: meta.version, nativeABI: pin.nativeABI }));
}
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) await main();
