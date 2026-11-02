import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdirSync, readFileSync, writeFileSync, realpathSync } from 'node:fs';
import { dirname, resolve, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { loadOracle } from '../../compat/typescript/run.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const repo = resolve(here, '../../../..');
const out = join(repo, 'out/declarationClasses');
const msc = resolve(process.env.MSC ?? join(repo, 'msc'));
const { identity } = loadOracle(join(repo, 'out/compat/typescript/oracle/lib/typescript.js'));
console.log(`oracle ${JSON.stringify(identity)}`);
const tsc = join(dirname(identity.path), 'tsc.js');
const flags = ['--strict', '--noEmit', '--target', 'ES2022', '--module', 'NodeNext', '--moduleResolution', 'NodeNext'];
function command(binary, args, expected = 0) {
  const result = spawnSync(binary, args, { cwd: repo, encoding: 'utf8', timeout: 60000 });
  assert.equal(result.error, undefined);
  assert.equal(result.status, expected, `${binary} ${args.join(' ')}\n${result.stdout}${result.stderr}`);
  return result.stdout + result.stderr;
}
for (const split of [false, true]) {
  test(`ordinary classes strict TS and Node ${split ? 'split' : 'bundle'}`, async () => {
    const root = join(out, split ? 'split' : 'bundle');
    mkdirSync(root, { recursive: true });
    const target = split ? root : join(root, 'api.mjs');
    command(msc, ['build', join(here, 'fixtures/classApi.ms'), '--target=js', '--declaration', `--output=${target}`, ...(split ? ['--split'] : [])]);
    writeFileSync(join(root, 'package.json'), '{"type":"module"}');
    let js = 'api.mjs';
    let declaration = join(root, 'api.d.mts');
    if (split) {
      const manifest = JSON.parse(readFileSync(join(root, '_manifest.json')));
      const source = realpathSync(join(here, 'fixtures/classApi.ms'));
      js = manifest.modules.find(file => file.source === source).out;
      declaration = join(root, manifest.declarations.find(file => file.source === source).out);
    }
    const text = readFileSync(declaration, 'utf8');
    assert.match(text, /import \{ ClassBase as/);
    assert.match(text, /class ClassChild extends/);
    const child = text.slice(text.indexOf('declare class ClassChild'), text.indexOf('declare class ClassOther'));
    assert.ok(!child.includes('"value":'), 'do not flatten inherited fields');
    writeFileSync(join(root, 'positive.mts'), `import { ClassBase, ClassChild, ClassOther, ClassTwin, ClassParameter } from ${JSON.stringify('./' + js)};
const child = new ClassChild(4);
const base: ClassBase = child;
const total: number = child.add(3) + child.scaled(2) + child.apply(value => value + 2);
const label: string = child.label;
const own: string = child.own;
const title: string = new ClassParameter('typed').title;
const a: ClassOther = new ClassOther(1);
const b: ClassTwin = new ClassTwin(2);
void [base, total, label, own, title, a, b];
`);
    command(process.execPath, [tsc, ...flags, join(root, 'positive.mts')]);
    const negatives = [
      ["new ClassChild('wrong');", /TS2345/],
      ['new ClassChild();', /TS2554/],
      ["new ClassChild(1).add('wrong');", /TS2345/],
      ["new ClassChild(1).label = 'wrong';", /TS2540/],
      ['new ClassChild(1).offset;', /TS2445/],
      ['new ClassChild(1).secret;', /TS2341/],
      ['new ClassChild(1).hidden();', /TS2341/],
      ['const wrong: ClassOther = new ClassTwin(1);', /TS2322/],
      ["new ClassParameter('x').title = 'wrong';", /TS2540/],
    ];
    for (let i = 0; i < negatives.length; i++) {
      const file = join(root, `negative${i}.mts`);
      writeFileSync(file, `import { ClassChild, ClassOther, ClassTwin, ClassParameter } from ${JSON.stringify('./' + js)};\n${negatives[i][0]}\n`);
      const errors = command(process.execPath, [tsc, ...flags, file], 2);
      assert.match(errors, negatives[i][1]);
      writeFileSync(file + '.log', errors);
    }
    const api = await import(pathToFileURL(join(root, js)));
    const childValue = new api.ClassChild(4);
    assert.equal(childValue.value, 4);
    assert.equal(childValue.add(3), 7);
    assert.equal(childValue.scaled(2), 8);
    assert.equal(childValue.apply(value => value + 2), 6);
    assert.equal(childValue.label, 'base');
    assert.equal(childValue.own, 'child');
    assert.ok(childValue instanceof api.ClassChild);
    assert.ok(childValue instanceof api.ClassBase);
    assert.equal(new api.ClassOther(2).add(3), 5);
    assert.equal(new api.ClassTwin(3).add(3), 6);
    assert.equal(new api.ClassParameter('typed').title, 'typed');
  });
}
