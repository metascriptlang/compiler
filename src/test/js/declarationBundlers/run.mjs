import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { createRequire } from 'node:module';
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, realpathSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { loadOracle } from '../../compat/typescript/run.mjs';
import { buildCompilerGraph } from '../../../../tools/vite-plugin/compilerCore.js';
import { watchTestQueue } from '../../../../tools/vite-plugin/watchTestQueue.js';

const here = dirname(fileURLToPath(import.meta.url));
const repo = resolve(here, '../../../..');
const require = createRequire(new URL('../../../../tools/vite-plugin/package.json', import.meta.url));
const pins = { vite: '6.3.5', rollup: '4.44.1', webpack: '5.99.9' };

async function framework(name) {
  const file = process.env[`${name.toUpperCase()}_MODULE`] ?? require.resolve(name);
  const module = await import(pathToFileURL(realpathSync(file)).href);
  const version = module.version ?? module.VERSION ?? module.default?.version;
  assert.equal(version, pins[name], `${name} must be provisioned at the acceptance pin`);
  return module;
}

function fixture(t) {
  assert.ok(process.env.MSC, 'MSC must explicitly name the integrated real Linux candidate; no compiler fallback');
  const msc = realpathSync(resolve(process.env.MSC));
  const { ts, identity } = loadOracle(process.env.TS_ORACLE_MODULE);
  const parent = join(repo, 'out/declarationBundlers');
  mkdirSync(parent, { recursive: true });
  const work = realpathSync(mkdtempSync(join(parent, 'run-')));
  const src = join(work, 'src');
  mkdirSync(src);
  writeFileSync(join(work, 'package.json'), '{"type":"commonjs"}');
  writeFileSync(join(src, 'package.json'), '{"type":"module"}');
  for (const file of ['primary.ms', 'base.jms', 'label.ms', 'host.tsx']) {
    copyFileSync(join(here, 'fixtures', file), join(src, file));
  }
  writeFileSync(join(src, 'marker.ts'), "export const marker = 'original';\n");
  writeFileSync(join(src, 'aliasMarker.ts'), "export const marker = 'aliased';\n");
  const f = { work, src, msc, ts, identity, types: join(work, 'editor-types'),
    primary: join(src, 'primary.ms'), base: join(src, 'base.jms'), label: join(src, 'label.ms'),
    tsc: join(dirname(identity.path), 'tsc.js') };
  f.options = { msc, entry: [f.primary, f.base], outDir: join(work, 'compiler'),
    sourceDeclarations: { outDir: f.types, rootDir: src } };
  stageTypeConsumers(f);
  const receipt = { work, msc, node: process.version,
    compilerSha256: createHash('sha256').update(readFileSync(msc)).digest('hex'), oracle: identity };
  writeFileSync(join(work, 'identity.json'), JSON.stringify(receipt, null, 2));
  t.diagnostic(JSON.stringify(receipt));
  return f;
}

function command(f, args, expected = 0) {
  const result = spawnSync(process.execPath, args, { cwd: f.work, encoding: 'utf8', timeout: 20000 });
  assert.equal(result.error, undefined);
  assert.equal(result.status, expected, `${args.join(' ')}\n${result.stdout}${result.stderr}`);
  return result.stdout + result.stderr;
}

function stageTypeConsumers(f) {
  const text = readFileSync(join(f.src, 'host.tsx'), 'utf8');
  for (const extension of ['ts', 'tsx']) {
    writeFileSync(join(f.src, `consumer.${extension}`), extension === 'tsx' ? text : text.replace('<panel value={child.doubled()} />', 'makeElement("panel", { value: child.doubled() })'));
    writeFileSync(join(f.src, `negative.${extension}`), `import { Child, increment, readLabel, missing } from './primary.ms';
import { Base } from './base.jms';
increment('wrong');
new Child('wrong');
readLabel({ text: 1 });
new Base(1).secret;
new Child(1).absent;
const nominal: Base = { value: 1, add(value: number) { return value; } };
void [missing, nominal];
`);
  }
}

function typecheck(f, types = f.types, expectedHostError = false) {
  for (const mode of ['NodeNext', 'Bundler']) {
    const config = join(f.work, `${mode}.json`);
    const compilerOptions = { strict: true, skipLibCheck: false, noEmit: true,
      target: 'ES2022', module: mode === 'NodeNext' ? 'NodeNext' : 'ESNext',
      moduleResolution: mode, allowArbitraryExtensions: true, jsx: 'preserve',
      types: [], rootDirs: [f.src, types] };
    for (const extension of ['ts', 'tsx']) {
      const host = join(f.src, `consumer.${extension}`);
      writeFileSync(config, JSON.stringify({ compilerOptions, files: [host] }));
      const output = command(f, [f.tsc, '-p', config], expectedHostError ? 2 : 0);
      if (expectedHostError) {
        assert.match(output, /TS2345/);
        assert.match(output, /Property '"note"' is missing/);
      }
      writeFileSync(join(f.work, `${mode}-${extension}-positive.log`), output);
      const negative = join(f.src, `negative.${extension}`);
      writeFileSync(config, JSON.stringify({ compilerOptions, files: [negative] }));
      const errors = command(f, [f.tsc, '-p', config], 2);
      for (const code of ['TS2305', 'TS2345', 'TS2322', 'TS2341', 'TS2339', 'TS2739']) assert.ok(errors.includes(code), errors);
      assert.match(errors, /missing the following properties from type 'Base': #private, "secret"/);
      assert.ok(!errors.includes('TS2307'), errors);
      writeFileSync(join(f.work, `${mode}-${extension}-negative.log`), errors);
    }
  }
}

function files(root) {
  return readdirSync(root, { withFileTypes: true }).flatMap(item => {
    const path = join(root, item.name);
    return item.isDirectory() ? files(path) : [path];
  });
}

function sourceFamily(f) {
  assert.deepEqual(JSON.parse(readFileSync(join(f.types, 'package.json'))), { type: 'module' });
  for (const name of ['primary.d.ms.ts', 'base.d.jms.ts']) assert.ok(existsSync(join(f.types, name)), name);
  const declarations = files(f.types).filter(file => file.endsWith('.ts'));
  assert.ok(declarations.some(file => file.includes('/_types/')));
  for (const file of declarations) assert.doesNotMatch(readFileSync(file, 'utf8'), /\bany\b|declare module ["']\*/);
  assert.equal(readFileSync(join(f.work, 'package.json'), 'utf8'), '{"type":"commonjs"}');
  assert.equal(existsSync(join(f.src, 'primary.d.ms.ts')), false);
}

function noPackagedTypes(output) {
  for (const file of files(output)) assert.ok(!/\.d\.(?:ts|ms\.ts|jms\.ts)$/.test(file), file);
}

async function importOutput(file) {
  return import(pathToFileURL(file).href);
}

function runtime(api, base, delta = 1) {
  const child = new api.Child(4);
  assert.ok(child instanceof base.Base);
  assert.equal(child.add(api.increment(2)), 7 + delta);
  assert.equal(child.doubled(), 8);
  assert.equal(api.answer, 42);
  assert.equal(api.readLabel({ text: 'typed' }), 'typed');
  assert.equal('PublicTag' in api, false);
}

function hostRuntime(host, delta = 1) {
  assert.deepEqual({ ...host.snapshot }, { value: 7 + delta, doubled: 8, answer: 42,
    label: 'typed', nominal: true, typeOnlyAbsent: true, marker: 'aliased', define: 'user-config' });
  assert.deepEqual({ ...host.element }, { tag: 'panel', value: 8 });
}

function viteConfig(f, plugin) {
  return { root: f.src, configFile: false, logLevel: 'silent', plugins: [plugin],
    esbuild: { jsxFactory: 'makeElement', jsxFragment: 'Fragment' },
    define: { HOST_DEFINE: JSON.stringify('user-config') },
    resolve: { alias: { './marker.js': join(f.src, 'aliasMarker.ts') } } };
}

test('core: real compiler multi-root graph, strict source TS/TSX and Node ESM', { timeout: 60000 }, async t => {
  const f = fixture(t);
  const graph = buildCompilerGraph({ ...f.options, root: f.src, sourceRoot: f.src });
  assert.deepEqual(graph.entries, [f.primary, f.base]);
  assert.equal(graph.sourceDeclarationRoot, '_source_declarations');
  assert.ok(graph.dependencies.includes(f.label));
  const types = join(graph.outDir, graph.sourceDeclarationRoot);
  f.types = types;
  sourceFamily(f);
  typecheck(f);
  writeFileSync(join(graph.outDir, 'package.json'), '{"type":"module"}');
  await runtime(await importOutput(graph.bySource.get(f.primary)), await importOutput(graph.bySource.get(f.base)));
});

test('vite-build: native build executes typed TSX and preserves JSX, define and aliases', { timeout: 60000 }, async t => {
  const f = fixture(t);
  const vite = await framework('vite');
  const { default: metascript } = await import('../../../../tools/vite-plugin/index.js');
  const dist = join(f.work, 'dist');
  await vite.build({ ...viteConfig(f, metascript(f.options)), build: { outDir: dist,
    minify: false, lib: { entry: join(f.src, 'host.tsx'), formats: ['es'], fileName: () => 'host.mjs' } } });
  sourceFamily(f); typecheck(f); noPackagedTypes(dist);
  hostRuntime(await importOutput(join(dist, 'host.mjs')));
  assert.equal(existsSync(join(f.types, '.msc-source-lease')), false);
});

test('rollup-build: native MS/JMS entries generate ESM with the real type-root sink', { timeout: 60000 }, async t => {
  const f = fixture(t);
  const rollup = await framework('rollup');
  const { default: metascript } = await import('../../../../tools/vite-plugin/rollup.js');
  const bundle = await rollup.rollup({ input: { primary: f.primary, base: f.base }, plugins: [metascript({ ...f.options, root: f.src })] });
  t.after(() => bundle.close());
  const dist = join(f.work, 'dist');
  const { output } = await bundle.write({ dir: dist, format: 'es', entryFileNames: '[name].mjs', chunkFileNames: '[name]-[hash].mjs' });
  assert.ok(output.every(item => item.type === 'chunk'));
  sourceFamily(f); typecheck(f); noPackagedTypes(dist);
  runtime(await importOutput(join(dist, 'primary.mjs')), await importOutput(join(dist, 'base.mjs')));
});

async function webpackCompiler(f) {
  const module = await framework('webpack');
  const webpack = module.default;
  const { default: MetaScriptPlugin, loader } = await import('../../../../tools/vite-plugin/webpack.js');
  const transpiled = f.ts.transpileModule(readFileSync(join(f.src, 'host.tsx'), 'utf8'), {
    fileName: 'host.tsx', compilerOptions: { target: f.ts.ScriptTarget.ES2022,
      module: f.ts.ModuleKind.ESNext, jsx: f.ts.JsxEmit.React, jsxFactory: 'makeElement' } });
  writeFileSync(join(f.src, 'host.js'), transpiled.outputText);
  return webpack({ mode: 'development', context: f.src, entry: join(f.src, 'host.js'),
    target: 'node18', devtool: false, parallelism: 1, experiments: { outputModule: true },
    output: { path: join(f.work, 'dist'), filename: '[name].[contenthash].mjs',
      chunkFilename: '[name].[contenthash].mjs', module: true, library: { type: 'module' } },
    resolve: { alias: { './marker.js$': join(f.src, 'aliasMarker.ts') }, extensions: ['.js', '.ts'] },
    module: { rules: [{ test: /\.(ms|jms)$/, type: 'javascript/auto', use: [{ loader }] }] },
    plugins: [new MetaScriptPlugin(f.options), new webpack.DefinePlugin({ HOST_DEFINE: JSON.stringify('user-config') })] });
}

function webpackResult(error, stats) {
  if (error) throw error;
  assert.ok(stats, 'webpack must return stats');
  return stats;
}

async function webpackRuntime(f, stats, delta = 1) {
  assert.equal(stats.hasErrors(), false, stats.toString({ all: false, errors: true }));
  const entry = stats.toJson({ all: false, entrypoints: true }).entrypoints.main.assets.find(file => file.name.endsWith('.mjs'));
  hostRuntime(await importOutput(join(f.work, 'dist', entry.name)), delta);
  noPackagedTypes(join(f.work, 'dist'));
}

function closeWebpack(compiler) {
  return new Promise((resolve, reject) => compiler.close(error => error ? reject(error) : resolve()));
}

test('webpack-build: native ESM library executes transpiled TSX after separate strict tsc', { timeout: 60000 }, async t => {
  const f = fixture(t);
  const compiler = await webpackCompiler(f);
  t.after(() => closeWebpack(compiler));
  const stats = await new Promise((resolve, reject) => compiler.run((error, stats) => {
    try { resolve(webpackResult(error, stats)); } catch (error) { reject(error); }
  }));
  sourceFamily(f); typecheck(f);
  await webpackRuntime(f, stats);
});

function original(f, name) { return readFileSync(join(here, 'fixtures', name), 'utf8'); }
function editRuntime(f) { writeFileSync(f.primary, original(f, 'primary.ms').replace('value + 1', 'value + 2')); }
function editType(f) { writeFileSync(f.label, 'export interface Label { text: string; note: string; }\n'); }
function failSource(f) { writeFileSync(f.label, 'export interface Label { text: ; }\n'); }
function restoreType(f) { writeFileSync(f.label, original(f, 'label.ms')); }
function absentTypes(f) { assert.equal(existsSync(join(f.types, 'primary.d.ms.ts')), false); }

async function establishedEdits(f, success, failure, trace = () => {}) {
  trace('edit-runtime'); editRuntime(f); await success(2);
  trace('edit-type'); editType(f); await success(2);
  assert.ok(files(f.types).some(file => file.endsWith('.ts') && /note/.test(readFileSync(file, 'utf8'))));
  trace('typecheck-required-note'); typecheck(f, f.types, true);
  trace('edit-invalid'); failSource(f); await failure(); absentTypes(f);
  trace('restore-after-error'); restoreType(f); await success(2); sourceFamily(f);
  trace('delete-type'); rmSync(f.label); await failure(); absentTypes(f);
  trace('restore-after-delete'); restoreType(f); await success(2);
  trace('typecheck-restored'); typecheck(f);
}

test('rollup-watch-established: real edits, type changes, errors, delete and restore after BUNDLE_END', { timeout: 60000 }, async t => {
  const f = fixture(t);
  const rollup = await framework('rollup');
  const { default: metascript } = await import('../../../../tools/vite-plugin/rollup.js');
  const queue = watchTestQueue();
  const watcher = rollup.watch({ input: { primary: f.primary, base: f.base },
    plugins: [metascript({ ...f.options, root: f.src })],
    output: { dir: join(f.work, 'watch-output'), format: 'es' }, watch: { skipWrite: true } });
  watcher.on('change', (id, change) => t.diagnostic(JSON.stringify({ rollupChange: id, ...change })));
  watcher.on('event', event => {
    t.diagnostic(JSON.stringify({ rollupEvent: event.code, error: event.error?.message }));
    if (event.code === 'ERROR' || event.code === 'BUNDLE_END') queue.push(event);
  });
  t.after(() => watcher.close());
  let generation = 0;
  const success = async delta => {
    const event = await queue.next();
    assert.equal(event.code, 'BUNDLE_END', event.error?.message);
    try {
      const dist = join(f.work, `generation-${generation++}`);
      const { output } = await event.result.write({ dir: dist, format: 'es', entryFileNames: '[name].mjs', chunkFileNames: '[name]-[hash].mjs' });
      assert.ok(output.every(item => item.type === 'chunk'));
      runtime(await importOutput(join(dist, 'primary.mjs')), await importOutput(join(dist, 'base.mjs')), delta);
    } finally { await event.result.close(); }
  };
  await success(1); sourceFamily(f);
  await establishedEdits(f, success, async () => assert.equal((await queue.next()).code, 'ERROR'));
  await watcher.close();
  assert.equal(existsSync(join(f.types, '.msc-source-lease')), false);
});

test('webpack-watch-established: native watch generations execute and invalidate source types', { timeout: 60000 }, async t => {
  const f = fixture(t);
  const compiler = await webpackCompiler(f);
  const queue = watchTestQueue();
  let phase = 'initial', generation = 0, compilationInput;
  const trace = (event, details = {}) => {
    const record = { webpackWatch: event, phase, generation, ...details };
    t.diagnostic(JSON.stringify(record));
    writeFileSync(join(f.work, 'webpack-watch-trace.jsonl'), `${JSON.stringify(record)}\n`, { flag: 'a' });
  };
  compiler.hooks.invalid.tap('AcceptanceWatchTrace', (file, time) => trace('invalid', { file, time }));
  compiler.hooks.watchRun.tap('AcceptanceWatchTrace', current => {
    const modified = [...(current.modifiedFiles ?? [])], removed = [...(current.removedFiles ?? [])];
    compilationInput = { phase, files: new Set([...modified, ...removed]) };
    trace('watchRun', { modified, removed });
  });
  compiler.hooks.done.tap('AcceptanceWatchTrace', stats => trace('done', { errors: stats.hasErrors() }));
  compiler.hooks.afterDone.tap('AcceptanceWatchTrace', () => trace('afterDone'));
  compiler.hooks.failed.tap('AcceptanceWatchTrace', error => trace('failed', { error: error.message }));
  compiler.hooks.watchClose.tap('AcceptanceWatchTrace', () => trace('watchClose'));
  const nativeWatch = compiler.watchFileSystem.watch;
  compiler.watchFileSystem.watch = function(files, directories, missing, startTime, options, callback, undelayed) {
    trace('watch-call', { files: [...files], directories: [...directories], missing: [...missing], startTime });
    return nativeWatch.call(this, files, directories, missing, startTime, options, (...args) => {
      const [error, , , changed, removed] = args;
      trace('aggregate', { error: error?.message, changed: [...(changed ?? [])], removed: [...(removed ?? [])] });
      return callback(...args);
    }, (file, time) => {
      trace('undelayed', { file, time });
      return undelayed?.(file, time);
    });
  };
  const watching = compiler.watch({ aggregateTimeout: 10 }, (error, stats) => {
    generation++;
    trace('callback', { error: error?.message, errors: stats?.hasErrors() });
    queue.push({ error, stats, input: compilationInput });
  });
  let closing;
  const stop = () => closing ??= new Promise((resolve, reject) => watching.close(error => error ? reject(error) : resolve()));
  t.after(async () => { await stop(); await closeWebpack(compiler); });
  const next = async () => {
    const expectedFile = phase === 'initial' ? undefined : phase === 'edit-runtime' ? f.primary : f.label;
    while (true) {
      trace('await-callback');
      const { error, stats, input } = await queue.next();
      const result = webpackResult(error, stats);
      assert.ok(input, 'watch callback must identify its compilation inputs');
      trace('consume-callback', { inputPhase: input.phase, inputFiles: [...input.files] });
      if (input.phase === phase && (!expectedFile || input.files.has(expectedFile))) return result;
      trace('unrelated-callback', { expectedFile });
    }
  };
  const success = async delta => {
    await webpackRuntime(f, await next(), delta);
    trace('runtime-verified', { delta });
  };
  await success(1); sourceFamily(f);
  const hostFile = join(f.src, 'host.js');
  const hostRebuilt = new Promise(resolve => compiler.hooks.afterDone.tap('AcceptanceHostRebuild', stats => {
    if (compiler.modifiedFiles?.has(hostFile)) resolve(stats);
  }));
  writeFileSync(hostFile, `${readFileSync(hostFile, 'utf8')}\n`);
  await webpackRuntime(f, await hostRebuilt);
  assert.ok(queue.pending > 0, 'an unrelated native build must be queued before the MS edit');
  await establishedEdits(f, success, async () => assert.equal((await next()).hasErrors(), true), nextPhase => {
    phase = nextPhase; trace('phase');
  });
  phase = 'close'; trace('phase');
  await stop();
  assert.equal(existsSync(join(f.types, '.msc-source-lease')), false);
});

test('vite-dev: in-process SSR plus native HMR protocol, not browser E2E', { timeout: 60000 }, async t => {
  const f = fixture(t);
  assert.ok(Number(process.versions.node.split('.')[0]) >= 24, 'acceptance tooling requires Node 24+');
  assert.equal(typeof WebSocket, 'function', 'acceptance tooling requires built-in Node WebSocket');
  const vite = await framework('vite');
  const { default: metascript } = await import('../../../../tools/vite-plugin/index.js');
  const typePublications = watchTestQueue();
  let awaitingTypePublication = false;
  const typeObserver = { name: 'acceptance-source-type-publication', enforce: 'post',
    handleHotUpdate(context) {
      if (awaitingTypePublication && context.file === f.label) typePublications.push(context.file);
    } };
  const config = viteConfig(f, metascript(f.options));
  const server = await vite.createServer({ ...config, plugins: [...config.plugins, typeObserver],
    server: { host: '127.0.0.1', port: 0, watch: { usePolling: false } } });
  t.after(() => server.close());
  await server.listen();
  const address = server.httpServer.address();
  assert.ok(address && typeof address !== 'string');
  const origin = `http://127.0.0.1:${address.port}`;
  const response = await fetch(`${origin}/@vite/client`);
  assert.equal(response.status, 200);
  const client = await response.text();
  const token = /const wsToken = ("[^"\n]+");/.exec(client);
  assert.ok(token, 'pinned served Vite client must expose its normal WebSocket token');
  const socket = new WebSocket(`${origin.replace('http:', 'ws:')}/?token=${encodeURIComponent(JSON.parse(token[1]))}`, 'vite-hmr');
  const queue = watchTestQueue();
  socket.addEventListener('message', event => {
    const message = JSON.parse(event.data);
    if (['connected', 'update', 'full-reload', 'error'].includes(message.type)) queue.push(message);
  });
  socket.addEventListener('error', event => queue.push({ type: 'transport-error', message: event.message }));
  t.after(() => socket.close());
  assert.equal((await queue.next()).type, 'connected');
  for (const file of ['host.tsx', 'primary.ms', 'base.jms']) {
    assert.equal((await fetch(`${origin}/${file}`)).status, 200);
  }
  hostRuntime(await server.ssrLoadModule('/host.tsx'));
  sourceFamily(f); typecheck(f);
  await assert.rejects(vite.build({ ...viteConfig(f, metascript(f.options)),
    build: { outDir: join(f.work, 'competing-dist'), lib: { entry: join(f.src, 'host.tsx'), formats: ['es'] } } }), /lease.*held|exclusive.*lease/i);
  const updated = async () => {
    const message = await queue.next();
    assert.ok(['update', 'full-reload'].includes(message.type), JSON.stringify(message));
    hostRuntime(await server.ssrLoadModule('/host.tsx'), 2);
  };
  editRuntime(f); await updated();
  awaitingTypePublication = true;
  editType(f);
  assert.equal(await typePublications.next(), f.label);
  awaitingTypePublication = false;
  assert.ok(files(f.types).some(file => file.endsWith('.ts') && /note/.test(readFileSync(file, 'utf8'))));
  typecheck(f, f.types, true);
  failSource(f);
  assert.equal((await queue.next()).type, 'error');
  absentTypes(f);
  restoreType(f); await updated();
  rmSync(f.label);
  assert.equal((await queue.next()).type, 'error');
  absentTypes(f);
  restoreType(f); await updated();
  typecheck(f);
  socket.close();
  await server.close();
  assert.equal(existsSync(join(f.types, '.msc-source-lease')), false);
});
