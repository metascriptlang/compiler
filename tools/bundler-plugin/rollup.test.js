import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { createRequire } from "node:module";
import { createInterface } from "node:readline";
import { pathToFileURL } from "node:url";
import { test } from "node:test";
import metascript from "./rollup.js";
import { canonicalPath } from "./compilerCore.js";

function fixture(t, options = {}) {
	const root = canonicalPath(mkdtempSync(join(tmpdir(), "msc rollup ")));
	const callCounter = `${root}.calls.jsonl`;
	t.after(() => {
		rmSync(root, { recursive: true, force: true });
		rmSync(callCounter, { force: true });
	});
	const entry = join(root, "main.ms");
	const dependency = join(root, "types.jms");
	writeFileSync(entry, "source");
	writeFileSync(dependency, "type source");
	const msc = join(root, "fake-msc.cjs");
	writeFileSync(msc, `#!/usr/bin/env node
const fs = require("node:fs");
const path = require("node:path");
const state = JSON.parse(fs.readFileSync(path.join(__dirname, "state.json"), "utf8"));
fs.appendFileSync(${JSON.stringify(callCounter)}, "call\\n");
if (state.fail || (state.required && !fs.existsSync(state.required))) { process.stderr.write("fixture compiler diagnostic"); process.exit(2); }
const out = process.argv.find(arg => arg.startsWith("--output=")).slice(9);
for (const [name, text] of Object.entries(state.files)) {
 const file = path.join(out, name);
 fs.mkdirSync(path.dirname(file), { recursive: true });
 fs.writeFileSync(file, text);
}
fs.writeFileSync(path.join(out, "_manifest.json"), JSON.stringify(state.manifest));
`);
	chmodSync(msc, 0o755);
	const state = {
		manifest: {
			entry, modules: [{ source: entry, out: "nested/main.js" }],
			instances: [], dependencies: [dependency],
			declarations: [{ source: entry, out: "nested/main.d.ts" }],
		},
		files: {
			"nested/main.js": "export const value = 1;\n//# sourceMappingURL=main.js.map\n",
			"nested/main.js.map": JSON.stringify({ version: 3, sources: ["../../../main.ms"], sourcesContent: ["source"], names: [], mappings: "AAAA" }),
			"nested/main.d.ts": "export declare const value: number;",
		},
	};
	const save = () => writeFileSync(join(root, "state.json"), JSON.stringify(state));
	save();
	const settings = { root, msc, entry: "main.ms", declaration: true, ...options };
	const plugin = metascript(settings);
	const watched = new Set();
	const assets = [];
	const context = {
		addWatchFile: file => watched.add(file),
		emitFile: asset => { assets.push(asset); return String(assets.length); },
	};
	const calls = () => existsSync(callCounter) ? readFileSync(callCounter, "utf8").trim().split("\n").length : 0;
	return { root, entry, dependency, state, save, settings, plugin, watched, assets, context, calls };
}

test("Rollup subpath ships native types beside the Vite subpath and no default entry", () => {
	const pkg = JSON.parse(readFileSync(new URL("./package.json", import.meta.url), "utf8"));
	assert.equal(pkg.exports["."], undefined);
	assert.deepEqual(pkg.exports["./vite"], { types: "./vite.d.ts", default: "./vite.js" });
	assert.deepEqual(pkg.exports["./rollup"], { types: "./rollup.d.ts", default: "./rollup.js" });
	for (const file of ["rollup.js", "rollup.d.ts"]) assert.ok(pkg.files.includes(file));
	assert.equal(pkg.peerDependencies.rollup, ">=4");
	assert.equal(pkg.peerDependenciesMeta.rollup.optional, true);
	assert.match(readFileSync(new URL("./rollup.d.ts", import.meta.url), "utf8"), /from "rollup"/);
});

test("one compiler snapshot supplies every Rollup output and watches type-only dependencies", t => {
	const f = fixture(t);
	f.plugin.buildStart.call(f.context, { input: f.entry });
	assert.deepEqual([...f.watched].sort(), [f.entry, f.dependency, f.settings.msc].sort());
	assert.equal(f.plugin.resolveId.call(f.context, f.entry), f.entry);
	const loaded = f.plugin.load.call(f.context, f.entry);
	assert.equal(loaded.code, "export const value = 1;\n");
	assert.deepEqual(loaded.map.sources, [f.entry]);
	for (const dir of ["first", "second"]) {
		f.plugin.generateBundle.call(f.context, { format: "es", dir: join(f.root, dir) }, {}, false);
		assert.equal(existsSync(join(f.root, dir)), false);
	}
	assert.equal(f.calls(), 1);
	assert.deepEqual(f.assets, Array(2).fill({ type: "asset", fileName: "nested/main.d.ts", source: "export declare const value: number;" }));
	assert.equal("configureServer" in f.plugin, false);
	assert.equal("handleHotUpdate" in f.plugin, false);
});

test("input inference accepts one string, array or named root and explicit entry supports a JS host", t => {
	for (const input of ["main.ms", ["main.ms"], { library: "main.ms" }]) {
		const f = fixture(t, { entry: undefined });
		f.plugin.buildStart.call(f.context, { input });
		assert.equal(f.calls(), 1);
		assert.equal(f.plugin.resolveId.call(f.context, f.entry), f.entry);
	}
	const f = fixture(t);
	f.plugin.buildStart.call(f.context, { input: join(f.root, "host.js") });
	assert.equal(f.calls(), 1);
});

test("lazy source imports choose one graph root and refuse uncompiled roots or instances", t => {
	const f = fixture(t, { entry: undefined });
	f.plugin.buildStart.call(f.context, { input: join(f.root, "host.js") });
	assert.equal(f.calls(), 0);
	assert.equal(f.plugin.resolveId.call(f.context, "./main.ms", join(f.root, "host.js")), f.entry);
	assert.equal(f.calls(), 1);
	assert.throws(() => f.plugin.resolveId.call(f.context, "./types.jms", f.entry), /outside.*graph|not.*graph/);
	assert.throws(() => f.plugin.resolveId.call(f.context, `${f.entry}?instance=missing`), /instance/);
});

test("multi-entry inputs use the explicit shared compiler roots", t => {
	for (const input of [["main.ms", "types.jms"], {main:"main.ms", types:"types.jms"}]) {
		const f = fixture(t, {entry:["main.ms", "types.jms"], declaration:false});
		f.state.manifest.entries = [f.entry, f.dependency];
		f.state.manifest.modules.push({source:f.dependency,out:"types.js"});
		f.state.files["types.js"] = "export {};";
		f.save();
		f.plugin.buildStart.call(f.context, {input});
		assert.equal(f.calls(),1);
		assert.equal(f.plugin.resolveId.call(f.context, f.dependency), f.dependency);
	}
});

test("relative emitted imports, reexports and dynamic imports resolve through manifest identities", t => {
	const f = fixture(t);
	f.state.manifest.modules.push({ source: f.dependency, out: "other/types.js" });
	f.state.manifest.instances.push({ source: f.dependency, out: "_instances/types_number.js" });
	f.state.files["other/types.js"] = "export const type = 1;";
	f.state.files["_instances/types_number.js"] = "export const type = 2;";
	f.save();
	f.plugin.buildStart.call(f.context, { input: f.entry });
	const alias = join(f.root, "alias.ms");
	symlinkSync(f.entry, alias);
	assert.equal(f.plugin.resolveId.call(f.context, alias), f.entry);
	assert.equal(f.plugin.resolveId.call(f.context, "../other/types.js", f.entry), f.dependency);
	const instance = `${f.dependency}?instance=types_number`;
	assert.equal(f.plugin.resolveId.call(f.context, "../_instances/types_number.js", f.entry), instance);
	assert.equal(f.plugin.load.call(f.context, instance).code, "export const type = 2;");
	assert.equal(f.plugin.resolveId.call(f.context, "../other/types.js", instance), f.dependency);
	assert.equal(f.plugin.resolveId.call(f.context, "external-package", f.entry), null);
	assert.equal(f.plugin.resolveId.call(f.context, "../external.js", f.entry), null);
});

test("watch invalidation refuses stale output and refreshes cached source instances each generation", t => {
	const f = fixture(t);
	f.plugin.buildStart.call(f.context, { input: f.entry });
	assert.equal(f.plugin.shouldTransformCachedModule.call(f.context, { id: f.entry }), true);
	assert.equal(f.plugin.shouldTransformCachedModule.call(f.context, { id: join(f.root, "host.js") }), false);
	f.plugin.watchChange(f.dependency);
	assert.throws(() => f.plugin.generateBundle.call(f.context, { format: "es" }), /current.*snapshot|invalidated/);
	f.state.files["nested/main.js"] = "export const value = 2;";
	f.state.files["nested/main.d.ts"] = "export declare const value: 2;";
	f.save();
	f.plugin.buildStart.call(f.context, { input: f.entry });
	assert.equal(f.calls(), 2);
	assert.equal(f.plugin.load.call(f.context, f.entry).code, "export const value = 2;");
	f.plugin.generateBundle.call(f.context, { format: "es" });
	assert.equal(f.assets[0].source, "export declare const value: 2;");
});

test("failed generations expose diagnostics, retain watches and cannot publish previous declarations", t => {
	const f = fixture(t);
	f.plugin.buildStart.call(f.context, { input: f.entry });
	f.state.fail = true;
	f.save();
	assert.throws(() => f.plugin.buildStart.call(f.context, { input: f.entry }), /fixture compiler diagnostic/);
	assert.throws(() => f.plugin.load.call(f.context, f.entry), /fixture compiler diagnostic/);
	assert.throws(() => f.plugin.generateBundle.call(f.context, { format: "es" }), /fixture compiler diagnostic/);
	assert.equal(f.calls(), 2);
	assert.equal(f.watched.has(f.dependency), true);
	assert.deepEqual(f.assets, []);
	f.state.fail = false;
	f.save();
	f.plugin.buildStart.call(f.context, { input: f.entry });
	assert.equal(f.calls(), 3);
	f.plugin.generateBundle.call(f.context, { format: "es" });
	assert.equal(f.assets.length, 1);
});

test("dependency deletion keeps recovery watches without publishing stale declarations", t => {
	const f = fixture(t);
	f.plugin.buildStart.call(f.context, { input: f.entry });
	rmSync(f.dependency);
	f.plugin.watchChange(f.dependency);
	assert.throws(() => f.plugin.buildStart.call(f.context, { input: f.entry }), /existing input file/);
	assert.throws(() => f.plugin.generateBundle.call(f.context, { format: "es" }), /existing input file/);
	assert.equal(f.watched.has(f.dependency), true);
	writeFileSync(f.dependency, "restored");
	f.plugin.buildStart.call(f.context, { input: f.entry });
	f.plugin.generateBundle.call(f.context, { format: "es" });
	assert.equal(f.assets.length, 1);
});

test("a generation only emits its current declaration inventory", t => {
	const f = fixture(t);
	f.plugin.buildStart.call(f.context, { input: f.entry });
	f.plugin.generateBundle.call(f.context, { format: "es" });
	f.assets.length = 0;
	f.state.manifest.declarations[0].out = "renamed.d.ts";
	f.state.files["renamed.d.ts"] = "export declare const value: number;";
	f.save();
	f.plugin.buildStart.call(f.context, { input: f.entry });
	f.plugin.generateBundle.call(f.context, { format: "es" });
	assert.deepEqual(f.assets.map(asset => asset.fileName), ["renamed.d.ts"]);
});

test("declaration publication is opt-in and non-ES outputs are refused", t => {
	const f = fixture(t, { declaration: false, sourcemap: false });
	f.plugin.buildStart.call(f.context, { input: f.entry });
	assert.equal(f.plugin.load.call(f.context, f.entry).map, null);
	f.plugin.generateBundle.call(f.context, { format: "es" });
	assert.deepEqual(f.assets, []);
	assert.throws(() => f.plugin.outputOptions({ format: "cjs" }), /ESM|ES module/);
});

let rollupPath = process.env.ROLLUP_MODULE;
if (!rollupPath) {
	try { rollupPath = createRequire(import.meta.url).resolve("rollup"); }
	catch (error) { if (error.code !== "MODULE_NOT_FOUND") throw error; }
}
const realRollup = rollupPath ? await import(pathToFileURL(rollupPath).href) : null;
if (realRollup) await import("./vendor/watchPolicy.test.mjs");
const rollupUnavailable = realRollup ? false : "Rollup is not provisioned; hook fixtures are not bundler acceptance";

test("real Rollup generates JS/maps and declarations for every in-memory ES output", { skip: rollupUnavailable }, async t => {
	const f = fixture(t);
	f.state.manifest.modules.push({ source: f.dependency, out: "other/types.js" });
	f.state.manifest.instances.push({ source: f.dependency, out: "_instances/types_number.js" });
	f.state.files["other/types.js"] = "export const normal = 1;";
	f.state.files["_instances/types_number.js"] = "export const special = 2;";
	f.state.files["nested/main.js.map"] = JSON.stringify({ version: 3, sources: ["../../../main.ms"], sourcesContent: ["source"], names: [], mappings: "AAAA;AAAA;AAAA;AAAA;AAAA" });
	f.state.files["nested/main.js"] = `import { normal } from "../other/types.js";
import { special } from "../_instances/types_number.js";
export { normal } from "../other/types.js";
export const value = normal + special;
export async function dynamic() { return (await import("../_instances/types_number.js")).special; }`;
	f.save();
	const bundle = await realRollup.rollup({ input: f.entry, plugins: [f.plugin] });
	t.after(() => bundle.close());
	assert.ok(bundle.watchFiles.includes(f.dependency));
	for (const name of ["first", "second"]) {
		const dir = join(f.root, name);
		const { output } = await bundle.generate({ format: "es", dir, inlineDynamicImports: true, sourcemap: true });
		const asset = output.find(item => item.fileName === "nested/main.d.ts");
		assert.equal(asset.source, f.state.files["nested/main.d.ts"]);
		const chunk = output.find(item => item.type === "chunk" && item.isEntry);
		assert.ok(chunk.map.sources.some(source => source.endsWith("main.ms")));
		const runtime = await import(`data:text/javascript;base64,${Buffer.from(chunk.code).toString("base64")}`);
		assert.equal(runtime.value, 3);
		assert.equal(await runtime.dynamic(), 2);
		assert.equal(existsSync(dir), false);
	}
	assert.equal(f.calls(), 1);
});

test("real Rollup cache generations refresh type-only edits, drop assets and recover after errors", { skip: rollupUnavailable }, async t => {
	const f = fixture(t);
	let bundle = await realRollup.rollup({ input: f.entry, plugins: [f.plugin] });
	const initial = await bundle.generate({ format: "es" });
	assert.equal(initial.output.filter(item => item.type === "asset").length, 1);
	let cache = bundle.cache;
	await bundle.close();
	f.state.files["nested/main.js"] = "export const value = 2;";
	f.state.files["nested/main.d.ts"] = "export declare const value: 2;";
	f.save();
	writeFileSync(f.dependency, "new type source");
	f.plugin.watchChange(f.dependency);
	bundle = await realRollup.rollup({ input: f.entry, cache, plugins: [f.plugin] });
	let output = (await bundle.generate({ format: "es" })).output;
	assert.match(output.find(item => item.type === "chunk").code, /value = 2/);
	assert.equal(output.find(item => item.type === "asset").source, "export declare const value: 2;");
	cache = bundle.cache;
	await bundle.close();
	f.state.fail = true;
	f.save();
	await assert.rejects(realRollup.rollup({ input: f.entry, cache, plugins: [f.plugin] }), /fixture compiler diagnostic/);
	f.state.fail = false;
	f.state.manifest.declarations[0].out = "renamed.d.ts";
	f.state.files["renamed.d.ts"] = "export declare const value: 2;";
	f.save();
	bundle = await realRollup.rollup({ input: f.entry, cache, plugins: [f.plugin] });
	t.after(() => bundle.close());
	output = (await bundle.generate({ format: "es" })).output;
	assert.deepEqual(output.filter(item => item.type === "asset").map(item => item.fileName), ["renamed.d.ts"]);
	assert.equal(f.calls(), 4);
});

test("Rollup source publisher keeps a watch lifetime lease across failed generations", t => {
 const f = fixture(t, {declaration:false,sourceDeclarations:{outDir:"editor-types"}});
 f.state.manifest.sourceDeclarationRoot = "_source_declarations";
 f.state.manifest.sourceDeclarationPackage = "_source_declarations/package.json";
 f.state.manifest.sourceDeclarations = [{source:f.entry,out:"_source_declarations/main.d.ms.ts"}];
 f.state.files["_source_declarations/main.d.ms.ts"] = "export declare const value: number;";
 f.state.files["_source_declarations/package.json"] = '{"type":"module"}'; f.save();
 const file = join(f.root,"editor-types/main.d.ms.ts");
 f.plugin.buildStart.call(f.context,{input:f.entry}); assert.ok(existsSync(file));
 f.plugin.generateBundle.call(f.context); assert.deepEqual(f.assets,[]);
 f.plugin.closeBundle.call({meta:{watchMode:true}});
 assert.ok(existsSync(join(f.root,"editor-types/.msc-source-lease")));
 f.plugin.watchChange(f.dependency); assert.equal(existsSync(file),false);
 f.state.fail = true; f.save(); assert.throws(() => f.plugin.buildStart.call(f.context,{input:f.entry}),/diagnostic/);
 assert.equal(existsSync(file),false);
 f.state.fail = false; f.save(); f.plugin.buildStart.call(f.context,{input:f.entry}); assert.ok(existsSync(file));
 f.plugin.closeWatcher(); assert.equal(existsSync(join(f.root,"editor-types/.msc-source-lease")),false); assert.ok(existsSync(file));
});

test("Rollup output-only watch generations reuse successful snapshots and retain failed diagnostics", t => {
 const f = fixture(t, {declaration:false,sourceDeclarations:{outDir:"editor-types"}});
 f.context.meta = {watchMode:true};
 f.state.manifest.sourceDeclarationRoot = "_source_declarations";
 f.state.manifest.sourceDeclarationPackage = "_source_declarations/package.json";
 f.state.manifest.sourceDeclarations = [{source:f.entry,out:"_source_declarations/main.d.ms.ts"}];
 f.state.files["_source_declarations/main.d.ms.ts"] = "export declare const value: number;";
 f.state.files["_source_declarations/package.json"] = '{"type":"module"}'; f.save();
 t.after(() => f.plugin.closeWatcher());
 const build = () => f.plugin.buildStart.call(f.context,{input:f.entry});
 const file = join(f.root,"editor-types/main.d.ms.ts");
 build(); assert.equal(f.calls(),1); assert.ok(existsSync(file));
 for (const output of [file,join(f.root,"node_modules/.metascript/private.js"),join(f.root,"unrelated.txt")]) {
  f.plugin.watchChange(output); build(); assert.equal(f.calls(),1); assert.ok(existsSync(file));
 }
 f.plugin.watchChange(f.dependency); assert.equal(existsSync(file),false);
 f.state.fail = true; f.save(); assert.throws(build,/diagnostic/); assert.equal(f.calls(),2);
 f.plugin.watchChange(file); assert.throws(build,/diagnostic/); assert.equal(f.calls(),2); assert.equal(existsSync(file),false);
 f.state.fail = false; f.save(); f.plugin.watchChange(f.dependency); build(); assert.equal(f.calls(),3); assert.ok(existsSync(file));
});

test("real Rollup watch discovers a missing new import, deletion and restoration without output feedback", {skip:rollupUnavailable,timeout:15000}, async t => {
 const {watchTestQueue} = await import("./watchTestQueue.js");
 const f = fixture(t,{declaration:false,sourceDeclarations:{outDir:"editor-types"}});
 const missing = join(f.root,"new.jms");
 f.state.required = missing; f.state.manifest.dependencies.push(missing);
 f.state.manifest.sourceDeclarationRoot = "_source_declarations";
 f.state.manifest.sourceDeclarationPackage = "_source_declarations/package.json";
 f.state.manifest.sourceDeclarations = [{source:f.entry,out:"_source_declarations/main.d.ms.ts"}];
 f.state.files["_source_declarations/main.d.ms.ts"] = "export declare const value: number;";
 f.state.files["_source_declarations/package.json"] = '{"type":"module"}'; f.save();
 const queue = watchTestQueue();
 const changes = [];
 const watcher = realRollup.watch({input:f.entry, plugins:[f.plugin,{name:"watch-observer",watchChange(id){changes.push(id);}}], output:{dir:join(f.root,"dist"),format:"es"}, watch:{skipWrite:true}});
 const events = [];
 watcher.on("event", event => { events.push({code:event.code, calls:f.calls(), watchFiles:event.error?.watchFiles}); if(event.code === "ERROR") queue.push(event); if(event.code === "BUNDLE_END") { event.result.close(); queue.push(event); } });
 t.after(() => t.diagnostic(JSON.stringify({events,changes})));
 t.after(() => watcher.close());
 assert.equal((await queue.next()).code,"ERROR");
 const file = join(f.root,"editor-types/main.d.ms.ts"); assert.equal(existsSync(file),false);
 writeFileSync(missing,"new type"); assert.equal((await queue.next()).code,"BUNDLE_END"); assert.ok(existsSync(file));
 rmSync(missing); assert.equal((await queue.next()).code,"ERROR"); assert.equal(existsSync(file),false);
 writeFileSync(missing,"restored type"); assert.equal((await queue.next()).code,"BUNDLE_END"); assert.ok(existsSync(file));
 await watcher.close();
 assert.equal(f.calls(),4); assert.equal(queue.pending,0);
 assert.ok(changes.includes(missing));
 assert.equal(changes.some(file => file.includes("editor-types") || file.includes(".metascript")),false);
 assert.ok(existsSync(file)); assert.equal(existsSync(join(f.root,"editor-types/.msc-source-lease")),false);
});

test("real Rollup watch restart recompiles offline edits and reacquires source lease", {skip:rollupUnavailable,timeout:15000}, async t => {
 const {watchTestQueue} = await import("./watchTestQueue.js");
 const f = fixture(t,{declaration:false,sourceDeclarations:{outDir:"editor-types"}});
 f.state.manifest.sourceDeclarationRoot = "_source_declarations";
 f.state.manifest.sourceDeclarationPackage = "_source_declarations/package.json";
 f.state.manifest.sourceDeclarations = [{source:f.entry,out:"_source_declarations/main.d.ms.ts"}];
 f.state.files["_source_declarations/main.d.ms.ts"] = "export declare const value: 1;";
 f.state.files["_source_declarations/package.json"] = '{"type":"module"}'; f.save();
 const queue = watchTestQueue();
 let watcher;
 const stop = async () => { if (watcher) { await watcher.close(); watcher = null; } };
 t.after(stop);
 const start = () => {
  watcher = realRollup.watch({input:f.entry,plugins:[f.plugin],output:{dir:join(f.root,"dist"),format:"es"},watch:{skipWrite:true}});
  watcher.on("event",event => { if (event.code === "ERROR" || event.code === "BUNDLE_END") queue.push(event); });
 };
 const runtime = async () => {
  const event = await queue.next();
  assert.equal(event.code,"BUNDLE_END",event.error?.message);
  try {
   const {output} = await event.result.generate({format:"es"});
   assert.equal(output.some(item => item.type === "asset"),false);
   const chunk = output.find(item => item.type === "chunk" && item.isEntry);
   return await import(`data:text/javascript;base64,${Buffer.from(chunk.code).toString("base64")}`);
  } finally { await event.result.close(); }
 };
 const file = join(f.root,"editor-types/main.d.ms.ts");
 const lease = join(f.root,"editor-types/.msc-source-lease");
 start(); assert.equal((await runtime()).value,1);
 const owner = JSON.parse(readFileSync(join(lease,"owner.json"),"utf8"));
 assert.equal(readFileSync(file,"utf8"),"export declare const value: 1;"); assert.equal(f.calls(),1);
 await stop(); assert.equal(existsSync(lease),false);
 f.state.files["nested/main.js"] = "export const value = 2;";
 f.state.files["_source_declarations/main.d.ms.ts"] = "export declare const value: 2;"; f.save();
 writeFileSync(f.entry,"offline source edit");
 start(); assert.equal((await runtime()).value,2);
 assert.equal(readFileSync(file,"utf8"),"export declare const value: 2;"); assert.equal(f.calls(),2);
 const nextOwner = JSON.parse(readFileSync(join(lease,"owner.json"),"utf8"));
 assert.equal(nextOwner.pid,process.pid); assert.notEqual(nextOwner.token,owner.token);
 await stop(); assert.equal(existsSync(lease),false); assert.equal(queue.pending,0);
});


function boundedSourceFixture(t) {
 const f = fixture(t,{declaration:false});
 const root = join(f.root,"project/src");
 const dataDir = join(f.root,"data");
 for (const dir of [root,dataDir]) mkdirSync(dir,{recursive:true});
 const entry = join(root,"main.ms");
 const data = join(dataDir,"schema.json");
 writeFileSync(entry,"source"); writeFileSync(data,"{}");
 f.state.manifest.entry = entry;
 f.state.manifest.modules = [{source:entry,out:"nested/main.js"}];
 f.state.manifest.declarations = [];
 f.state.manifest.dependencies = [data];
 f.state.manifest.sourceDeclarationRoot = "_source_declarations";
 f.state.manifest.sourceDeclarationPackage = "_source_declarations/package.json";
 f.state.manifest.sourceDeclarations = [{source:entry,out:"_source_declarations/main.d.ms.ts"}];
 f.state.files["_source_declarations/package.json"] = '{"type":"module"}';
 f.state.files["_source_declarations/main.d.ms.ts"] = "export declare const value: number;";
 f.save();
 const plugin = metascript({root,entry,msc:f.settings.msc,declaration:false,outDir:join(f.root,"generated"),sourceDeclarations:{outDir:join(f.root,"editor-types")}});
 return {...f,root,entry,data,dataDir,plugin,container:f.root,sidecar:join(f.root,"editor-types/main.d.ms.ts")};
}

test("Rollup bounds source roots separately from exact compiler watches across failures and restart", t => {
 const f = boundedSourceFixture(t);
 f.context.meta = {watchMode:true};
 t.after(() => f.plugin.closeWatcher());
 const build = () => f.plugin.buildStart.call(f.context,{input:f.entry});
 const bounds = external => {
  for (const file of [f.root,f.entry,f.settings.msc,...(external ? [f.data,f.dataDir] : [])]) assert.ok(f.watched.has(file),`missing watch ${file}`);
  assert.equal(f.watched.has(f.container),false,"compiler parent became source root");
 };
 f.state.fail = true; f.save(); assert.throws(build,/diagnostic/); bounds(false);
 f.state.fail = false; f.save(); f.plugin.watchChange(f.entry); build(); bounds(true);
 for (const file of [f.settings.msc,f.data]) {
  f.plugin.watchChange(file); assert.equal(existsSync(f.sidecar),false);
  f.state.fail = true; f.save(); f.watched.clear(); assert.throws(build,/diagnostic/); bounds(true);
  assert.equal(existsSync(f.sidecar),false);
  f.state.fail = false; f.save(); f.plugin.watchChange(file); build(); bounds(true); assert.ok(existsSync(f.sidecar));
 }
 f.plugin.closeWatcher(); f.watched.clear(); build(); bounds(true); assert.ok(existsSync(f.sidecar));
});

test("real Rollup watches bounded source roots and exact external compiler through errors and restart", {skip:rollupUnavailable,timeout:15000}, async t => {
 const {watchTestQueue} = await import("./watchTestQueue.js");
 const f = boundedSourceFixture(t);
 const queue = watchTestQueue();
 const events = [];
 const changes = [];
 let phase = "initial build";
 t.after(() => t.diagnostic(JSON.stringify({phase,events,changes,calls:f.calls()})));
 let watcher;
 const stop = async () => { if (watcher) { await watcher.close(); watcher = null; } };
 t.after(stop);
 const start = () => {
  watcher = realRollup.watch({input:f.entry,plugins:[f.plugin,{name:"bounded-watch-observer",watchChange(id){changes.push(id);}}],output:{dir:join(f.container,"dist"),format:"es"},watch:{skipWrite:true}});
  watcher.on("event",event => { events.push({code:event.code,phase,calls:f.calls()}); if (event.code === "ERROR" || event.code === "BUNDLE_END") queue.push(event); });
 };
 const bundled = async () => {
  const event = await queue.next();
  assert.equal(event.code,"BUNDLE_END",event.error?.message);
  try {
   for (const file of [f.root,f.entry,f.data,f.dataDir,f.settings.msc]) assert.ok(event.result.watchFiles.includes(file),`missing native watch ${file}`);
   assert.equal(event.result.watchFiles.includes(f.container),false,"native compiler parent became source root");
   assert.ok(existsSync(f.sidecar));
  } finally { await event.result.close(); }
 };
 start(); await bundled(); assert.equal(f.calls(),1);
 phase = "external JSON error";
 f.state.fail = true; f.save();
 writeFileSync(f.data,'{"changed":true}');
 assert.equal((await queue.next()).code,"ERROR"); assert.equal(existsSync(f.sidecar),false);
 phase = "exact compiler recovery";
 f.state.fail = false; f.save();
 writeFileSync(f.settings.msc,readFileSync(f.settings.msc,"utf8")+"\n// compiler changed\n");
 await bundled(); assert.equal(f.calls(),3);
 phase = "restart";
 await stop(); start(); await bundled(); assert.equal(f.calls(),4);
 await stop(); assert.equal(queue.pending,0);
});

test("stock Rollup observes immediate external JSON updates after initial BUNDLE_END", {skip:rollupUnavailable,timeout:15000}, async t => {
 const {watchTestQueue} = await import("./watchTestQueue.js");
 const f = boundedSourceFixture(t);
 writeFileSync(f.entry,"export const value = 1;");
 const queue = watchTestQueue();
 const events = [];
 const changes = [];
 let builds = 0;
 const inputs = [f.root,f.entry,f.data,f.dataDir,f.settings.msc];
 const watcher = realRollup.watch({input:f.entry,plugins:[{
  name:"stock-external-json-control",
  buildStart(){builds++; for (const file of inputs) this.addWatchFile(file);},
  watchChange(id){changes.push(id);},
 }],output:{dir:join(f.container,"dist"),format:"es"},watch:{skipWrite:true}});
 watcher.on("event",event => { events.push({code:event.code,builds}); if (event.code === "ERROR" || event.code === "BUNDLE_END") queue.push(event); });
 t.after(() => t.diagnostic(JSON.stringify({events,changes,builds})));
 t.after(() => watcher.close());
 const first = await queue.next();
 assert.equal(first.code,"BUNDLE_END",first.error?.message);
 try { for (const file of inputs) assert.ok(first.result.watchFiles.includes(file)); }
 finally { await first.result.close(); }
 writeFileSync(f.data,'{"changed":true}');
 const second = await queue.next();
 assert.equal(second.code,"BUNDLE_END",second.error?.message);
 await second.result.close();
 assert.equal(builds,2); assert.ok(changes.includes(f.data));
});

test("real Rollup keeps compiler parents out of native source roots across restart", {skip:rollupUnavailable,timeout:15000}, async t => {
 const {watchTestQueue} = await import("./watchTestQueue.js");
 const f = boundedSourceFixture(t);
 const queue = watchTestQueue();
 let watcher;
 const stop = async () => { if (watcher) { await watcher.close(); watcher = null; } };
 t.after(stop);
 const start = () => {
  watcher = realRollup.watch({input:f.entry,plugins:[f.plugin],output:{dir:join(f.container,"dist"),format:"es"},watch:{skipWrite:true}});
  watcher.on("event",event => { if (event.code === "ERROR" || event.code === "BUNDLE_END") queue.push(event); });
 };
 const boundary = async () => {
  const event = await queue.next();
  assert.equal(event.code,"BUNDLE_END",event.error?.message);
  try {
   for (const file of [f.root,f.entry,f.data,f.dataDir,f.settings.msc]) assert.ok(event.result.watchFiles.includes(file),`missing native watch ${file}`);
   assert.equal(event.result.watchFiles.includes(f.container),false,"native compiler parent became source root");
   assert.ok(existsSync(f.sidecar));
  } finally { await event.result.close(); }
 };
 start(); await boundary(); assert.equal(f.calls(),1);
 const lease = join(f.container,"editor-types/.msc-source-lease");
 const owner = JSON.parse(readFileSync(join(lease,"owner.json"),"utf8"));
 await stop(); assert.equal(existsSync(lease),false);
 f.state.files["nested/main.js"] = "export const value = 2;"; f.save();
 writeFileSync(f.data,'{"offline":true}');
 start(); await boundary(); assert.equal(f.calls(),2);
 assert.notEqual(JSON.parse(readFileSync(join(lease,"owner.json"),"utf8")).token,owner.token);
 await stop(); assert.equal(queue.pending,0); assert.equal(existsSync(lease),false);
});

const optionsRoot = join(tmpdir(), "msc-options-unit-root");
const watchContext = Object.freeze({ meta: Object.freeze({ watchMode: true, rollupVersion: "4.67.5+metascript.2" }) });
const outputFileStats = Object.freeze({ isDirectory: () => false });
const outputDirectoryStats = Object.freeze({ isDirectory: () => true });

for (const [name, ignored] of [
	["undefined", undefined],
	["string", join(optionsRoot, "caller-ignore")],
	["RegExp", Object.freeze(/caller-ignore/)],
	["function", Object.freeze(path => path.endsWith("caller-ignore"))],
	["frozen array", Object.freeze([join(optionsRoot, "caller-ignore"), Object.freeze(/caller-pattern/), Object.freeze(() => false)])]
]) {
	test(`public options preserves frozen caller config and ${name} ignored`, t => {
		const root = canonicalPath(mkdtempSync(join(tmpdir(), "msc rollup options ")));
		t.after(() => rmSync(root, { recursive: true, force: true }));
		mkdirSync(join(root, "editor-types"));
		const awaitWriteFinish = Object.freeze({ stabilityThreshold: 123, pollInterval: 17 });
		const chokidar = Object.freeze({ ignored, atomic: false, awaitWriteFinish, alwaysStat: true, usePolling: false, followSymlinks: false, ignoreInitial: false, cwd: root });
		const onInvalidate = () => {};
		const watch = Object.freeze({ chokidar, buildDelay: 19, skipWrite: true, clearScreen: false, onInvalidate, include: Object.freeze([/\.ms$/]), exclude: "caller-exclude" });
		const plugins = Object.freeze([]);
		const output = Object.freeze({ dir: join(root, "dist"), format: "es" });
		const inputOptions = Object.freeze({ input: join(root, "main.ms"), watch, plugins, output, treeshake: false });
		const compilerArgs = Object.freeze(["--config=compiler.json"]);
		const sourceDeclarations = Object.freeze({ outDir: "editor-types", rootDir: root });
		const adapterOptions = Object.freeze({ root, sourceDeclarations, msc: join(root, "fake-msc.cjs"), compilerArgs });
		const plugin = metascript(adapterOptions);
		const processed = plugin.options.call(watchContext, inputOptions);
		assert.notEqual(processed, inputOptions);
		assert.notEqual(processed.watch, watch);
		assert.notEqual(processed.watch.chokidar, chokidar);
		for (const [key, value] of Object.entries(inputOptions)) if (key !== "watch") assert.equal(processed[key], value);
		for (const [key, value] of Object.entries(watch)) if (key !== "chokidar") assert.equal(processed.watch[key], value);
		for (const [key, value] of Object.entries(chokidar)) if (key !== "ignored") assert.equal(processed.watch.chokidar[key], value);
		assert.equal(watch.chokidar, chokidar);
		assert.equal(chokidar.ignored, ignored);
		assert.equal(chokidar.ignoreInitial, false);
		assert.equal(adapterOptions.compilerArgs, compilerArgs);
		const expected = ignored === undefined ? [] : Array.isArray(ignored) ? [...ignored] : [ignored];
		const merged = processed.watch.chokidar.ignored;
		assert.notEqual(merged, ignored);
		assert.equal(merged.length, expected.length + 1);
		for (let index = 0; index < expected.length; index++) assert.equal(merged[index], expected[index]);
		const owned = merged.at(-1);
		assert.equal(typeof owned, "function");
		for (const path of [join(root, "editor-types/main.d.ms.ts"), join(root, "node_modules/.metascript/out.js")]) {
			assert.equal(owned(path, outputFileStats), true);
			assert.equal(owned(path), true);
		}
		assert.equal(owned(join(root, "editor-types"), outputDirectoryStats), false);
		assert.equal(owned(join(root, "node_modules"), outputDirectoryStats), true);
		assert.equal(owned(join(root, "packages/app/node_modules"), outputDirectoryStats), true);
		assert.equal(owned(join(root, "node_modules")), false, "a node_modules not created yet stays watched");
		assert.equal(owned(join(root, "node_modules/pkg/index.ms"), outputFileStats), false);
		assert.equal(owned(join(root, "editor-types")), false);
		for (const path of [inputOptions.input, join(root, "types.jms"), adapterOptions.msc, join(root, "compiler.json"), join(root, "rollup.config.js"), join(root, "state.json"), join(root, "editor-types-sibling/main.ms"), join(root, "editor-types/new.ms"), join(root, "node_modules/.metascript/new.jms")]) assert.equal(owned(path, outputFileStats), false);
		const again = plugin.options.call(watchContext, inputOptions);
		assert.equal(again.watch.chokidar.ignored.length, merged.length);
		assert.notEqual(again.watch.chokidar.ignored, merged);
		assert.equal(inputOptions.watch, watch);
	});
}

test("options hook returns null outside source-declaration watch or when watch is false", () => {
	const root = optionsRoot;
	const enabled = metascript({ root, sourceDeclarations: { outDir: "editor-types" } });
	const ordinary = metascript({ root });
	const disabled = Object.freeze({ input: join(root, "main.ms"), watch: false });
	const normal = Object.freeze({ input: join(root, "main.ms"), watch: Object.freeze({ skipWrite: true }) });
	assert.equal(enabled.options.call(watchContext, disabled), null);
	assert.equal(enabled.options.call({ meta: { watchMode: false, rollupVersion: "4.44.1" } }, normal), null);
	assert.equal(enabled.options.call({}, normal), null);
	assert.equal(ordinary.options.call({ meta: { watchMode: true, rollupVersion: "4.44.1" } }, normal), null);
});

test("options hook copies absent watch/chokidar and honors an explicit compiler workspace", () => {
	const root = optionsRoot;
	const plugin = metascript({ root, msc: join(root, "compiler-output/fake-msc.cjs"), outDir: "compiler-output", sourceDeclarations: { outDir: "editor-types" } });
	for (const input of [Object.freeze({ input: join(root, "main.ms") }), Object.freeze({ watch: Object.freeze({ skipWrite: true }) })]) {
		const processed = plugin.options.call(watchContext, input);
		assert.equal(processed.watch.chokidar.ignored.length, 1);
		const owned = processed.watch.chokidar.ignored[0];
		assert.equal(owned(join(root, "compiler-output/generated.js"), outputFileStats), true);
		assert.equal(owned(join(root, "node_modules/.metascript/not-owned.js"), outputFileStats), false);
		assert.equal(owned(join(root, "fake-msc.cjs"), outputFileStats), false);
		assert.equal(owned(join(root, "compiler-output/fake-msc.cjs"), outputFileStats), false);
		assert.equal(owned(join(root, "editor-types/main.ms"), outputFileStats), false);
	}
});

for (const rollupVersion of [undefined, "4.44.1", "4.67.5", "4.67.5+other.1"]) {
	test(`source-declaration watch refuses an unqualified host ${rollupVersion}`, () => {
		const plugin = metascript({ root: optionsRoot, sourceDeclarations: { outDir: "editor-types" } });
		assert.throws(() => plugin.options.call({ meta: { watchMode: true, rollupVersion } }, { input: "main.ms" }),
			/requires Rollup 4\.67\.5\+metascript\.2; pin the host Rollup dependency/);
	});
}

for (const [name, options, file] of [
 ["compiler beside declarations", {sourceDeclarations:{outDir:"types"},msc:join(optionsRoot,"types/compiler.cjs")}, join(optionsRoot,"types/compiler.cjs")],
 ["compiler in its workspace", {sourceDeclarations:{outDir:"types"},outDir:"generated",msc:join(optionsRoot,"generated/compiler.cjs")}, join(optionsRoot,"generated/compiler.cjs")],
 ["source beside declarations", {sourceDeclarations:{outDir:"src"}}, join(optionsRoot,"src/main.ms")]
]) {
 test(`public options retains ${name} as an input`, () => {
  const plugin = metascript({root:optionsRoot,...options});
  const owned = plugin.options.call(watchContext,{input:join(optionsRoot,"src/main.ms")}).watch.chokidar.ignored.at(-1);
  assert.equal(typeof owned === "function" ? owned(file,outputFileStats) : owned.test(file),false);
 });
}

test("public Rollup CLI watch recovers JSON errors and reloads config in one process", { skip: rollupUnavailable, timeout: 15000 }, async t => {
	const { watchTestQueue } = await import("./watchTestQueue.js");
	const packageRoot = dirname(createRequire(pathToFileURL(rollupPath)).resolve("rollup/package.json"));
	const pkg = JSON.parse(readFileSync(join(packageRoot, "package.json"), "utf8"));
	assert.equal(realRollup.VERSION, "4.67.5+metascript.2");
	assert.equal(pkg.version, realRollup.VERSION);
	assert.equal(pkg.bin.rollup, "dist/bin/rollup");
	const cli = join(packageRoot, "dist/bin/rollup");
	assert.ok(existsSync(cli));
	const root = canonicalPath(mkdtempSync(join(tmpdir(), "msc rollup cli ")));
	const project = join(root, "project");
	const entry = join(project, "main.js");
	const data = join(project, "value.json");
	const config = join(project, "rollup.config.mjs");
	const output = join(root, "out/bundle.mjs");
	const logs = [];
	const queue = watchTestQueue();
	let child, closed;
	const readers = [];
	const abort = () => {
		child?.kill("SIGKILL");
		queue.push("test aborted");
	};
	t.signal.addEventListener("abort", abort, { once: true });
	const saveConfig = offset => writeFileSync(config, `import { readFileSync } from "node:fs";
const entry = ${JSON.stringify(entry)};
const data = ${JSON.stringify(data)};
export default {
 input: entry,
 output: { file: ${JSON.stringify(output)}, format: "es" },
 watch: { clearScreen: false },
 plugins: [{
  name: "cli-json-pin",
  transform(code, id) {
   if (id !== entry) return null;
   this.addWatchFile(data);
   const { value } = JSON.parse(readFileSync(data, "utf8"));
   return { code: "export const value = " + (value + ${offset}) + ";", map: null };
  }
 }]
};
`);
	const execute = code => import(`data:text/javascript;base64,${Buffer.from(code).toString("base64")}`);
	const created = async () => assert.match(await queue.next(), /^created \.\.\/out\/bundle\.mjs in .+$/, "expected CLI created-output line");
	const runtime = async value => {
		await created();
		assert.equal((await execute(readFileSync(output, "utf8"))).value, value);
	};
	try {
		mkdirSync(project);
		writeFileSync(entry, "export const value = 0;\n");
		writeFileSync(data, '{"value":1}');
		saveConfig(0);
		child = spawn(process.execPath, [cli, "--config", config, "--watch", "--no-stdin"], {
			cwd: project,
			env: { ...process.env, NO_COLOR: "1", FORCE_COLOR: "0" },
			stdio: ["ignore", "pipe", "pipe"]
		});
		child.on("error", error => queue.push(error));
		closed = new Promise(resolve => child.once("close", (code, signal) => {
			const result = { code, signal };
			queue.push(result);
			resolve(result);
		}));
		for (const [stream, input] of [["stdout", child.stdout], ["stderr", child.stderr]]) {
			const reader = createInterface({ input, crlfDelay: Infinity });
			reader.on("error", error => queue.push(error));
			readers.push(reader);
			reader.on("line", line => {
				logs.push({ stream, line });
				if (stream === "stderr" && (/^created /.test(line) || /^\[!\]/.test(line))) queue.push(line);
			});
		}
		await created();
		writeFileSync(data, '{"value":2}');
		await runtime(2);
		assert.ok(logs.some(({ stream, line }) => stream === "stderr" && line === "rollup v4.67.5+metascript.2"));
		writeFileSync(data, "{");
		assert.match(await queue.next(), /^\[!\] \(plugin cli-json-pin\) SyntaxError: /, "expected genuine JSON parse error");
		writeFileSync(data, '{"value":3}');
		await runtime(3);
		saveConfig(10);
		await runtime(13);
		writeFileSync(config, 'throw new Error("ROLLUP_CLI_CONFIG_PIN");\n');
		assert.equal(await queue.next(), "[!] Error: ROLLUP_CLI_CONFIG_PIN", "expected config-module error");
		saveConfig(20);
		await runtime(23);
		assert.equal(queue.pending, 0, "unexpected extra CLI terminal");
	} finally {
		try {
			if (child && child.exitCode === null && child.signalCode === null) child.kill("SIGINT");
			if (closed) await closed;
		} finally {
			for (const reader of readers) reader.close();
			t.signal.removeEventListener("abort", abort);
			for (const { stream, line } of logs) t.diagnostic(`${stream}: ${line}`);
			rmSync(root, { recursive: true, force: true });
		}
	}
	assert.deepEqual(await closed, { code: 0, signal: null }, "CLI did not exit cleanly after SIGINT");
	assert.equal(queue.pending, 1, "expected exactly one queued CLI close event");
	assert.deepEqual(await queue.next(), { code: 0, signal: null });
	assert.deepEqual(logs.filter(({ stream }) => stream === "stdout"), []);
	assert.equal(logs.filter(({ stream, line }) => stream === "stderr" && /^created /.test(line)).length, 5);
	assert.equal(logs.filter(({ stream, line }) => stream === "stderr" && /^\[!\]/.test(line)).length, 2);
	assert.equal(logs.filter(({ stream, line }) => stream === "stderr" && line === "Reloading updated config...").length, 3);
});

test("native exact compiler edits alone invalidate and recover bounded source declarations", {skip:rollupUnavailable,timeout:15000}, async t => {
 const {watchTestQueue} = await import("./watchTestQueue.js");
 const f = boundedSourceFixture(t);
 const queue = watchTestQueue();
 const events = [];
 const changes = [];
 const compiler = f.settings.msc;
 const original = readFileSync(compiler,"utf8");
 const broken = original.replace("if (state.fail ||", "if (true || state.fail ||");
 assert.notEqual(broken,original);
 const inputs = [f.entry,f.data,join(f.container,"state.json")];
 const before = inputs.map(path => readFileSync(path,"utf8"));
 const watcher = realRollup.watch({input:f.entry,plugins:[f.plugin,{
  name:"exact-compiler-only-observer",
  watchChange(id){changes.push(canonicalPath(id));}
 }],output:{dir:join(f.container,"dist"),format:"es"},watch:{skipWrite:true}});
 let stopped = false;
 const stop = async () => {if (!stopped) {stopped=true;await watcher.close();}};
 t.after(stop);
 t.after(() => t.diagnostic(JSON.stringify({events,changes,calls:f.calls()})));
 watcher.on("event",event => {
  events.push({code:event.code,calls:f.calls(),error:event.error?.message});
  if(event.code==="ERROR"||event.code==="BUNDLE_END")queue.push(event);
 });
 const bundled = async () => {
  const event = await queue.next();
  assert.equal(event.code,"BUNDLE_END",event.error?.message);
  try {
   assert.ok(event.result.watchFiles.includes(compiler));
   assert.equal(event.result.watchFiles.includes(f.container),false);
   assert.ok(existsSync(f.sidecar));
  } finally {await event.result.close();}
 };
 await bundled();assert.equal(f.calls(),1);
 writeFileSync(compiler,broken);
 const error = await queue.next();
 assert.equal(error.code,"ERROR");assert.match(error.error.message,/fixture compiler diagnostic/);
 assert.equal(f.calls(),2);assert.equal(existsSync(f.sidecar),false);
 assert.deepEqual(changes,[canonicalPath(compiler)]);
 writeFileSync(compiler,original);
 await bundled();assert.equal(f.calls(),3);
 assert.deepEqual(changes,[canonicalPath(compiler),canonicalPath(compiler)]);
 assert.deepEqual(inputs.map(path=>readFileSync(path,"utf8")),before);
 assert.equal(readFileSync(compiler,"utf8"),original);
 await stop();assert.equal(queue.pending,0);
});

for (const folder of ["editor-types", "generated"]) for (const relativeEvents of [false, true]) {
 test(`native owned-prefix compiler and JSON controls in ${folder}, relative events ${relativeEvents}`, {skip:rollupUnavailable,timeout:15000}, async t => {
  const {watchTestQueue} = await import("./watchTestQueue.js");
  const f = boundedSourceFixture(t);
  const directory = join(f.container,folder);
  mkdirSync(directory,{recursive:true});
  const compiler = join(directory,"compiler.cjs");
  const data = join(directory,"schema.json");
  writeFileSync(data,'{"value":1}');
  const original = readFileSync(f.settings.msc,"utf8");
  const script = original.replace('path.join(__dirname, "state.json")', JSON.stringify(join(f.container,"state.json")))
   .replace("const out =", `const value = JSON.parse(fs.readFileSync(${JSON.stringify(data)}, "utf8")).value;
state.files["nested/main.js"] = "export const value = " + value + ";";
state.files["_source_declarations/main.d.ms.ts"] = "export declare const value: " + value + ";";
const out =`);
  assert.notEqual(script,original);
  writeFileSync(compiler,script,{mode:0o755});
  f.state.manifest.dependencies = [data];f.save();
  const plugin = metascript({root:f.root,entry:f.entry,msc:compiler,declaration:false,outDir:join(f.container,"generated"),sourceDeclarations:{outDir:join(f.container,"editor-types")}});
  const queue = watchTestQueue();
  const changes = [];
  const watcher = realRollup.watch({input:f.entry,plugins:[plugin,{
   name:"owned-prefix-controls",
   watchChange(id){changes.push(canonicalPath(resolve(relativeEvents ? f.container : process.cwd(),id)));}
  }],output:{dir:join(f.container,"dist"),format:"es"},watch:{skipWrite:true,chokidar:relativeEvents ? {cwd:f.container} : {}}});
  t.after(() => watcher.close());
  watcher.on("event",event => {if(event.code==="ERROR"||event.code==="BUNDLE_END")queue.push(event);});
  const runtime = async value => {
   const event = await queue.next();assert.equal(event.code,"BUNDLE_END",event.error?.message);
   try {
    const result = await event.result.generate({format:"es"});
    const chunk = result.output.find(item => item.type==="chunk" && item.isEntry);
    assert.equal((await import(`data:text/javascript;base64,${Buffer.from(chunk.code).toString("base64")}`)).value,value);
    assert.equal(readFileSync(f.sidecar,"utf8"),`export declare const value: ${value};`);
   } finally {await event.result.close();}
  };
  await runtime(1);assert.equal(f.calls(),1);
  writeFileSync(compiler,script.replace("if (state.fail ||","if (true || state.fail ||"));
  let event = await queue.next();assert.equal(event.code,"ERROR");assert.match(event.error.message,/fixture compiler diagnostic/);
  assert.equal(f.calls(),2);assert.equal(existsSync(f.sidecar),false);
  writeFileSync(compiler,script);await runtime(1);assert.equal(f.calls(),3);
  writeFileSync(data,'{"value":2}');await runtime(2);assert.equal(f.calls(),4);
  writeFileSync(data,"{");event = await queue.next();assert.equal(event.code,"ERROR");assert.match(event.error.message,/SyntaxError/);
  assert.equal(f.calls(),5);assert.equal(existsSync(f.sidecar),false);
  writeFileSync(data,'{"value":3}');await runtime(3);assert.equal(f.calls(),6);
  assert.deepEqual(changes,[compiler,compiler,data,data,data].map(canonicalPath));
  await watcher.close();assert.equal(queue.pending,0);
 });
}

test("native source edits beside declarations invalidate before entry validation and restore without feedback", {skip:rollupUnavailable,timeout:15000}, async t => {
 const {watchTestQueue} = await import("./watchTestQueue.js");
 const f = boundedSourceFixture(t);
 f.state.required = f.entry;f.save();
 const sidecar = join(f.root,"main.d.ms.ts");
 const plugin = metascript({root:f.root,entry:f.entry,msc:f.settings.msc,declaration:false,outDir:join(f.container,"generated"),sourceDeclarations:{outDir:f.root}});
 const queue = watchTestQueue();
 const watcher = realRollup.watch({input:f.entry,plugins:[plugin],output:{dir:join(f.container,"dist"),format:"es"},watch:{skipWrite:true}});
 t.after(() => watcher.close());
 watcher.on("event",event => {if(event.code==="ERROR"||event.code==="BUNDLE_END")queue.push(event);});
 const bundled = async () => {
  const event = await queue.next();assert.equal(event.code,"BUNDLE_END",event.error?.message);
  try {assert.ok(existsSync(sidecar));} finally {await event.result.close();}
 };
 await bundled();assert.equal(f.calls(),1);
 writeFileSync(f.entry,"source edit");await bundled();assert.equal(f.calls(),2);
 rmSync(f.entry);const event = await queue.next();assert.equal(event.code,"ERROR");
 assert.equal(event.error.message,"Invalid msc split manifest: entry must be an absolute existing input file");
 assert.equal(f.calls(),2);assert.equal(existsSync(sidecar),false);
 writeFileSync(f.entry,"source restore");await bundled();assert.equal(f.calls(),3);
 await watcher.close();assert.equal(queue.pending,0);
});
