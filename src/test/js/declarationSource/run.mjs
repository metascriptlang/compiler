import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync, copyFileSync, existsSync, realpathSync, symlinkSync } from 'node:fs';
import { dirname, resolve, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { loadOracle } from '../../compat/typescript/run.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const repo = resolve(here, '../../../..');
const msc = resolve(process.env.MSC ?? join(repo, 'msc'));
mkdirSync(join(repo, 'out/declarationSource'), { recursive: true });
const work = mkdtempSync(join(repo, 'out/declarationSource/run-'));
const src = join(work, 'src');
const output = join(work, 'build');
mkdirSync(src);
mkdirSync(join(work, 'support'));
writeFileSync(join(work, 'package.json'), '{"type":"commonjs"}');
writeFileSync(join(src, 'package.json'), '{"type":"module"}');
for (const name of ['primary.ms', 'base.jms', 'independent.ms']) copyFileSync(join(here, name), join(src, name));
copyFileSync(join(here, 'label.ms'), join(work, 'support/label.ms'));
const primary = realpathSync(join(src, 'primary.ms'));
const base = realpathSync(join(src, 'base.jms'));
const independent = realpathSync(join(src, 'independent.ms'));
function command(binary, args, expected = 0) {
  const result = spawnSync(binary, args, { cwd: repo, encoding: 'utf8', timeout: 60000 });
  assert.equal(result.error, undefined);
  assert.equal(result.status, expected, `${binary} ${args.join(' ')}\n${result.stdout}${result.stderr}`);
  return result.stdout + result.stderr;
}
function build(entry = primary, extra = [], target = output, expected = 0) {
  return command(msc, ['build', entry, '--target=js', '--split', '--declaration',
    `--declaration-source-root=${src}`, `--output=${target}`, ...extra], expected);
}
function manifest(target = output) { return JSON.parse(readFileSync(join(target, '_manifest.json'))); }
function sourceFile(tree, source) { return tree.sourceDeclarations.find(file => file.source === source); }
const oraclePath = join(repo, 'out/compat/typescript/oracle/lib/typescript.js');
if (!existsSync(oraclePath)) command(process.execPath, [join(repo, 'src/test/compat/typescript/run.mjs'), 'fetch']);
const { identity } = loadOracle(oraclePath);
console.log(`oracle ${JSON.stringify(identity)}`);
const tsc = join(dirname(identity.path), 'tsc.js');

function typecheck(mode) {
  const options = { strict: true, skipLibCheck: false, noEmit: true, target: 'ES2022',
    module: mode === 'NodeNext' ? 'NodeNext' : 'ESNext', moduleResolution: mode,
    allowArbitraryExtensions: true, jsx: 'preserve', rootDirs: [src, join(output, '_source_declarations')] };
  const positive = `import { Child, increment, readLabel, answer } from './primary.ms';
import { Base } from './base.jms';
const child = new Child(4);
const base: Base = child;
const value: number = base.add(increment(answer)) + child.doubled();
const label: string = readLabel({ text: 'typed' });
void [value, label];
`;
  writeFileSync(join(src, 'consumer.ts'), positive);
  writeFileSync(join(src, 'consumer.tsx'), positive + `declare global { namespace JSX { interface IntrinsicElements { button: { children?: unknown }; } } }
const element = <button>{child.doubled()}</button>;
void element;
`);
  const config = join(work, `${mode}.json`);
  writeFileSync(config, JSON.stringify({ compilerOptions: options, files: [join(src, 'consumer.ts'), join(src, 'consumer.tsx')] }));
  command(process.execPath, [tsc, '-p', config]);
  const negative = `import { Child, increment, readLabel, missing } from './primary.ms';
import { Base } from './base.jms';
increment('wrong');
new Child('wrong');
readLabel({ text: 1 });
new Base(1).secret;
new Child(1).absent;
`;
  for (const extension of ['ts', 'tsx']) {
    writeFileSync(join(src, `negative.${extension}`), negative);
    writeFileSync(config, JSON.stringify({ compilerOptions: options, files: [join(src, `negative.${extension}`)] }));
    const errors = command(process.execPath, [tsc, '-p', config], 2);
    for (const code of ['TS2305', 'TS2345', 'TS2322', 'TS2341', 'TS2339']) assert.ok(errors.includes(code), errors);
    writeFileSync(join(work, `${mode}-${extension}-negative.log`), errors);
  }
}

test('explicit source roots share class identity through precise TS/TSX declarations and Node outputs', () => {
  build();
  const single = manifest();
  const supportingBase = sourceFile(single, base);
  assert.ok(supportingBase.out.startsWith('_source_declarations/_types/'));
  assert.ok(supportingBase.out.endsWith('.d.ts'));
  assert.ok(!existsSync(join(output, '_source_declarations/base.d.jms.ts')));
  symlinkSync('base.jms', join(src, 'baseAlias.jms'));
  build(primary, [`--js-entry=${base}`, `--js-entry=${join(src, 'baseAlias.jms')}`, `--js-entry=${independent}`, `--js-entry=${primary}`]);
  const tree = manifest();
  assert.deepEqual(tree.entries, [primary, base, independent]);
  assert.equal(tree.entry, primary);
  assert.equal(tree.sourceDeclarationRoot, '_source_declarations');
  assert.equal(tree.sourceDeclarationPackage, '_source_declarations/package.json');
  assert.deepEqual(JSON.parse(readFileSync(join(output, tree.sourceDeclarationPackage))), { type: 'module' });
  assert.equal(readFileSync(join(work, 'package.json'), 'utf8'), '{"type":"commonjs"}');
  assert.equal(sourceFile(tree, primary).out, '_source_declarations/primary.d.ms.ts');
  assert.equal(sourceFile(tree, base).out, '_source_declarations/base.d.jms.ts');
  const childText = readFileSync(join(output, sourceFile(tree, primary).out), 'utf8');
  assert.match(childText, /\.\/base\.jms/);
  assert.ok(!childText.includes('_types/base.js'));
  const support = sourceFile(tree, realpathSync(join(work, 'support/label.ms')));
  assert.ok(support.out.startsWith('_source_declarations/_types/'));
  assert.ok(!readFileSync(join(output, support.out), 'utf8').includes('internalGeneric'));
  assert.ok(tree.dependencies.includes(base));
  assert.ok(tree.dependencies.includes(independent));
  for (const mode of ['NodeNext', 'Bundler']) typecheck(mode);
  writeFileSync(join(output, 'package.json'), '{"type":"module"}');
  const js = source => pathToFileURL(join(output, tree.modules.find(file => file.source === source).out)).href;
  const runtime = command(process.execPath, ['--input-type=module', '-e', `
const api = await import(${JSON.stringify(js(primary))});
const base = await import(${JSON.stringify(js(base))});
const value = new api.Child(4);
if (!(value instanceof base.Base) || value.add(3) !== 8 || value.doubled() !== 8 || api.increment(2) !== 3 || api.readLabel({text:'node'}) !== 'node' || api.answer !== 42) throw Error('API mismatch');
console.log('primary ready');
const independent = await import(${JSON.stringify(js(independent))});
if (independent.independent !== 9) throw Error('secondary mismatch');
console.log('secondary ready');
`]);
  assert.equal(runtime, 'primary ready\nindependent initialized\nsecondary ready\n');
});

test('empty source entry emits an ESM sidecar; plain multi-entry split opts out', () => {
  const empty = join(src, 'empty.ms');
  const emptyJs = join(src, 'emptyOther.jms');
  writeFileSync(empty, '');
  writeFileSync(emptyJs, '');
  const target = join(work, 'empty');
  build(empty, [`--js-entry=${emptyJs}`], target);
  const tree = manifest(target);
  assert.equal(tree.sourceDeclarations.length, 2);
  for (const file of tree.sourceDeclarations) {
    assert.match(readFileSync(join(target, file.out), 'utf8'), /export \{\};/);
  }
  const plain = join(work, 'plain');
  command(msc, ['build', empty, '--target=js', '--split', `--js-entry=${independent}`, `--output=${plain}`]);
  const optedOut = manifest(plain);
  assert.deepEqual(optedOut.entries, [empty, independent]);
  assert.deepEqual(optedOut.declarations, []);
  assert.equal(optedOut.sourceDeclarations, undefined);
  assert.ok(!existsSync(join(plain, '_source_declarations')));
});

test('source root and located declaration errors leave the previous manifest and files intact', () => {
  const target = join(work, 'lastGood');
  build(primary, [`--js-entry=${base}`], target);
  const previous = readFileSync(join(target, '_manifest.json'), 'utf8');
  const previousDeclaration = readFileSync(join(target, '_source_declarations/primary.d.ms.ts'), 'utf8');
  const outside = join(work, 'outside.ms');
  writeFileSync(outside, 'export const outside: int32 = 1;');
  assert.match(build(primary, [`--js-entry=${outside}`], target, 1), /source declaration entry.*outside\.ms.*must be under/);
  assert.match(build(primary, [`--declaration-source-root=${join(work, 'missing')}`], target, 1), /existing directory/);
  assert.match(build(primary, [`--declaration-source-root=${primary}`], target, 1), /existing directory/);
  const invalidExtension = join(src, 'bad.cms');
  writeFileSync(invalidExtension, '');
  assert.match(build(invalidExtension, [], target, 1), /end in \.ms or \.jms/);
  const refused = join(src, 'refused.ms');
  writeFileSync(refused, 'export function identity<T>(value: T): T { return value; }');
  const errors = build(refused, [], target, 1);
  assert.match(errors, /refused\.ms:1:/);
  assert.match(errors, /cannot emit JS declaration/);
  assert.equal(readFileSync(join(target, '_manifest.json'), 'utf8'), previous);
  assert.equal(readFileSync(join(target, '_source_declarations/primary.d.ms.ts'), 'utf8'), previousDeclaration);
});

test('case-folded output collisions fail before publishing files or a manifest', () => {
  const target = join(work, 'collision');
  const upper = join(src, 'Case.ms');
  const lower = join(src, 'case.ms');
  writeFileSync(upper, 'export const upper: int32 = 1;');
  writeFileSync(lower, 'export const lower: int32 = 2;');
  if (realpathSync(upper) === realpathSync(lower)) throw Error('case-sensitive fixture filesystem required');
  assert.match(build(upper, [`--js-entry=${lower}`], target, 1), /output collision/);
  assert.ok(!existsSync(target));
});

test('file and directory output collisions fail before publication in either root order', () => {
  const target = join(work, 'ancestorCollision');
  const parent = join(src, 'clash.ms');
  const child = join(src, 'clash.js/child.ms');
  writeFileSync(parent, 'export const parent: int32 = 1;');
  mkdirSync(dirname(child));
  writeFileSync(child, 'export const child: int32 = 2;');
  for (const [first, second] of [[parent, child], [child, parent]]) {
    assert.match(build(first, [`--js-entry=${second}`], target, 1), /output collision/);
    assert.ok(!existsSync(target));
  }
});

test('source and extra-root options reject unsupported command combinations and empty paths', () => {
  for (const args of [
    ['run', '--target=js', '--split', `--js-entry=${base}`, primary],
    ['build', primary, '--target=c', '--split', `--js-entry=${base}`],
    ['build', primary, '--target=js', `--js-entry=${base}`],
  ]) assert.match(command(msc, args, 1), /--js-entry requires build --target=js --split/);
  for (const args of [
    ['build', primary, '--target=js', '--split'],
    ['build', primary, '--target=js', '--declaration'],
  ]) assert.match(command(msc, [...args, `--declaration-source-root=${src}`], 1), /--declaration-source-root requires/);
  for (const flag of ['--js-entry=', '--declaration-source-root=']) {
    assert.match(command(msc, ['build', primary, '--target=js', '--split', flag], 1), /requires a (path|directory)/);
  }
});
