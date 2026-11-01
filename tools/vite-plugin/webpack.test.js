import assert from "node:assert/strict";
import { chmodSync, existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, relative, resolve } from "node:path";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
import { test } from "node:test";
import MetaScriptPlugin, { loader } from "./webpack.js";
import metascriptLoader from "./webpackLoader.js";
import { canonicalPath } from "./compilerCore.js";

class Hook {
	callbacks = [];
	tap(options, callback) { this.callbacks.push(callback); this.options = options; }
	call(...args) { for (const callback of this.callbacks) callback(...args); }
}

function fixture(t) {
	const root = canonicalPath(mkdtempSync(join(tmpdir(), "msc webpack ")));
	t.after(() => rmSync(root, { recursive: true, force: true }));
	const entry = join(root, "main.ms");
	const dependency = join(root, "types.jms");
	writeFileSync(entry, "source");
	writeFileSync(dependency, "types");
	const msc = join(root, "fake-msc.cjs");
	writeFileSync(msc, `#!/usr/bin/env node
const fs = require("node:fs"), path = require("node:path");
const state = JSON.parse(fs.readFileSync(path.join(__dirname, "state.json"), "utf8"));
fs.appendFileSync(path.join(__dirname, "calls"), "call\\n");
if (state.fail || (state.required && !fs.existsSync(state.required))) { process.stderr.write("fixture compiler diagnostic"); process.exit(2); }
const out = process.argv.find(arg => arg.startsWith("--output=")).slice(9);
for (const [name, text] of Object.entries(state.files)) {
 const file = path.join(out, name); fs.mkdirSync(path.dirname(file), { recursive: true }); fs.writeFileSync(file, text);
}
fs.writeFileSync(path.join(out, "_manifest.json"), JSON.stringify(state.manifest));
`);
	chmodSync(msc, 0o755);
	const state = {
		manifest: { entry, modules: [{ source: entry, out: "nested/main.js" }], instances: [], dependencies: [dependency], declarations: [{ source: entry, out: "nested/main.d.ts" }] },
		files: {
			"nested/main.js": "export const value = 1;\n//# sourceMappingURL=main.js.map\n",
			"nested/main.js.map": JSON.stringify({ version: 3, sources: ["../../../../main.ms"], sourcesContent: ["source"], names: [], mappings: "AAAA" }),
			"nested/main.d.ts": "export declare const value: number;",
		},
	};
	const save = () => writeFileSync(join(root, "state.json"), JSON.stringify(state));
	save();
	const settings = { root, entry, msc, declaration: true };
	const calls = () => existsSync(join(root, "calls")) ? readFileSync(join(root, "calls"), "utf8").trim().split("\n").length : 0;
	return { root, entry, dependency, state, save, settings, calls };
}

function fakeCompiler(root, plugin, hooks = {}) {
	const compiler = {
		context: root,
		hooks: { thisCompilation: new Hook(), ...hooks },
		webpack: {
			version: "5.0.0",
			Compilation: { PROCESS_ASSETS_STAGE_ADDITIONAL: -2000 },
			NormalModule: { getCompilationHooks: compilation => compilation.moduleHooks },
			sources: { RawSource: class { constructor(text) { this.text = text; } source() { return this.text; } } },
		},
	};
	plugin.apply(compiler);
	return compiler;
}

function generation(compiler) {
	const assets = new Map();
	const compilation = {
		fileDependencies: new Set(), buildDependencies: new Set(), contextDependencies: new Set(), missingDependencies: new Set(),
		errors: [], hooks: { processAssets: new Hook() }, moduleHooks: { loader: new Hook() },
		moduleGraph: { getParentModule: dependency => dependency.parent },
		emitAsset: (name, asset) => assets.set(name, asset.source()),
	};
	const normalModuleFactory = { hooks: { beforeResolve: new Hook() } };
	compiler.hooks.thisCompilation.call(compilation, { normalModuleFactory });
	return { compilation, assets, normalModuleFactory };
}

function load(compilation, resourcePath, resourceQuery = "") {
	let result;
	const dependencies = new Set(), buildDependencies = new Set();
	const context = {
		resourcePath, resourceQuery,
		async: () => (error, code, map) => { result = { error, code, map }; },
		cacheable: value => { context.cached = value; },
		addDependency: file => dependencies.add(file), addBuildDependency: file => buildDependencies.add(file),
	};
	compilation.moduleHooks.loader.call(context);
	metascriptLoader.call(context);
	return { ...result, dependencies, buildDependencies, cached: context.cached };
}

function request(generation, issuer, source) {
	const data = { contextInfo: { issuer }, request: source };
	generation.normalModuleFactory.hooks.beforeResolve.call(data);
	return data.request;
}

test("webpack package subpaths preserve Vite and Rollup entries", () => {
	const pkg = JSON.parse(readFileSync(new URL("./package.json", import.meta.url), "utf8"));
	assert.equal(pkg.exports["."].default, "./index.js");
	assert.equal(pkg.exports["./rollup"].default, "./rollup.js");
	assert.deepEqual(pkg.exports["./webpack"], { types: "./webpack.d.ts", default: "./webpack.js" });
	assert.equal(pkg.exports["./webpack/loader"], "./webpackLoader.js");
	for (const file of ["webpack.js", "webpack.d.ts", "webpackLoader.js"]) assert.ok(pkg.files.includes(file));
	assert.equal(pkg.peerDependencies.webpack, "^5.0.0");
	assert.equal(pkg.peerDependenciesMeta.webpack.optional, true);
	assert.match(loader, /webpackLoader\.js$/);
});

test("one compilation snapshot supplies JS maps dependencies and declaration assets", t => {
	const f = fixture(t);
	const compiler = fakeCompiler(f.root, new MetaScriptPlugin(f.settings));
	const g = generation(compiler);
	for (let i = 0; i < 2; i++) {
		const output = load(g.compilation, f.entry);
		assert.ifError(output.error);
		assert.equal(output.code, "export const value = 1;\n");
		assert.deepEqual(output.map.sources, [f.entry]);
		assert.equal(output.cached, false);
		assert.ok(output.dependencies.has(f.dependency));
		assert.ok([...output.buildDependencies].some(file => file.endsWith("compilerCore.js")));
	}
	assert.ok(g.compilation.fileDependencies.has(f.dependency));
	assert.ok(g.compilation.buildDependencies.has(f.settings.msc));
	assert.equal(g.compilation.contextDependencies.size, 0);
	assert.equal(g.compilation.missingDependencies.size, 0);
	assert.equal(g.compilation.hooks.processAssets.options.stage, -2000);
	g.compilation.hooks.processAssets.call();
	assert.deepEqual([...g.assets], [["nested/main.d.ts", f.state.files["nested/main.d.ts"]]]);
	assert.equal(f.calls(), 1);
	assert.equal(existsSync(join(f.root, "dist")), false);
});

test("emitted relative modules and instances return to the configured loader flow", t => {
	const f = fixture(t);
	f.state.manifest.modules.push({ source: f.dependency, out: "other/types.js" });
	f.state.manifest.instances.push({ source: f.dependency, out: "_instances/types_number.js" });
	f.state.files["other/types.js"] = "export const normal = 1;";
	f.state.files["_instances/types_number.js"] = "export const special = 2;";
	f.save();
	const g = generation(fakeCompiler(f.root, new MetaScriptPlugin(f.settings)));
	assert.equal(request(g, f.entry, "../other/types.js"), f.dependency);
	assert.equal(request(g, f.entry, "../_instances/types_number.js"), `${f.dependency}?instance=types_number`);
	assert.equal(request(g, `${f.dependency}?instance=types_number`, "../other/types.js"), f.dependency);
	assert.equal(load(g.compilation, f.dependency, "?instance=types_number").code, "export const special = 2;");
	assert.match(load(g.compilation, f.entry, "?instance=types_number").error.message, /outside.*graph/);
	assert.equal(request(g, f.entry, "package"), "package");
	assert.equal(request(g, f.entry, "../external.js"), "../external.js");
	assert.match(load(g.compilation, join(f.root, "absent.ms")).error.message, /outside.*graph/);
});

test("warm module generations still publish current types and remove stale asset inventory", t => {
	const f = fixture(t);
	const compiler = fakeCompiler(f.root, new MetaScriptPlugin(f.settings));
	let g = generation(compiler);
	g.compilation.hooks.processAssets.call();
	f.state.manifest.declarations[0].out = "renamed.d.ts";
	f.state.files["renamed.d.ts"] = "export declare const value: 2;";
	f.save();
	g = generation(compiler);
	g.compilation.hooks.processAssets.call();
	assert.deepEqual([...g.assets], [["renamed.d.ts", "export declare const value: 2;"]]);
	assert.equal(f.calls(), 2);
});

test("failed compilations preserve recovery watches but never publish previous declarations", t => {
	const f = fixture(t);
	const compiler = fakeCompiler(f.root, new MetaScriptPlugin(f.settings));
	generation(compiler);
	f.state.fail = true;
	f.save();
	let g = generation(compiler);
	assert.match(g.compilation.errors[0].message, /fixture compiler diagnostic/);
	assert.match(load(g.compilation, f.entry).error.message, /fixture compiler diagnostic/);
	g.compilation.hooks.processAssets.call();
	assert.equal(g.assets.size, 0);
	assert.ok(g.compilation.fileDependencies.has(f.dependency));
	f.state.fail = false;
	f.save();
	g = generation(compiler);
	assert.equal(g.compilation.errors.length, 0);
	g.compilation.hooks.processAssets.call();
	assert.equal(g.assets.size, 1);
	assert.equal(f.calls(), 3);
});

test("one plugin reused across compilers keeps separate compilation state", t => {
	const f = fixture(t);
	const plugin = new MetaScriptPlugin(f.settings);
	const first = generation(fakeCompiler(f.root, plugin));
	f.state.files["nested/main.js"] = "export const value = 2;";
	f.save();
	const second = generation(fakeCompiler(f.root, plugin));
	assert.match(load(first.compilation, f.entry).code, /value = 1/);
	assert.match(load(second.compilation, f.entry).code, /value = 2/);
	assert.equal(f.calls(), 2);
});

test("declarations are opt-in and loader requires companion plugin and webpack 5", t => {
	const f = fixture(t);
	const g = generation(fakeCompiler(f.root, new MetaScriptPlugin({ ...f.settings, declaration: false, sourcemap: false })));
	assert.equal(load(g.compilation, f.entry).map, undefined);
	g.compilation.hooks.processAssets.call();
	assert.equal(g.assets.size, 0);
	let error;
	metascriptLoader.call({ async: () => value => { error = value; }, cacheable() {} });
	assert.match(error.message, /requires MetaScriptPlugin/);
	assert.throws(() => new MetaScriptPlugin(), /explicit/);
	assert.throws(() => new MetaScriptPlugin({ entry: [] }), /explicit/);
	assert.throws(() => new MetaScriptPlugin(f.settings).apply({ webpack: { version: "4.0.0" } }), /webpack 5/);
});

let webpackPath = process.env.WEBPACK_MODULE;
if (!webpackPath) {
	try { webpackPath = createRequire(import.meta.url).resolve("webpack"); }
	catch (error) { if (error.code !== "MODULE_NOT_FOUND") throw error; }
}
const webpack = webpackPath ? createRequire(import.meta.url)(webpackPath) : null;
const unavailable = webpack ? false : "webpack is not provisioned; fake hooks prove protocol only";
if (webpack) console.log(`webpack integration version: ${webpack.version}`);

function run(compiler) {
	return new Promise((resolve, reject) => compiler.run((error, stats) => {
		if (error) reject(error);
		else if (stats.hasErrors()) reject(new Error(stats.toString({ all: false, errors: true })));
		else resolve(stats);
	}));
}

function memoryOutput(compiler) {
	const files = new Map();
	compiler.outputFileSystem = {
		mkdir: (path, options, callback) => (callback ?? options)(null),
		writeFile: (path, content, callback) => { files.set(path, content); callback(null); },
		stat: (path, callback) => callback(Object.assign(new Error("missing"), { code: "ENOENT" })),
		join,
	};
	return files;
}

test("real webpack memory output resolves static reexport dynamic and instance modules", { skip: unavailable }, async t => {
	const f = fixture(t);
	f.state.manifest.modules.push({ source: f.dependency, out: "other/types.js" });
	f.state.manifest.instances.push({ source: f.dependency, out: "_instances/types_number.js" });
	f.state.files["other/types.js"] = "export const normal = 1;";
	const helper = join(f.root, "helper.ms");
	writeFileSync(helper, "instance helper");
	f.state.manifest.modules.push({ source: helper, out: "_instances/helper.js" });
	f.state.files["_instances/helper.js"] = "export const special = 2;";
	f.state.files["_instances/types_number.js"] = 'export { special } from "./helper.js";';
	f.state.files["nested/main.js"] = `import { normal } from "../other/types.js";
import { special } from "../_instances/types_number.js";
export { normal } from "../other/types.js";
export const value = normal + special;
export async function dynamic() { return (await import("../_instances/types_number.js")).special; }`;
	f.save();
	const compiler = webpack({
		mode: "development", context: f.root, entry: f.entry, target: "node", devtool: "source-map", parallelism: 1,
		output: { path: join(f.root, "dist"), filename: "bundle.cjs", library: { type: "commonjs2" } },
		module: { rules: [{ test: /\.(ms|jms)$/, type: "javascript/auto", use: [{ loader }] }] },
		plugins: [new MetaScriptPlugin(f.settings)],
	});
	t.after(() => new Promise((resolve, reject) => compiler.close(error => error ? reject(error) : resolve())));
	const files = memoryOutput(compiler);
	await run(compiler);
	assert.equal(files.get(join(f.root, "dist/nested/main.d.ts")).toString(), f.state.files["nested/main.d.ts"]);
	const result = { exports: {} };
	new Function("module", "exports", files.get(join(f.root, "dist/bundle.cjs")).toString())(result, result.exports);
	assert.equal(result.exports.value, 3);
	assert.equal(result.exports.normal, 1);
	assert.equal(await result.exports.dynamic(), 2);
	const map = JSON.parse(files.get(join(f.root, "dist/bundle.cjs.map")));
	assert.ok(map.sources.some(source => source.endsWith("main.ms")));
	assert.equal(existsSync(join(f.root, "dist")), false);
	assert.equal(f.calls(), 1);
	f.state.manifest.declarations[0].out = "fresh.d.ts";
	f.state.files["fresh.d.ts"] = "export declare const value: 3;";
	f.save();
	files.clear();
	const stats = await run(compiler);
	assert.ok(stats.compilation.getAsset("fresh.d.ts"));
	assert.equal(stats.compilation.getAsset("nested/main.d.ts"), undefined);
	assert.equal(f.calls(), 2);
});

function nativeConfig(f, plugin, extra = {}) {
	return {
		mode: "development", context: f.root, entry: f.entry, target: "node", devtool: false, parallelism: 1,
		output: { path: join(f.root, "dist"), filename: "bundle.js" },
		module: { rules: [{ test: /\.(ms|jms)$/, type: "javascript/auto", use: [{ loader }] }] },
		plugins: [plugin], ...extra,
	};
}

function close(compiler) {
	return new Promise((resolve, reject) => compiler.close(error => error ? reject(error) : resolve()));
}

test("real webpack persistent cache restores host modules without skipping project declarations", { skip: unavailable }, async t => {
	const f = fixture(t);
	const host = join(f.root, "host.js");
	writeFileSync(host, "export const host = 1;");
	const config = () => nativeConfig(f, new MetaScriptPlugin(f.settings), {
		entry: host,
		cache: { type: "filesystem", cacheDirectory: join(f.root, "webpack-cache"), name: "test" },
	});
	let compiler = webpack(config());
	memoryOutput(compiler);
	let stats = await run(compiler);
	assert.ok(stats.compilation.getAsset("nested/main.d.ts"));
	await close(compiler);
	f.state.files["nested/main.d.ts"] = "export declare const value: 2;";
	f.save();
	compiler = webpack(config());
	t.after(() => close(compiler));
	const files = memoryOutput(compiler);
	stats = await run(compiler);
	const module = [...stats.compilation.modules].find(module => module.resource === host);
	assert.ok(module);
	assert.equal(stats.compilation.builtModules.has(module), false);
	assert.equal(files.get(join(f.root, "dist/nested/main.d.ts")).toString(), "export declare const value: 2;");
	assert.equal(f.calls(), 2);
});

test("real webpack MultiCompiler can reuse a plugin without sharing graphs or asset destinations", { skip: unavailable }, async t => {
	const f = fixture(t);
	const plugin = new MetaScriptPlugin(f.settings);
	const configs = ["first", "second"].map(name => nativeConfig(f, plugin, {
		name, output: { path: join(f.root, name), filename: "bundle.js" },
	}));
	const compiler = webpack(configs);
	t.after(() => close(compiler));
	const outputs = compiler.compilers.map(memoryOutput);
	const stats = await run(compiler);
	for (let i = 0; i < 2; i++) {
		assert.ok(stats.stats[i].compilation.getAsset("nested/main.d.ts"));
		assert.equal(outputs[i].get(join(configs[i].output.path, "nested/main.d.ts")).toString(), f.state.files["nested/main.d.ts"]);
		assert.equal(existsSync(configs[i].output.path), false);
	}
	assert.equal(f.calls(), 2);
});

test("real webpack child compilations do not recompile or publish the parent project", { skip: unavailable }, async t => {
	const f = fixture(t);
	let childAssets;
	const compiler = webpack(nativeConfig(f, new MetaScriptPlugin(f.settings)));
	compiler.hooks.make.tapAsync("child fixture", (compilation, done) => {
		const child = compilation.createChildCompiler("child fixture", {});
		child.runAsChild((error, entries, result) => {
			childAssets = result?.getAssets();
			done(error);
		});
	});
	t.after(() => close(compiler));
	memoryOutput(compiler);
	await run(compiler);
	assert.deepEqual(childAssets, []);
	assert.equal(f.calls(), 1);
});

const oraclePath = process.env.TS_ORACLE_MODULE ?? resolve("out/compat/typescript/oracle/lib/typescript.js");
test("verified TS oracle checks strict NodeNext webpack options and adapter declarations", {
	skip: unavailable || (!existsSync(oraclePath) && "pinned TypeScript oracle is not provisioned"),
}, async t => {
	const { loadOracle } = await import("../../src/test/compat/typescript/run.mjs");
	const { ts, identity } = loadOracle(oraclePath);
	assert.equal(identity.version, "5.9.2");
	const file = new URL(`./.webpack-options-${process.pid}.mts`, import.meta.url);
	t.after(() => rmSync(file, { force: true }));
	writeFileSync(file, `import MetaScriptPlugin, { loader } from "vite-plugin-metascript/webpack";
import type { Configuration } from "webpack";
import metascript from "vite-plugin-metascript";
import rollupMetascript from "vite-plugin-metascript/rollup";
import { buildCompilerGraph } from "vite-plugin-metascript/core";
metascript({entry:["a.ms","b.jms"] as const, sourceDeclarations:{outDir:"editor-types"}});
rollupMetascript({entry:["a.ms","b.jms"] as const, sourceDeclarations:{outDir:"editor-types"}});
buildCompilerGraph({entry:["a.ms","b.jms"] as const, sourceRoot:"src"}).entries satisfies readonly string[];
const config: Configuration = { plugins: [new MetaScriptPlugin({ entry: "src/main.ms", declaration: true })], module: { rules: [{ test: /\\.(ms|jms)$/, use: [{ loader }] }] } };
// @ts-expect-error entry is required
new MetaScriptPlugin({});
// @ts-expect-error entry must be a path string
new MetaScriptPlugin({ entry: 123 });
new MetaScriptPlugin({ entry: ["a.ms", "b.jms"] as const, sourceDeclarations: {outDir:"editor-types", rootDir:"src"} });
// @ts-expect-error declarations must be boolean
new MetaScriptPlugin({ entry: "main.ms", declaration: "yes" });
`);
	const roots = [fileURLToPath(file), ...["compilerCore", "index", "rollup", "webpack"].map(name => fileURLToPath(new URL(`./${name}.d.ts`, import.meta.url)))];
	const program = ts.createProgram(roots, {
		strict: true, noEmit: true, skipLibCheck: false, module: ts.ModuleKind.NodeNext,
		moduleResolution: ts.ModuleResolutionKind.NodeNext, target: ts.ScriptTarget.ES2022, types: [],
	});
	const diagnostics = ts.getPreEmitDiagnostics(program);
	assert.deepEqual(diagnostics.map(diagnostic => ts.flattenDiagnosticMessageText(diagnostic.messageText, "\n")), []);
});

test("relative compiler paths track the executable used by the shared core", t => {
	const f = fixture(t);
	const compiler = fakeCompiler(f.root, new MetaScriptPlugin({ ...f.settings, msc: relative(process.cwd(), f.settings.msc) }));
	const g = generation(compiler);
	assert.deepEqual(g.compilation.errors, []);
	assert.ok(g.compilation.buildDependencies.has(f.settings.msc));
	assert.equal(f.calls(), 1);
});

test("webpack source-only publishing invalidates immediately and recovers in the same compiler", t => {
 const f = fixture(t);
 f.state.manifest.sourceDeclarationRoot = "_source_declarations";
 f.state.manifest.sourceDeclarationPackage = "_source_declarations/package.json";
 f.state.manifest.sourceDeclarations = [{source:f.entry,out:"_source_declarations/main.d.ms.ts"}];
 f.state.files["_source_declarations/main.d.ms.ts"] = "export declare const value: number;";
 f.state.files["_source_declarations/package.json"] = '{"type":"module"}'; f.save();
 const plugin = new MetaScriptPlugin({...f.settings,declaration:false,sourceDeclarations:{outDir:"editor-types"}});
 const compiler = {context:f.root, hooks:{thisCompilation:new Hook(),invalid:new Hook(),shutdown:new Hook(),watchClose:new Hook()},webpack:fakeCompiler(f.root,new MetaScriptPlugin(f.settings)).webpack};
 plugin.apply(compiler);
 const file = join(f.root,"editor-types/main.d.ms.ts");
 let g = generation(compiler); assert.deepEqual(g.compilation.errors,[]); assert.ok(existsSync(file));
 g.compilation.hooks.processAssets.call(); assert.equal(g.assets.size,0);
 compiler.hooks.invalid.call(f.dependency); assert.equal(existsSync(file),false);
 f.state.fail = true; f.save(); g = generation(compiler); assert.match(g.compilation.errors[0].message,/diagnostic/); assert.equal(existsSync(file),false);
 f.state.fail = false; f.save(); g = generation(compiler); assert.deepEqual(g.compilation.errors,[]); assert.ok(existsSync(file));
 compiler.hooks.shutdown.call(); assert.ok(existsSync(file)); assert.equal(existsSync(join(f.root,"editor-types/.msc-source-lease")),false);
});

function sourceSettings(f) {
 f.state.manifest.sourceDeclarationRoot = "_source_declarations";
 f.state.manifest.sourceDeclarationPackage = "_source_declarations/package.json";
 f.state.manifest.sourceDeclarations = [{source:f.entry,out:"_source_declarations/main.d.ms.ts"}];
 f.state.files["_source_declarations/main.d.ms.ts"] = "export declare const value: number;";
 f.state.files["_source_declarations/package.json"] = '{"type":"module"}'; f.save();
 return {...f.settings,declaration:false,sourceDeclarations:{outDir:"editor-types"}};
}

test("source watch wrapper preserves runtime ignored options and observes callbacks before invalid coalescing", t => {
 const f = fixture(t), settings = sourceSettings(f);
 const compiler = fakeCompiler(f.root, new MetaScriptPlugin(settings), {afterEnvironment:new Hook(),shutdown:new Hook()});
 compiler.watchMode = true;
 t.after(() => compiler.hooks.shutdown.call());
 let args;
 const nativeWatcher = {close() {},pause() {},getInfo() { return {}; }};
 compiler.watchFileSystem = {watch(...values) { args = values; return nativeWatcher; }};
 compiler.hooks.afterEnvironment.call();
 const file = join(f.root,"editor-types/main.d.ms.ts");
 generation(compiler); assert.ok(existsSync(file));
 for (const ignored of [/keep-this/i, ["**/keep-this/**"], "**/keep-this/**", undefined]) {
  const runtime = {aggregateTimeout:17,ignored};
  let forwarded;
  const callback = () => {};
  const result = compiler.watchFileSystem.watch([f.entry],[f.root],[],123,runtime,callback,(path,time) => {
   forwarded = [path,time];
   if (path === f.entry) assert.equal(existsSync(file),false);
  });
  assert.equal(result,nativeWatcher); assert.equal(args[3],123); assert.equal(args[4].aggregateTimeout,17); assert.equal(args[5],callback);
  assert.equal(runtime.ignored,ignored);
  assert.deepEqual(args[4].ignored.slice(0,-1), ignored === undefined ? [] : Array.isArray(ignored) ? ignored : [ignored]);
  const outputs = args[4].ignored.at(-1);
  assert.ok(outputs.test(join(f.root,"editor-types"))); assert.ok(outputs.test(join(f.root,"node_modules/.metascript/webpack-private"))); assert.equal(outputs.test(f.entry),false);
  args[6](join(f.root,"calls"),1); assert.ok(existsSync(file));
  args[6](f.entry,2); assert.deepEqual(forwarded,[f.entry,2]);
  generation(compiler); assert.ok(existsSync(file));
 }
 compiler.hooks.shutdown.call();
});

test("directory-only aggregates validate source bytes after failures and reuse unrelated or output-only snapshots", t => {
 const f = fixture(t), settings = sourceSettings(f);
 f.state.fail = true; f.save();
 const pluginCompiler = fakeCompiler(f.root, new MetaScriptPlugin(settings), {shutdown:new Hook()});
 pluginCompiler.watchMode = true;
 t.after(() => pluginCompiler.hooks.shutdown.call());
 let g = generation(pluginCompiler); assert.match(g.compilation.errors[0].message,/diagnostic/); assert.equal(f.calls(),1);
 const unknown = join(f.root,"not-yet-in-manifest.jms");
 writeFileSync(unknown,"first bytes");
 pluginCompiler.modifiedFiles = new Set([f.root]);
 g = generation(pluginCompiler); assert.match(g.compilation.errors[0].message,/diagnostic/); assert.equal(f.calls(),2);
 writeFileSync(unknown,"other bytes");
 g = generation(pluginCompiler); assert.match(g.compilation.errors[0].message,/diagnostic/); assert.equal(f.calls(),3);
 writeFileSync(join(f.root,"unrelated.txt"),"not a source");
 g = generation(pluginCompiler); assert.match(g.compilation.errors[0].message,/diagnostic/); assert.equal(f.calls(),3);
 f.state.fail = false; f.save(); writeFileSync(unknown,"valid bytes");
 g = generation(pluginCompiler); assert.deepEqual(g.compilation.errors,[]); assert.equal(f.calls(),4);
 writeFileSync(join(f.root,"editor-types/ignored.jms"),"owned output");
 g = generation(pluginCompiler); assert.deepEqual(g.compilation.errors,[]); assert.equal(f.calls(),4);
 assert.ok(existsSync(join(f.root,"editor-types/main.d.ms.ts")));
 rmSync(unknown);
 g = generation(pluginCompiler); assert.deepEqual(g.compilation.errors,[]); assert.equal(f.calls(),5);
});

test("real webpack watch recovers missing new imports, deletion and restoration without output feedback", {skip:unavailable,timeout:15000}, async t => {
 const {watchTestQueue} = await import("./watchTestQueue.js");
 const f = fixture(t);
 const missing = join(f.root,"new.jms"); f.state.required = missing; f.state.manifest.dependencies.push(missing);
 f.state.manifest.sourceDeclarationRoot = "_source_declarations";
 f.state.manifest.sourceDeclarationPackage = "_source_declarations/package.json";
 f.state.manifest.sourceDeclarations = [{source:f.entry,out:"_source_declarations/main.d.ms.ts"}];
 f.state.files["_source_declarations/main.d.ms.ts"] = "export declare const value: number;";
 f.state.files["_source_declarations/package.json"] = '{"type":"module"}'; f.save();
 const plugin = new MetaScriptPlugin({...f.settings,declaration:false,sourceDeclarations:{outDir:"editor-types"}});
 const compiler = webpack(nativeConfig(f,plugin));
 memoryOutput(compiler);
 const queue = watchTestQueue(); const invalid = [];
 compiler.hooks.invalid.tap("test-observer",file => invalid.push(file));
 const events = [];
 const watching = compiler.watch({aggregateTimeout:10,ignored:/do-not-watch/},(error,stats) => { events.push({calls:f.calls(),invalid:[...invalid],modified:[...(compiler.modifiedFiles ?? [])],missing:existsSync(missing),types:existsSync(join(f.root,"editor-types/main.d.ms.ts")),errors:stats?.toString({all:false,errors:true})}); queue.push({error,stats}); });
 t.after(() => t.diagnostic(JSON.stringify(events)));
 t.after(() => close(compiler));
 let result = await queue.next(); assert.equal(result.error,null); assert.equal(result.stats.hasErrors(),true);
 const file = join(f.root,"editor-types/main.d.ms.ts"); assert.equal(existsSync(file),false);
 writeFileSync(missing,"new type"); result = await queue.next(); assert.equal(result.error,null); assert.equal(result.stats.hasErrors(),false); assert.ok(existsSync(file));
 rmSync(missing); result = await queue.next(); assert.equal(result.stats.hasErrors(),true); assert.equal(existsSync(file),false);
 writeFileSync(missing,"restored type"); result = await queue.next(); assert.equal(result.stats.hasErrors(),false); assert.ok(existsSync(file));
 await new Promise((resolve,reject) => watching.close(error => error ? reject(error) : resolve()));
 await close(compiler);
 assert.equal(f.calls(),4); assert.equal(queue.pending,0);
 assert.equal(invalid.some(file => file.includes("editor-types") || file.includes(".metascript")),false);
 assert.ok(existsSync(file)); assert.equal(existsSync(join(f.root,"editor-types/.msc-source-lease")),false);
});

test("real webpack watch restart reacquires source lease on the same compiler", {skip:unavailable,timeout:15000}, async t => {
 const {watchTestQueue} = await import("./watchTestQueue.js");
 const f = fixture(t), settings = sourceSettings(f);
 const compiler = webpack(nativeConfig(f,new MetaScriptPlugin(settings)));
 memoryOutput(compiler);
 const queue = watchTestQueue();
 let watching;
 const stop = async () => {
  if (!watching) return;
  await new Promise((resolve,reject) => watching.close(error => error ? reject(error) : resolve()));
  watching = null;
 };
 t.after(async () => { await stop(); await close(compiler); });
 const start = () => { watching = compiler.watch({aggregateTimeout:10,ignored:/do-not-watch/},(error,stats) => queue.push({error,stats})); };
 const successful = async () => {
  const {error,stats} = await queue.next();
  assert.ifError(error);
  assert.equal(stats.hasErrors(),false,stats.toString({all:false,errors:true}));
  assert.equal(stats.compilation.getAssets().some(asset => asset.name.endsWith(".d.ts")),false);
 };
 const file = join(f.root,"editor-types/main.d.ms.ts");
 const lease = join(f.root,"editor-types/.msc-source-lease");
 start(); await successful();
 const owner = JSON.parse(readFileSync(join(lease,"owner.json"),"utf8"));
 assert.ok(existsSync(file)); assert.equal(f.calls(),1);
 await stop();
 assert.equal(existsSync(lease),false); assert.ok(existsSync(file));
 start(); await successful();
 const nextOwner = JSON.parse(readFileSync(join(lease,"owner.json"),"utf8"));
 assert.equal(nextOwner.pid,process.pid); assert.notEqual(nextOwner.token,owner.token);
 assert.ok(existsSync(file)); assert.equal(f.calls(),2);
 await stop();
 assert.equal(existsSync(lease),false); assert.equal(queue.pending,0);
});
