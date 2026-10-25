import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { basename, join } from 'node:path';
import vm from 'node:vm';
import { fingerprint } from './core.mjs';

export function verifySnapshot(root, pin) {
  const snapshot = fingerprint(root, pin.snapshotEntries);
  if (snapshot.sha256 !== pin.snapshotSha256) throw new Error(`upstream snapshot differs from ${pin.commit}: ${snapshot.sha256}`);
  const cases = Object.keys(snapshot.files).filter(name => /^tests\/cases\/(compiler|conformance)\/.*\.tsx?$/.test(name));
  if (cases.length !== pin.caseFiles) throw new Error(`upstream case count: expected ${pin.caseFiles}, found ${cases.length}`);
  return { ...snapshot, cases };
}

function select(ts, source, names) {
  const ast = ts.createSourceFile('upstream.ts', source, ts.ScriptTarget.Latest, true);
  const selected = [];
  for (const name of names) {
    const node = ast.statements.find(stmt => stmt.name?.text === name ||
      ts.isVariableStatement(stmt) && stmt.declarationList.declarations.some(decl => decl.name.getText(ast) === name));
    if (!node) throw new Error(`upstream declaration missing: ${name}`);
    selected.push(node.getText(ast));
  }
  return selected.join('\n');
}

export function loadHarness(ts, root) {
  const io = readFileSync(join(root, 'src/harness/harnessIO.ts'), 'utf8');
  const ast = ts.createSourceFile('harnessIO.ts', io, ts.ScriptTarget.Latest, true);
  const compiler = ast.statements.find(stmt => ts.isModuleDeclaration(stmt) && stmt.name.text === 'Compiler');
  if (!compiler || !ts.isModuleBlock(compiler.body)) throw new Error('upstream Compiler namespace missing');
  const utils = readFileSync(join(root, 'src/harness/harnessUtils.ts'), 'utf8');
  const runner = ts.createSourceFile('compilerRunner.ts', readFileSync(join(root, 'src/testRunner/compilerRunner.ts'), 'utf8'), ts.ScriptTarget.Latest, true);
  const klass = runner.statements.find(stmt => ts.isClassDeclaration(stmt) && stmt.name?.text === 'CompilerTest');
  const varyBy = klass?.members.find(member => member.name?.getText(runner) === 'varyBy')?.initializer;
  if (!varyBy) throw new Error('upstream configuration expansion missing');
  const source = [
    select(ts, io, ['splitVaryBySettingValue', 'computeFileBasedTestConfigurationVariations', 'booleanVaryByStarSettingValues',
      'getVaryByStarSettingValues', 'getFileBasedTestConfigurations', 'getConfigNameFromFileName', 'TestCaseParser']),
    select(ts, compiler.body.statements.map(stmt => stmt.getText(ast)).join('\n'),
      ['harnessOptionDeclarations', 'optionsIndex', 'getCommandLineOption', 'setCompilerOptionsFromHarnessSetting', 'optionValue']),
    select(ts, utils, ['splitContentByNewlines']),
    'const Utils = { splitContentByNewlines };',
    `export const varyBy = ${varyBy.getText(runner)};`,
  ].join('\n');
  const exports = {};
  const output = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 } });
  vm.runInNewContext(output.outputText, {
    exports, ts, assert: { isTrue: value => assert.ok(value) },
    vfs: { srcFolder: '/src', Symlink: class { constructor(source) { this.source = source; } } },
  }, { filename: 'pinned-upstream-harness.js', timeout: 5000 });
  return exports;
}

export function enumerate(root, snapshot, harness) {
  const cases = [];
  for (const file of snapshot.cases) {
    const text = readFileSync(join(root, file), 'utf8');
    const settings = harness.TestCaseParser.extractCompilerSettings(text);
    const configurations = harness.getFileBasedTestConfigurations(settings, harness.varyBy) ?? [{}];
    for (const configuration of configurations) {
      const keys = Object.keys(configuration).sort();
      cases.push({
        id: `${file}#${keys.map(key => `${key}=${configuration[key]}`).join(',') || 'default'}`,
        file, sourceSha256: snapshot.files[file], configuration,
      });
    }
  }
  if (new Set(cases.map(item => item.id)).size !== cases.length) throw new Error('duplicate upstream configuration IDs');
  return cases;
}

export function prepareCase(ts, harness, text, entry) {
  const parsed = harness.TestCaseParser.makeUnitsFromTest(text, entry.file);
  const settings = { ...parsed.settings, ...entry.configuration };
  const options = { noResolve: false, newLine: ts.NewLineKind.CarriageReturnLineFeed, noErrorTruncation: true, skipDefaultLibCheck: true };
  harness.setCompilerOptionsFromHarnessSetting(settings, options);
  const unsupported = [];
  if (parsed.tsConfig) unsupported.push('tsconfig virtual project');
  if (parsed.symlinks) unsupported.push('virtual symlinks');
  for (const name of ['currentDirectory', 'includeBuiltFile', 'libFiles', 'typeScriptVersion']) {
    if (settings[name]) unsupported.push(`harness setting ${name}`);
  }
  if (options.useCaseSensitiveFileNames === false) unsupported.push('case-insensitive filesystem');
  const pathOptions = ts.optionDeclarations.filter(option => option.isFilePath || option.element?.isFilePath).map(option => option.name);
  for (const name of pathOptions) if (options[name] !== undefined) unsupported.push(`path option ${name}`);
  if (options.paths) unsupported.push('paths mapping');
  const files = parsed.testUnitData.map(unit => ({ name: unit.name, content: unit.content }));
  const last = files.at(-1);
  const roots = settings.noImplicitReferences || /require\(/.test(last.content) || /reference\spath/.test(last.content)
    ? [last.name] : files.map(unit => unit.name).filter(name => !name.endsWith('.json'));
  if (roots.length !== 1) unsupported.push(`multiple CLI roots (${roots.length})`);
  if (roots[0] && !/\.(ts|tsx|js|jsx|mts|cts|mjs|cjs)$/.test(roots[0])) unsupported.push(`entry extension ${basename(roots[0])}`);
  if (files.some(file => /^\s*\/\/\/\s*<reference\s+path=/m.test(file.content))) unsupported.push('triple-slash file references');
  if (options.captureSuggestions) unsupported.push('suggestion diagnostic capture');
  return { files, roots, options, settings, unsupported };
}
