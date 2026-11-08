import assert from "node:assert/strict";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, relative, resolve } from "node:path";
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
	assert.ok(g.compilation.fileDependencies.has(f.settings.msc));
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
	assert.ok(g.compilation.fileDependencies.has(f.settings.msc));
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

// macOS watchpack also wakes on the fixture's call counter and webpack's own bundle, which sit
// in the watched root; such a generation recompiles nothing, and the `invalid` check proves
// no plugin output woke one.
const compilingGenerations = records => records.filter((record, index) => index === 0 || record.calls !== records[index - 1].calls || record.errors !== records[index - 1].errors).length;

function sourceSettings(f) {
 f.state.manifest.sourceDeclarationRoot = "_source_declarations";
 f.state.manifest.sourceDeclarationPackage = "_source_declarations/package.json";
 f.state.manifest.sourceDeclarations = [{source:f.entry,out:"_source_declarations/main.d.ms.ts"}];
 f.state.files["_source_declarations/main.d.ms.ts"] = "export declare const value: number;";
 f.state.files["_source_declarations/package.json"] = '{"type":"module"}'; f.save();
 return {...f.settings,declaration:false,sourceDeclarations:{outDir:"editor-types"}};
}

const userIgnoredShapes = [/keep-this/i, ["**/keep-this/**"], "**/keep-this/**", path => path.includes("keep-this"), undefined];

test("composed ignored separates plugin outputs, user patterns and sources in the installed watchpack", {skip:unavailable}, t => {
 const Watchpack = createRequire(webpackPath)("watchpack");
 const f = fixture(t);
 const compiler = fakeCompiler(f.root,new MetaScriptPlugin(sourceSettings(f)),{afterEnvironment:new Hook(),shutdown:new Hook()});
 t.after(() => compiler.hooks.shutdown.call());
 let options;
 compiler.watchFileSystem = {watch(...values) { options = values[4]; return {close() {}}; }};
 compiler.hooks.afterEnvironment.call();
 const owned = ["editor-types/main.d.ms.ts","editor-types/nested/main.d.jms.ts","editor-types/package.json","editor-types/.msc-source-lease","editor-types/.msc-source-lease/owner.json","editor-types/.msc-source-ledger.json","node_modules/.metascript/webpack-private","node_modules/.metascript/webpack-private/out.js"].map(path => join(f.root,path));
 const kept = [f.entry,f.dependency,f.settings.msc,join(f.root,"editor-types"),join(f.root,"editor-types/new.jms"),join(f.root,"editor-types/schema.json"),join(f.root,"node_modules/.metascript"),join(f.root,"node_modules/.metascript/late.ms")];
 for (const ignored of userIgnoredShapes) {
  compiler.watchFileSystem.watch([],[],[],0,{ignored},() => {});
  const probe = new Watchpack(options);
  const matcher = probe.watcherOptions?.ignored;
  probe.close();
  assert.ok(typeof matcher === "function" || matcher instanceof RegExp,"installed watchpack must expose its normalized ignored matcher");
  const ignores = path => typeof matcher === "function" ? matcher(path) : matcher.test(path);
  const label = String(ignored);
  for (const path of owned) assert.equal(ignores(path),true,`${label}: ${path}`);
  for (const path of kept) assert.equal(ignores(path),false,`${label}: ${path}`);
  assert.equal(ignores(join(f.root,"keep-this/user.js")),Boolean(ignored),label);
 }
});

test("glob ignored under a project path with glob characters names the watchpack it needs", t => {
 const f = fixture(t), settings = sourceSettings(f);
 const root = join(f.root,"app[1]"); mkdirSync(root);
 const compiler = fakeCompiler(root,new MetaScriptPlugin({...settings,root}),{afterEnvironment:new Hook(),shutdown:new Hook()});
 t.after(() => compiler.hooks.shutdown.call());
 compiler.watchFileSystem = {watch(...values) {
  const ignored = values[4].ignored;
  if (Array.isArray(ignored) && !ignored.every(item => typeof item === "string")) throw new TypeError("Expected a string");
  return {close() {}};
 }};
 compiler.hooks.afterEnvironment.call();
 assert.throws(() => compiler.watchFileSystem.watch([],[],[],0,{ignored:"**/keep-this/**"},() => {}),error => /glob characters/.test(error.message) && /only from 2\.6\.0/.test(error.message) && error.cause instanceof TypeError);
 for (const ignored of [/keep-this/, undefined]) assert.doesNotThrow(() => compiler.watchFileSystem.watch([],[],[],0,{ignored},() => {}));
});

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
 for (const ignored of userIgnoredShapes) {
  const runtime = {aggregateTimeout:17,ignored};
  let forwarded;
  const callback = () => {};
  const result = compiler.watchFileSystem.watch([f.entry],[f.root],[],123,runtime,callback,(path,time) => {
   forwarded = [path,time];
   if (path === f.entry) assert.equal(existsSync(file),false);
  });
  assert.equal(result,nativeWatcher); assert.equal(args[3],123); assert.equal(args[4].aggregateTimeout,17); assert.equal(args[5],callback);
  assert.equal(runtime.ignored,ignored);
  const enriched = args[4].ignored;
  if (typeof ignored === "function") assert.equal(typeof enriched,"function");
  else assert.ok(enriched instanceof RegExp || (Array.isArray(enriched) && enriched.every(item => typeof item === "string")),"watchpack before 2.6 accepts ignored only as one RegExp, a glob or a glob list");
  if (Array.isArray(enriched)) assert.deepEqual(enriched.slice(0,[ignored].flat().length),[ignored].flat());
  args[6](join(f.root,"calls"),1); assert.ok(existsSync(file));
  args[6](f.entry,2); assert.deepEqual(forwarded,[f.entry,2]);
  generation(compiler); assert.ok(existsSync(file));
 }
 compiler.hooks.shutdown.call();
});

test("source watch wrapper preserves native option identity and isolates compilers", t => {
 const f = fixture(t), plugin = new MetaScriptPlugin(sourceSettings(f));
 const ignored = Object.freeze([/keep-this/i, "**/keep-this/**"]);
 const options = Object.freeze({aggregateTimeout:17,ignored});
 const files = [f.entry], directories = [f.root], missing = [];
 const callback = () => {};
 let forwarded;
 const undelayed = (file,time) => { forwarded = [file,time]; };
 const setup = () => {
  const compiler = fakeCompiler(f.root,plugin,{afterEnvironment:new Hook()});
  let args;
  const handle = {close() {},pause() {},getInfo() { return {}; }};
  const native = {watch(...values) { assert.equal(this,native); args = values; return handle; }};
  compiler.watchFileSystem = native;
  compiler.hooks.afterEnvironment.call();
  return runtime => {
   assert.equal(compiler.watchFileSystem.watch(files,directories,missing,123,runtime,callback,undelayed),handle);
   assert.equal(args[0],files); assert.equal(args[1],directories); assert.equal(args[2],missing);
   assert.equal(args[3],123); assert.equal(args[5],callback);
   args[6](f.entry,456); assert.deepEqual(forwarded,[f.entry,456]);
   return args[4];
  };
 };
 const watch = setup();
 const first = watch(options);
 assert.notEqual(first,options);
 assert.equal(watch(options),first,"same native watch options must retain enriched identity");
 assert.equal(first.aggregateTimeout,17);
 assert.deepEqual(first.ignored.slice(0,-1),ignored);
 assert.equal(first.ignored[0],ignored[0]);
 assert.ok(first.ignored.at(-1).test(join(f.root,"editor-types/main.d.ms.ts")));
 assert.equal(first.ignored.at(-1).test(join(f.root,"editor-types")),false);
 assert.equal(first.ignored.at(-1).test(f.entry),false);
 assert.deepEqual(options,{aggregateTimeout:17,ignored:[/keep-this/i,"**/keep-this/**"]});
 const nextOptions = Object.freeze({aggregateTimeout:23,ignored:"**/other/**"});
 const next = watch(nextOptions);
 assert.notEqual(next,first); assert.equal(watch(nextOptions),next);
 assert.equal(next.aggregateTimeout,23); assert.equal(next.ignored[0],nextOptions.ignored);
 const otherWatch = setup();
 const other = otherWatch(options);
 assert.notEqual(other,first); assert.equal(otherWatch(options),other);
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
 writeFileSync(join(f.root,"editor-types/ignored.d.jms.ts"),"owned output");
 g = generation(pluginCompiler); assert.deepEqual(g.compilation.errors,[]); assert.equal(f.calls(),4);
 assert.ok(existsSync(join(f.root,"editor-types/main.d.ms.ts")));
 rmSync(unknown);
 g = generation(pluginCompiler); assert.deepEqual(g.compilation.errors,[]); assert.equal(f.calls(),5);
});

test("a source reported again after its bytes compiled reuses the snapshot, while controls still recompile", t => {
 const f = fixture(t), settings = sourceSettings(f);
 const data = join(f.root,"schema.json"); writeFileSync(data,"{}"); f.state.manifest.dependencies.push(data); f.save();
 const compiler = fakeCompiler(f.root,new MetaScriptPlugin(settings),{invalid:new Hook(),shutdown:new Hook()});
 compiler.watchMode = true; t.after(() => compiler.hooks.shutdown.call());
 const sidecar = join(f.root,"editor-types/main.d.ms.ts");
 let g = generation(compiler); assert.deepEqual(g.compilation.errors,[]); assert.equal(f.calls(),1);
 writeFileSync(f.entry,"edited source"); compiler.modifiedFiles = new Set([f.root]);
 g = generation(compiler); assert.deepEqual(g.compilation.errors,[]); assert.equal(f.calls(),2);
 compiler.hooks.invalid.call(f.entry); assert.equal(existsSync(sidecar),false);
 compiler.modifiedFiles = new Set([f.root,f.entry]);
 g = generation(compiler); assert.deepEqual(g.compilation.errors,[]); assert.equal(f.calls(),2); assert.ok(existsSync(sidecar));
 writeFileSync(f.entry,"newer source"); compiler.hooks.invalid.call(f.entry);
 g = generation(compiler); assert.equal(f.calls(),3); assert.ok(existsSync(sidecar));
 writeFileSync(data,'{"changed":true}'); compiler.hooks.invalid.call(data); compiler.modifiedFiles = new Set([f.root]);
 g = generation(compiler); assert.deepEqual(g.compilation.errors,[]); assert.equal(f.calls(),4); assert.ok(existsSync(sidecar));
 compiler.hooks.invalid.call(undefined); compiler.modifiedFiles = new Set([f.root]);
 g = generation(compiler); assert.equal(f.calls(),5);
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

for (const declarationDir of ["editor-types", "."]) test(`webpack directory inventory retains MS/JMS under owned prefixes (${declarationDir})`, t => {
 const f = fixture(t), settings = sourceSettings(f);
 settings.outDir = "workspace"; settings.sourceDeclarations.outDir = declarationDir;
 const compiler = fakeCompiler(f.root,new MetaScriptPlugin(settings),{shutdown:new Hook()});
 compiler.watchMode = true; t.after(() => compiler.hooks.shutdown.call());
 let g = generation(compiler); assert.deepEqual(g.compilation.errors,[]); let calls = f.calls();
 compiler.modifiedFiles = new Set([f.root]);
 for (const prefix of [declarationDir,"workspace"]) {
  const dir = join(f.root,prefix); mkdirSync(dir,{recursive:true});
  const source = join(dir,"unknown.jms");
  writeFileSync(source,"first source"); g = generation(compiler); assert.deepEqual(g.compilation.errors,[]); assert.equal(f.calls(),++calls);
  writeFileSync(source,"other source"); generation(compiler); assert.equal(f.calls(),++calls);
  f.state.fail = true; f.save(); writeFileSync(source,"invalid source");
  g = generation(compiler); assert.match(g.compilation.errors[0].message,/diagnostic/); assert.equal(f.calls(),++calls);
  f.state.fail = false; f.save(); writeFileSync(source,"restored source");
  g = generation(compiler); assert.deepEqual(g.compilation.errors,[]); assert.equal(f.calls(),++calls);
  rmSync(source); generation(compiler); assert.equal(f.calls(),++calls);
 }
 const generated = join(f.root,declarationDir,"main.d.ms.ts");
 writeFileSync(generated,"external generated-file edit"); generation(compiler); assert.equal(f.calls(),calls);
});

for (const prefix of ["editor-types", "workspace"]) test(`webpack exact compiler and JSON controls precede ${prefix} ownership`, t => {
 const f = fixture(t), settings = sourceSettings(f);
 settings.outDir = "workspace";
 const dir = join(f.root,prefix); mkdirSync(dir,{recursive:true});
 settings.msc = join(dir,"fake-msc.cjs");
 writeFileSync(settings.msc,readFileSync(f.settings.msc,"utf8").replaceAll("__dirname",JSON.stringify(f.root))); chmodSync(settings.msc,0o755);
 const data = join(dir,"schema.json"); writeFileSync(data,"{}"); f.state.manifest.dependencies.push(data); f.save();
 const compiler = fakeCompiler(f.root,new MetaScriptPlugin(settings),{invalid:new Hook(),shutdown:new Hook()});
 compiler.watchMode = true; t.after(() => compiler.hooks.shutdown.call());
 let g = generation(compiler); assert.deepEqual(g.compilation.errors,[]);
 const sidecar = join(f.root,"editor-types/main.d.ms.ts"); let calls = f.calls();
 assert.ok(g.compilation.fileDependencies.has(settings.msc)); assert.ok(g.compilation.fileDependencies.has(data));
 for (const file of [settings.msc,data]) {
  compiler.modifiedFiles = new Set([file]); compiler.hooks.invalid.call(file); assert.equal(existsSync(sidecar),false);
  g = generation(compiler); assert.deepEqual(g.compilation.errors,[]); assert.equal(f.calls(),++calls);
  f.state.fail = true; f.save(); compiler.hooks.invalid.call(file);
  g = generation(compiler); assert.match(g.compilation.errors[0].message,/diagnostic/); assert.equal(f.calls(),++calls); assert.equal(existsSync(sidecar),false);
  f.state.fail = false; f.save(); compiler.hooks.invalid.call(file);
  g = generation(compiler); assert.deepEqual(g.compilation.errors,[]); assert.equal(f.calls(),++calls); assert.ok(existsSync(sidecar));
 }
});

test("webpack explicit compiler outside context is an exact live file dependency, not a source root", t => {
 const f = fixture(t), settings = sourceSettings(f);
 const external = canonicalPath(mkdtempSync(join(tmpdir(),"msc external compiler ")));
 t.after(() => rmSync(external,{recursive:true,force:true}));
 settings.msc = join(external,"fake-msc.cjs");
 writeFileSync(settings.msc,readFileSync(f.settings.msc,"utf8").replaceAll("__dirname",JSON.stringify(f.root))); chmodSync(settings.msc,0o755);
 const compiler = fakeCompiler(f.root,new MetaScriptPlugin(settings),{shutdown:new Hook()});
 t.after(() => compiler.hooks.shutdown.call());
 const g = generation(compiler); assert.deepEqual(g.compilation.errors,[]);
 assert.ok(g.compilation.fileDependencies.has(settings.msc)); assert.ok(g.compilation.buildDependencies.has(settings.msc));
 assert.equal(g.compilation.contextDependencies.has(external),false);
});


test("owned-control native colocated source declarations retain MS/JMS lifecycle without feedback", {skip:unavailable,timeout:15000}, async t => {
 const {watchTestQueue} = await import("./watchTestQueue.js");
 const f = fixture(t), settings = sourceSettings(f);
 settings.sourceDeclarations.outDir = "."; settings.outDir = "workspace";
 const compiler = webpack(nativeConfig(f,new MetaScriptPlugin(settings)));
 const queue = watchTestQueue(), arms = watchTestQueue(), records = [], invalid = [];
 let stage = {name:"initial",file:null,calls:1}, generationNumber = 0, input;
 compiler.hooks.watchRun.tap("OwnedControlProbe", current => {
  input = {generation:++generationNumber,stage:{...stage},files:[...(current.modifiedFiles ?? []),...(current.removedFiles ?? [])]};
 });
 compiler.hooks.invalid.tap("OwnedControlProbe",file => invalid.push(file));
 const nativeWatch = compiler.watchFileSystem.watch;
 compiler.watchFileSystem.watch = function(...args) {
  const handle = nativeWatch.apply(this,args); arms.push(generationNumber); return handle;
 };
 const watching = compiler.watch({aggregateTimeout:10},(error,stats) => {
  const record = {input,calls:f.calls(),error:error?.message,errors:stats?.hasErrors(),detail:stats?.toString({all:false,errors:true})};
  records.push(record); queue.push({error,stats,record});
 });
 let closed = false;
 const stop = async () => { if (!closed) { closed = true; await new Promise((resolve,reject) => watching.close(error => error ? reject(error) : resolve())); await close(compiler); } };
 t.after(stop); t.after(() => t.diagnostic(JSON.stringify({nativeColocation:true,records,invalid,calls:f.calls()})));
 const next = async errors => {
  while (true) {
   const value = await queue.next(); assert.ifError(value.error);
   const r = value.record;
   if (r.input.stage.name !== stage.name) continue;
   if (stage.file && !r.input.files.includes(stage.file) && !(stage.context && r.input.files.includes(f.root))) continue;
   if (r.calls < stage.calls) continue;
   assert.equal(r.calls,stage.calls); assert.equal(value.stats.hasErrors(),errors,r.detail);
   while ((await arms.next()) < r.input.generation) {}
   return value;
  }
 };
 const edit = async (name,file,action,errors=false,context=false) => {
  stage = {name,file,calls:f.calls()+1,context}; action(); await next(errors);
 };
 try {
  await next(false); const sidecar = join(f.root,"main.d.ms.ts"); assert.ok(existsSync(sidecar));
  await edit("known-ms",f.entry,() => writeFileSync(f.entry,"edited source"));
  const unknown = join(f.root,"new.jms");
  await edit("new-jms",unknown,() => writeFileSync(unknown,"new source"),false,true);
  await edit("edit-jms",unknown,() => writeFileSync(unknown,"other source"),false,true);
  await edit("delete-known",f.dependency,() => rmSync(f.dependency),true); assert.equal(existsSync(sidecar),false);
  await edit("restore-known",f.dependency,() => writeFileSync(f.dependency,"restored source")); assert.ok(existsSync(sidecar));
  f.state.fail = true; f.save();
  await edit("source-error",f.entry,() => writeFileSync(f.entry,"invalid source"),true); assert.equal(existsSync(sidecar),false);
  f.state.fail = false; f.save();
  await edit("source-recovery",f.entry,() => writeFileSync(f.entry,"valid source")); assert.ok(existsSync(sidecar));
  await edit("delete-new",unknown,() => rmSync(unknown),false,true);
  await stop();
  assert.equal(f.calls(),9); assert.equal(compilingGenerations(records),9); assert.equal(queue.pending,0);
  assert.equal(invalid.some(file => file && (/\.d\.(?:ms\.ts|jms\.ts|ts)$/.test(file) || file.includes("workspace/") || file.includes(".msc-source-"))),false);
  assert.equal(existsSync(join(f.root,".msc-source-lease")),false);
 } finally { await stop(); }
});

for (const prefix of ["editor-types","workspace"]) test(`owned-control native external compiler and ${prefix} JSON remain exact and update runtime`, {skip:unavailable,timeout:15000}, async t => {
 const {watchTestQueue} = await import("./watchTestQueue.js");
 const f = fixture(t), settings = sourceSettings(f); settings.outDir = "workspace";
 const external = canonicalPath(mkdtempSync(join(tmpdir(),"owned external compiler ")));
 t.after(() => rmSync(external,{recursive:true,force:true}));
 settings.msc = join(external,"fake-msc.cjs");
 const originalCompiler = readFileSync(f.settings.msc,"utf8").replaceAll("__dirname",JSON.stringify(f.root));
 writeFileSync(settings.msc,originalCompiler); chmodSync(settings.msc,0o755);
 mkdirSync(join(f.root,prefix),{recursive:true}); const data = join(f.root,prefix,"schema.json");
 writeFileSync(data,"{}"); f.state.manifest.dependencies.push(data); f.save();
 const compiler = webpack(nativeConfig(f,new MetaScriptPlugin(settings),{output:{path:join(f.root,"dist"),filename:"bundle.cjs",library:{type:"commonjs2"}}}));
 const queue = watchTestQueue(), arms = watchTestQueue(), records = [], watches = [], invalid = [];
 let stage = {name:"initial",file:null,calls:1}, generationNumber = 0, input;
 compiler.hooks.watchRun.tap("OwnedControlProbe",current => {
  input = {generation:++generationNumber,stage:{...stage},files:[...(current.modifiedFiles ?? []),...(current.removedFiles ?? [])]};
 });
 compiler.hooks.invalid.tap("OwnedControlProbe",file => invalid.push(file));
 const nativeWatch = compiler.watchFileSystem.watch;
 compiler.watchFileSystem.watch = function(files,directories,...args) {
  watches.push({files:[...files],directories:[...directories]});
  const handle = nativeWatch.call(this,files,directories,...args); arms.push(generationNumber); return handle;
 };
 const watching = compiler.watch({aggregateTimeout:10},(error,stats) => {
  const record = {input,calls:f.calls(),error:error?.message,errors:stats?.hasErrors(),detail:stats?.toString({all:false,errors:true})};
  records.push(record); queue.push({error,stats,record});
 });
 let closed = false;
 const stop = async () => { if (!closed) { closed = true; await new Promise((resolve,reject) => watching.close(error => error ? reject(error) : resolve())); await close(compiler); } };
 t.after(stop); t.after(() => t.diagnostic(JSON.stringify({nativeControl:prefix,records,watches,invalid,calls:f.calls()})));
 const next = async (errors=false,value=1) => {
  while (true) {
   const item = await queue.next(); assert.ifError(item.error); const r = item.record;
   if (r.input.stage.name !== stage.name || (stage.file && !r.input.files.includes(stage.file))) continue;
   assert.equal(r.calls,stage.calls); assert.equal(item.stats.hasErrors(),errors,r.detail);
   while ((await arms.next()) < r.input.generation) {}
   if (!errors) {
    const result = {exports:{}};
    new Function("module","exports",readFileSync(join(f.root,"dist/bundle.cjs"),"utf8"))(result,result.exports);
    assert.equal(result.exports.value,value);
   }
   return item;
  }
 };
 const edit = async (name,file,action,errors=false,value=1) => { stage={name,file,calls:f.calls()+1}; action(); await next(errors,value); };
 try {
  await next();
  for (const watch of watches) { assert.ok(watch.files.includes(settings.msc)); assert.equal(watch.directories.includes(external),false); assert.equal(watch.directories.includes(dirname(external)),false); }
  await edit("json-control",data,() => writeFileSync(data,'{"changed":true}'));
  const changedCompiler = originalCompiler.replace("fs.writeFileSync(file, text);",'fs.writeFileSync(file, name === "nested/main.js" ? text.replace("value = 1", "value = 2") : text);');
  assert.notEqual(changedCompiler,originalCompiler);
  await edit("compiler-only",settings.msc,() => writeFileSync(settings.msc,changedCompiler),false,2);
  const sidecar = join(f.root,"editor-types/main.d.ms.ts");
  f.state.fail = true; f.save(); await edit("error-control",data,() => writeFileSync(data,'{"fail":true}'),true); assert.equal(existsSync(sidecar),false);
  f.state.fail = false; f.save(); await edit("recovery-control",data,() => writeFileSync(data,'{"restored":true}'),false,2); assert.ok(existsSync(sidecar));
  await edit("source-barrier",f.entry,() => writeFileSync(f.entry,"barrier source"),false,2);
  await stop(); assert.equal(f.calls(),6); assert.equal(compilingGenerations(records),6); assert.equal(queue.pending,0);
  assert.equal(invalid.some(file => file && (/\.d\.(?:ms\.ts|jms\.ts|ts)$/.test(file) || file.includes(".msc-source-"))),false);
  assert.equal(existsSync(join(f.root,"editor-types/.msc-source-lease")),false);
 } finally { await stop(); }
});
