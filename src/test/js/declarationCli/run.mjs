import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdirSync, readFileSync, writeFileSync, existsSync, realpathSync } from 'node:fs';
import { dirname, resolve, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { loadOracle } from '../../compat/typescript/run.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const repo = resolve(here, '../../../..');
const out = resolve(repo, 'out/declarationCli');
const msc = resolve(process.env.MSC ?? join(repo, 'msc'));
const source = name => realpathSync(join(here, name));
mkdirSync(out, { recursive: true });
function command(binary, args, expected = 0) {
  const result = spawnSync(binary, args, { cwd: repo, encoding: 'utf8', timeout: 60000 });
  assert.equal(result.error, undefined);
  assert.equal(result.status, expected, `${binary} ${args.join(' ')}\n${result.stdout}${result.stderr}`);
  return result.stdout + result.stderr;
}
function build(entry, target, args = []) {
  return command(msc, ['build', source(entry), '--target=js', '--declaration', `--output=${target}`, ...args]);
}
if (process.env.DECLARATION_BASELINE) {
  const text = command(process.env.DECLARATION_BASELINE,
    ['build', source('empty.ms'), '--target=js', '--declaration'], 1);
  assert.match(text, /unknown option '--declaration'/);
  console.log('old-red: --declaration is unknown');
} else {
  const { identity } = loadOracle(join(repo, 'out/compat/typescript/oracle/lib/typescript.js'));
  console.log(`oracle ${JSON.stringify(identity)}`);
  const tsc = join(dirname(identity.path), 'tsc.js');
  function typecheck(root, specifier) {
    writeFileSync(join(root, 'consumer.mts'), `import value, { greeting, later, read, Color, type Options } from ${JSON.stringify(specifier)};
const options: Options = { label: { text: 'typed' } };
const text: string = read(options);
const greetingText: string = greeting();
const future: Promise<string> = later();
const color: Color = Color.Blue;
const defaultValue: number = value;
void [text, greetingText, future, color, defaultValue];
`);
    const flags = ['--strict', '--noEmit', '--target', 'ES2022', '--module', 'NodeNext', '--moduleResolution', 'NodeNext'];
    command(process.execPath, [tsc, ...flags, join(root, 'consumer.mts')]);
    writeFileSync(join(root, 'negative.mts'), `import { greeting, read, type Options } from ${JSON.stringify(specifier)};
const bad: number = greeting();
read({ label: { text: 42 } });
const absent: Options = {};
`);
    const errors = command(process.execPath, [tsc, ...flags, join(root, 'negative.mts')], 2);
    assert.match(errors, /TS2322/);
    assert.match(errors, /TS2741/);
    writeFileSync(join(root, 'negative.log'), errors);
  }
  async function runtime(path) {
    const api = await import(pathToFileURL(path));
    assert.equal(api.greeting(), 'hello');
    assert.equal(await api.later(), 'later');
    assert.equal(api.Color.Blue, 1);
    assert.equal(api.default, 7);
  }
  test('split declarations preserve layout, closure, dependencies and strict TS/Node API', async () => {
    const root = join(out, 'split');
    build('api.ms', root, ['--split']);
    writeFileSync(join(root, 'package.json'), '{"type":"module"}');
    const manifest = JSON.parse(readFileSync(join(root, '_manifest.json')));
    assert.equal(manifest.entry, source('api.ms'));
    assert.ok(Array.isArray(manifest.modules));
    assert.ok(Array.isArray(manifest.instances));
    assert.ok(manifest.dependencies.includes(source('api.ms')));
    assert.ok(manifest.dependencies.includes(source('types.ms')));
    for (const input of manifest.dependencies) assert.ok(existsSync(input));
    const entry = manifest.declarations.find(file => file.source === source('api.ms'));
    const helper = manifest.declarations.find(file => file.source === source('types.ms'));
    assert.ok(entry && helper);
    assert.ok(!readFileSync(join(root, helper.out), 'utf8').includes('unrelated'));
    const js = manifest.modules.find(file => file.source === source('api.ms')).out;
    assert.equal(entry.out, js.slice(0, -3) + '.d.ts');
    typecheck(root, './' + js);
    await runtime(join(root, js));
  });
  test('bundle .mjs uses .d.mts and deterministic type-only helper closure', async () => {
    const root = join(out, 'bundle');
    mkdirSync(root, { recursive: true });
    const path = join(root, 'api.mjs');
    build('api.ms', path);
    const declaration = readFileSync(join(root, 'api.d.mts'), 'utf8');
    assert.match(declaration, /api.types\/.*types.js/);
    assert.ok(!declaration.includes(repo));
    typecheck(root, './api.mjs');
    await runtime(path);
    build('api.ms', path);
    assert.equal(readFileSync(join(root, 'api.d.mts'), 'utf8'), declaration);
  });
  test('empty requested entry gets a declaration and opt-out creates none', () => {
    const root = join(out, 'empty');
    build('empty.ms', root, ['--split']);
    const manifest = JSON.parse(readFileSync(join(root, '_manifest.json')));
    assert.equal(manifest.declarations.length, 1);
    assert.match(readFileSync(join(root, manifest.declarations[0].out), 'utf8'), /export \{\};/);
    const plain = join(out, 'plain.mjs');
    command(msc, ['build', source('empty.ms'), '--target=js', `--output=${plain}`]);
    assert.ok(!existsSync(join(out, 'plain.d.mts')));
  });
  test('located declaration refusal does not publish a success manifest', () => {
    const root = join(out, 'refused');
    mkdirSync(root, { recursive: true });
    const manifest = join(root, '_manifest.json');
    writeFileSync(manifest, 'previous successful manifest');
    const errors = command(msc, ['build', source('refused.ms'), '--target=js', '--split', '--declaration', `--output=${root}`], 1);
    assert.match(errors, /refused.ms/);
    assert.match(errors, /class|Class/);
    assert.equal(readFileSync(manifest, 'utf8'), 'previous successful manifest');
  });
  test('bundle rejects actual declaration path and ancestor collisions before publication', () => {
    for (const entry of ['collision/index.ms', 'ancestor/index.ms', 'ancestor/reverse.ms']) {
      const root = join(out, entry.replaceAll('/', '-'));
      mkdirSync(join(root, 'api.types'), { recursive: true });
      const bundle = join(root, 'api.mjs');
      const declaration = join(root, 'api.d.mts');
      const support = join(root, 'api.types/same.d.ts');
      const map = bundle + '.map';
      for (const file of [bundle, declaration, support, map]) writeFileSync(file, 'previous:' + file);
      const errors = command(msc, ['build', source(entry), '--target=js', '--declaration',
        '--sourcemap', `--output=${bundle}`], 1);
      assert.match(errors, /output collision/);
      for (const file of [bundle, declaration, support, map]) assert.equal(readFileSync(file, 'utf8'), 'previous:' + file);
    }
  });
  test('declaration rejects non-JS and non-ESM outputs', () => {
    for (const target of ['c', 'raiser']) {
      assert.match(command(msc, ['build', source('empty.ms'), `--target=${target}`, '--declaration'], 1),
        target === 'raiser' ? /has no Raiser output/ : /requires build --target=js/);
    }
    assert.match(command(msc, ['run', '--target=raiser', '--declaration', source('empty.ms')], 1), /requires build --target=js/);
    assert.match(command(msc, ['build', source('empty.ms'), '--target=js', '--declaration', `--output=${join(out, 'api.cjs')}`], 1), /ESM/);
  });
}
