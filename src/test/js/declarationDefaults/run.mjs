import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync, copyFileSync, existsSync, realpathSync } from 'node:fs';
import { dirname, resolve, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { loadOracle } from '../../compat/typescript/run.mjs';
const here = dirname(fileURLToPath(import.meta.url));
const repo = resolve(here, '../../../..');
const msc = resolve(process.env.MSC ?? join(repo, 'msc'));
mkdirSync(join(repo, 'out/declarationDefaults'), { recursive: true });
const work = mkdtempSync(join(repo, 'out/declarationDefaults/run-'));
const src = join(work, 'src'); mkdirSync(src);
for (const name of ['api.ms', 'model.jms']) copyFileSync(join(here, name), join(src, name));
writeFileSync(join(src, 'package.json'), '{"type":"module"}');
function command(binary, args, expected = 0) {
  const result = spawnSync(binary, args, { cwd: repo, encoding: 'utf8', timeout: 60000 });
  assert.equal(result.error, undefined);
  assert.equal(result.status, expected, `${binary} ${args.join(' ')}\n${result.stdout}${result.stderr}`);
  return result.stdout + result.stderr;
}
const oracle = join(repo, 'out/compat/typescript/oracle/lib/typescript.js');
if (!existsSync(oracle)) command(process.execPath, [join(repo, 'src/test/compat/typescript/run.mjs'), 'fetch']);
const { identity } = loadOracle(oracle);
console.log(`oracle ${JSON.stringify(identity)}`);
const tsc = join(dirname(identity.path), 'tsc.js');
function typecheck(root, api, model, sourceFamily) {
  const imports = `import { increment, type Pair, type Box, type Cell } from '${api}';
${model ? `import type { Label, Record } from '${model}';` : ''}`;
  const positive = `${imports}
const pair: Pair = ['text', ['text'], ['text', ['text']]];
const box: Box = { value: 'text', values: ['text'] };
const cell: Cell = { value: 7 };
const explicit: Pair<'ok'> = ['ok', ['ok'], ['ok', ['ok']]];
const required: number = increment(4);
${model ? "const label: Label = ['typed']; const record: Record = { value: 'typed' }; void [label, record];" : ''}
void [pair, box, cell, explicit, required];
`;
  const negative = `${imports}
const pair: Pair = [1, [], ['x', []]];
const box: Box = { value: 1, values: ['text'] };
const cell: Cell = { value: 'bad' };
const constraint: Pair<number> = [1, [], [1, []]];
increment();
${model ? 'const label: Label = [1]; const record: Record = { value: 1 };' : ''}
`;
  for (const mode of ['NodeNext', 'Bundler']) {
    const options = { strict: true, skipLibCheck: false, noEmit: true, target: 'ES2022',
      module: mode === 'NodeNext' ? 'NodeNext' : 'ESNext', moduleResolution: mode,
      ...(sourceFamily ? { allowArbitraryExtensions: true, rootDirs: [src, join(root, '_source_declarations')] } : {}) };
    const consumer = sourceFamily ? join(src, 'consumer.mts') : join(root, 'consumer.mts');
    const config = join(root, `${mode}.json`);
    writeFileSync(config, JSON.stringify({ compilerOptions: options, files: [consumer] }));
    writeFileSync(consumer, positive);
    command(process.execPath, [tsc, '-p', config]);
    writeFileSync(consumer, negative);
    const errors = command(process.execPath, [tsc, '-p', config], 2);
    for (const code of ['TS2322', 'TS2344', 'TS2554']) assert.ok(errors.includes(code), errors);
    writeFileSync(join(root, `${mode}-negative.log`), errors);
  }
}
test('checked type defaults support strict TS omitted type arguments without runtime generics', async () => {
  const root = join(work, 'bundle'); mkdirSync(root);
  const target = join(root, 'api.mjs');
  command(msc, ['build', join(src, 'api.ms'), '--target=js', '--declaration', `--output=${target}`]);
  const text = readFileSync(join(root, 'api.d.mts'), 'utf8');
  assert.match(text, /T extends string = string, U = Array<T>, V = \[T, U\]/);
  typecheck(root, './api.mjs', '', false);
  const api = await import(pathToFileURL(target));
  assert.equal(api.increment(4), 5);
  assert.deepEqual(Object.keys(api), ['increment']);
});
test('direct MS and JMS source families reuse checked default projection', async () => {
  const root = join(work, 'source');
  command(msc, ['build', join(src, 'api.ms'), '--target=js', '--split', '--declaration',
    `--js-entry=${join(src, 'model.jms')}`, `--declaration-source-root=${src}`, `--output=${root}`]);
  const tree = JSON.parse(readFileSync(join(root, '_manifest.json')));
  for (const name of ['api.ms', 'model.jms']) {
    const file = tree.sourceDeclarations.find(file => file.source === realpathSync(join(src, name)));
    assert.ok(file);
    assert.match(readFileSync(join(root, file.out), 'utf8'), /T.* = string/);
  }
  typecheck(root, './api.ms', './model.jms', true);
  writeFileSync(join(root, 'package.json'), '{"type":"module"}');
  const file = tree.modules.find(file => file.source === realpathSync(join(src, 'api.ms')));
  const api = await import(pathToFileURL(join(root, file.out)));
  assert.equal(api.increment(8), 9);
  assert.deepEqual(Object.keys(api), ['increment']);
});
test('unsafe raw free-function APIs fail only in declaration mode', () => {
  const entry = join(here, '../declarationCli/defaultParameter.ms');
  const root = join(work, 'refused'); mkdirSync(root);
  const target = join(root, 'raw.mjs');
  command(msc, ['build', entry, '--target=js', `--output=${target}`]);
  const before = readFileSync(target, 'utf8');
  const errors = command(msc, ['build', entry, '--target=js', '--declaration', `--output=${target}`], 1);
  assert.match(errors, /readDefault.*value.*omitted-argument ABI.*pending host adaptation/);
  assert.equal(readFileSync(target, 'utf8'), before);
  assert.ok(!existsSync(join(root, 'raw.d.mts')));
});
