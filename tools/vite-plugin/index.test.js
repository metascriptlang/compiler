import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { chmodSync, existsSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, test } from "node:test";
import metascript from "./index.js";
import { canonicalPath } from "./compilerCore.js";

function fixture(t, options = {}) {
	const root = canonicalPath(mkdtempSync(join(tmpdir(), "msc vite hooks ")));
	t.after(() => rmSync(root, { recursive: true, force: true }));
	const entry = join(root, "main.ms");
	const typeInput = join(root, "types.jms");
	writeFileSync(entry, "source");
	writeFileSync(typeInput, "type source");
	const msc = join(root, "fake-msc.cjs");
	writeFileSync(msc, `#!/usr/bin/env node
const fs = require("node:fs");
const path = require("node:path");
const state = JSON.parse(fs.readFileSync(path.join(__dirname, "state.json"), "utf8"));
fs.appendFileSync(path.join(__dirname, "calls.jsonl"), JSON.stringify(process.argv.slice(2)) + "\\n");
if (state.fail) { process.stderr.write("fixture compiler diagnostic"); process.exit(2); }
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
		manifest: { entry, modules: [{ source: entry, out: "main.js" }], instances: [], dependencies: [typeInput] },
		files: { "main.js": "export const value = 1;\n//# sourceMappingURL=main.js.map\n", "main.js.map": JSON.stringify({ version: 3, sources: ["../../main.ms"], names: [], mappings: "AAAA" }) },
	};
	if (options.declaration) {
		state.manifest.declarations = [{ source: entry, out: "main.d.ts" }];
		state.files["main.d.ts"] = "export declare const value: number;";
	}
	const save = () => writeFileSync(join(root, "state.json"), JSON.stringify(state));
	save();
	const plugin = metascript({ msc, entry, ...options });
	plugin.configResolved({ root, command: "build" });
	const watched = new Set();
	const assets = [];
	const context = {
		addWatchFile: file => watched.add(file),
		emitFile: asset => { assets.push(asset); return String(assets.length); },
	};
	const calls = () => existsSync(join(root, "calls.jsonl")) ? readFileSync(join(root, "calls.jsonl"), "utf8").trim().split("\n").map(JSON.parse) : [];
	return { root, entry, typeInput, plugin, state, save, watched, assets, context, calls, out: join(root, "node_modules/.metascript") };
}

function devServer() {
	const watcher = new EventEmitter();
	const watched = new Set();
	watcher.add = files => { for (const file of files) watched.add(file); };
	const sent = [];
	const invalidated = [];
	const modules = new Map();
	return {
		watcher, watched, sent, modules, invalidated,
		ws: { send: message => sent.push(message) },
		moduleGraph: {
			getModulesByFile: file => modules.get(file),
			invalidateModule: module => invalidated.push(module),
		},
	};
}

function hot(f, server, file = f.entry) {
	return f.plugin.handleHotUpdate.call(f.context, { file, server });
}

describe("Vite native hooks with fake compiler (not Vite consumer acceptance)", () => {
	test("the existing package entry exposes option types and includes its runtime core", () => {
		const pkg = JSON.parse(readFileSync(new URL("./package.json", import.meta.url), "utf8"));
		assert.equal(pkg.main, "index.js");
		assert.equal(pkg.types, "./index.d.ts");
		assert.deepEqual(pkg.exports["."], { types: "./index.d.ts", default: "./index.js" });
		assert.equal(pkg.peerDependencies.vite, ">=5");
		for (const file of ["index.js", "index.d.ts", "compilerCore.js"]) {
			assert.ok(pkg.files.includes(file));
			assert.ok(existsSync(new URL(file, import.meta.url)));
		}
	});
	test("the package publicly exports the typed reusable core", async () => {
		const core = await import("vite-plugin-metascript/core");
		assert.equal(typeof core.buildCompilerGraph, "function");
		const pkg = JSON.parse(readFileSync(new URL("./package.json", import.meta.url), "utf8"));
		assert.deepEqual(pkg.exports["./core"], { types: "./compilerCore.d.ts", default: "./compilerCore.js" });
	});

	test("existing options and sourcemaps use the shared compiler core", t => {
		const f = fixture(t);
		const explicit = join(f.root, "custom output");
		f.state.files["main.js.map"] = JSON.stringify({ version: 3, sources: ["../main.ms"], names: [], mappings: "AAAA" });
		f.save();
		const plugin = metascript({ msc: join(f.root, "fake-msc.cjs"), entry: f.entry, outDir: explicit, compilerArgs: ["--define=some value"] });
		plugin.configResolved({ root: f.root, command: "build" });
		plugin.buildStart.call(f.context);
		assert.deepEqual(f.calls()[0], ["build", f.entry, "--define=some value", "--target=js", "--split", `--output=${explicit}`, "--sourcemap"]);
		const loaded = plugin.load.call(f.context, f.entry);
		assert.equal(loaded.code, "export const value = 1;\n");
		assert.equal(loaded.map.mappings, "AAAA");
		assert.deepEqual(loaded.map.sources, [f.entry]);
		assert.equal(loaded.code.includes("sourceMappingURL"), false);
	});

	test("declarations are opt-in assets emitted once for each output without writing output directories", t => {
		const f = fixture(t, { declaration: true });
		f.plugin.buildStart.call(f.context);
		assert.equal(f.calls()[0].includes("--declaration"), true);
		const output = { dir: join(f.root, "bundle"), format: "es" };
		f.plugin.generateBundle.call(f.context, output, {}, false);
		f.plugin.generateBundle.call(f.context, { ...output, dir: join(f.root, "second") }, {}, false);
		assert.deepEqual(f.assets, Array(2).fill({ type: "asset", fileName: "main.d.ts", source: "export declare const value: number;" }));
		assert.equal(existsSync(output.dir), false);
		assert.equal(existsSync(join(f.root, "second")), false);
		assert.equal(f.calls().length, 1);
	});

	test("default options do not publish declarations and sourcemap false is preserved", t => {
		const f = fixture(t, { sourcemap: false });
		f.plugin.buildStart.call(f.context);
		f.plugin.generateBundle.call(f.context, {}, {}, false);
		assert.equal(f.calls()[0].includes("--declaration"), false);
		assert.equal(f.calls()[0].includes("--sourcemap"), false);
		assert.equal(f.plugin.load.call(f.context, f.entry).map, null);
		assert.deepEqual(f.assets, []);
	});

	test("buildStart watches compiler inputs even when no runtime resolve requests them", t => {
		const f = fixture(t);
		f.plugin.buildStart.call(f.context);
		assert.deepEqual([...f.watched].sort(), [f.entry, f.typeInput, join(f.root,"fake-msc.cjs")].sort());
		assert.equal(f.plugin.resolveId.call(f.context, "./main.ms?v=1"), f.entry);
		assert.equal(f.calls().length, 1);
	});

	test("runtime load and transform register compiler dependencies on the module hooks", t => {
		const f = fixture(t);
		f.plugin.buildStart.call(f.context);
		f.watched.clear();
		const loaded = f.plugin.load.call(f.context, f.entry);
		assert.deepEqual([...f.watched].sort(), [f.entry, f.typeInput, join(f.root,"fake-msc.cjs")].sort());
		f.watched.clear();
		f.plugin.transform.call({ ...f.context, parse: () => ({ type: "Program", body: [] }) }, loaded.code, f.entry);
		assert.deepEqual([...f.watched].sort(), [f.entry, f.typeInput, join(f.root,"fake-msc.cjs")].sort());
	});

	test("an omitted entry still compiles lazily on the first source import", t => {
		const f = fixture(t, { entry: undefined });
		f.plugin.buildStart.call(f.context);
		assert.equal(f.calls().length, 0);
		assert.equal(f.plugin.resolveId.call(f.context, "./main.ms"), f.entry);
		assert.equal(f.calls().length, 1);
		assert.equal(f.watched.has(f.typeInput), true);
		assert.equal(f.plugin.resolveId.call(f.context, "./missing.ms"), null);
	});

	test("canonical paths and generic source-instance IDs remain resolvable", t => {
		const f = fixture(t);
		f.state.manifest.instances.push({ source: f.entry, out: "_instances/box_number.js" });
		f.state.files["_instances/box_number.js"] = "export const box = 1;";
		f.save();
		const alias = join(f.root, "alias.ms");
		symlinkSync(f.entry, alias);
		f.plugin.buildStart.call(f.context);
		assert.equal(f.plugin.resolveId.call(f.context, alias), f.entry);
		assert.equal(f.plugin.resolveId.call(f.context, "./main.ms?instance=box_number"), `${f.entry}?instance=box_number`);
		assert.equal(f.plugin.load.call(f.context, `${f.entry}?instance=box_number`).code, "export const box = 1;");
		assert.equal(f.plugin.resolveId.call(f.context, "./main.ms?instance=missing"), null);
	});

	test("transform rewrites parsed imports, reexports and dynamic imports but not ordinary strings", t => {
		const f = fixture(t);
		f.state.manifest.modules.push({ source: f.typeInput, out: "types.js" });
		f.state.manifest.instances.push({ source: f.typeInput, out: "_instances/box_number.js" });
		f.state.files["types.js"] = "export {};";
		f.state.files["_instances/box_number.js"] = "export {};";
		f.save();
		f.plugin.buildStart.call(f.context);
		const code = 'import "./types.js"; export * from "./types.js"; import("./_instances/box_number.js"); const text = "./types.js";';
		const literals = [...code.matchAll(/"([^"]+)"/g)].map(match => ({ type: "Literal", value: match[1], start: match.index, end: match.index + match[0].length }));
		const parse = () => ({ type: "Program", body: [
			{ type: "ImportDeclaration", source: literals[0] },
			{ type: "ExportAllDeclaration", source: literals[1] },
			{ type: "ImportExpression", source: literals[2] },
			{ type: "VariableDeclaration", value: literals[3] },
		] });
		const transformed = f.plugin.transform.call({ ...f.context, parse }, code, f.entry);
		assert.equal(transformed.code, 'import "./types.jms"; export * from "./types.jms"; import("./types.jms?instance=box_number"); const text = "./types.js";');
		assert.equal(transformed.map.sources[0], f.entry);
		assert.ok(transformed.map.mappings.length > 0);
	});

	test("watchChange refreshes type-only declarations without a runtime module request", t => {
		const f = fixture(t, { declaration: true });
		f.plugin.buildStart.call(f.context);
		f.state.files["main.d.ts"] = "export declare const value: string;";
		f.save();
		f.plugin.watchChange.call(f.context, f.typeInput, { event: "update" });
		f.plugin.buildStart.call(f.context);
		f.plugin.generateBundle.call(f.context, {}, {}, false);
		assert.equal(f.assets[0].source, "export declare const value: string;");
		assert.equal(f.calls().length, 2);
	});

	test("output hooks reject a dirty snapshot rather than recompiling after runtime chunks were generated", t => {
		const f = fixture(t, { declaration: true });
		f.plugin.buildStart.call(f.context);
		f.plugin.watchChange.call(f.context, f.typeInput, { event: "update" });
		assert.throws(() => f.plugin.generateBundle.call(f.context, {}, {}, false), /rebuild before emitting declarations/);
		assert.equal(f.calls().length, 1);
		assert.deepEqual(f.assets, []);
	});

	test("an invalidated production generation cannot replace an already consumed graph", t => {
		const f = fixture(t, { declaration: true });
		f.state.manifest.modules.push({ source: f.typeInput, out: "types.js" });
		f.state.files["types.js"] = "export const name = 'before';";
		f.save();
		f.plugin.buildStart.call(f.context);
		assert.match(f.plugin.load.call(f.context, f.entry).code, /value = 1/);
		f.state.files["types.js"] = "export const name = 'after';";
		f.state.files["main.d.ts"] = "export declare const value: string;";
		f.save();
		f.plugin.watchChange.call(f.context, f.typeInput, { event: "update" });
		assert.throws(() => f.plugin.load.call(f.context, f.typeInput), /invalidated.*buildStart/);
		assert.throws(() => f.plugin.resolveId.call(f.context, "./types.jms", f.entry), /invalidated.*buildStart/);
		assert.throws(() => f.plugin.generateBundle.call(f.context), /rebuild before emitting declarations/);
		assert.equal(f.calls().length, 1);
		assert.deepEqual(f.assets, []);
		f.plugin.buildStart.call(f.context);
		assert.match(f.plugin.load.call(f.context, f.typeInput).code, /after/);
		f.plugin.generateBundle.call(f.context);
		assert.equal(f.calls().length, 2);
		assert.equal(f.assets[0].source, "export declare const value: string;");
	});

	test("source and instance pairing is validated during resolution and loading", t => {
		const f = fixture(t);
		f.state.manifest.modules.push({ source: f.typeInput, out: "types.js" });
		f.state.manifest.instances.push({ source: f.typeInput, out: "_instances/types_number.js" });
		f.state.files["types.js"] = "export {};";
		f.state.files["_instances/types_number.js"] = "export const instance = 1;";
		f.save();
		f.plugin.buildStart.call(f.context);
		const wrong = `${f.entry}?instance=types_number`;
		assert.throws(() => f.plugin.resolveId.call(f.context, wrong), /source.*instance.*match/);
		assert.throws(() => f.plugin.load.call(f.context, wrong), /source.*instance.*match/);
		const correct = `${f.typeInput}?instance=types_number`;
		assert.equal(f.plugin.resolveId.call(f.context, correct), correct);
		assert.equal(f.plugin.load.call(f.context, correct).code, "export const instance = 1;");
	});

	test("watch builds fail on a deleted dependency and recover without publishing stale declarations", t => {
		const f = fixture(t, { declaration: true });
		f.plugin.buildStart.call(f.context);
		rmSync(f.typeInput);
		f.plugin.watchChange.call(f.context, f.typeInput, { event: "delete" });
		assert.throws(() => f.plugin.buildStart.call(f.context), /absolute existing input/);
		assert.throws(() => f.plugin.generateBundle.call(f.context, {}, {}, false), /rebuild before emitting declarations/);
		assert.deepEqual(f.assets, []);
		assert.equal(f.watched.has(f.typeInput), true);
		writeFileSync(f.typeInput, "restored");
		f.plugin.watchChange.call(f.context, f.typeInput, { event: "create" });
		f.plugin.buildStart.call(f.context);
		f.plugin.generateBundle.call(f.context, {}, {}, false);
		assert.equal(f.assets.length, 1);
	});

	test("each build generation recompiles and emits only current declaration inventory", t => {
		const f = fixture(t, { declaration: true });
		f.state.manifest.declarations.push({ source: f.typeInput, out: "types.d.ts" });
		f.state.files["types.d.ts"] = "export type Value = number;";
		f.save();
		f.plugin.buildStart.call(f.context);
		f.plugin.generateBundle.call(f.context, {}, {}, false);
		assert.deepEqual(f.assets.map(a => a.fileName), ["main.d.ts", "types.d.ts"]);
		f.assets.length = 0;
		f.state.manifest.declarations.pop();
		delete f.state.files["types.d.ts"];
		f.save();
		f.plugin.buildStart.call(f.context);
		f.plugin.generateBundle.call(f.context, {}, {}, false);
		assert.deepEqual(f.assets.map(a => a.fileName), ["main.d.ts"]);
		assert.equal(f.calls().length, 2);
	});

	test("dev HMR watches type-only dependencies without invalidating unchanged JavaScript", t => {
		const f = fixture(t, { declaration: true });
		const server = devServer();
		f.plugin.configureServer(server);
		f.plugin.buildStart.call(f.context);
		assert.equal(server.watched.has(f.typeInput), true);
		f.state.files["main.d.ts"] = "export declare const value: string;";
		f.save();
		assert.deepEqual(hot(f, server, f.typeInput), []);
		assert.equal(f.calls().length, 2);
		assert.equal(server.sent.length, 0);
		assert.equal(existsSync(join(f.root, "main.d.ms.ts")), false);
	});

	test("dev HMR invalidates only changed source instances and removes vanished compiler JS/maps", t => {
		const f = fixture(t);
		f.state.manifest.instances.push({ source: f.entry, out: "_instances/box_number.js" });
		f.state.files["_instances/box_number.js"] = "export const box = 1;";
		f.state.files["_instances/box_number.js.map"] = JSON.stringify({ sources: ["../../../main.ms"] });
		f.save();
		f.plugin.buildStart.call(f.context);
		const server = devServer();
		const sourceModule = { id: f.entry };
		const instanceModule = { id: `${f.entry}?instance=box_number` };
		server.modules.set(f.entry, new Set([sourceModule, instanceModule]));
		f.plugin.configureServer(server);
		f.state.manifest.instances = [];
		delete f.state.files["_instances/box_number.js"];
		delete f.state.files["_instances/box_number.js.map"];
		f.save();
		assert.deepEqual(hot(f, server), [instanceModule]);
		assert.equal(existsSync(join(f.out, "_instances/box_number.js")), false);
		assert.equal(existsSync(join(f.out, "_instances/box_number.js.map")), false);
		assert.deepEqual(hot(f, server, join(f.out, "main.js")), []);
	});

	test("dev stale cleanup never deletes an unowned sourcemap beside a removed module", t => {
		const f = fixture(t, { sourcemap: false });
		f.state.manifest.instances.push({ source: f.entry, out: "_instances/box_number.js" });
		f.state.files["_instances/box_number.js"] = "export const box = 1;";
		f.save();
		f.plugin.buildStart.call(f.context);
		const unownedMap = join(f.out, "_instances/box_number.js.map");
		writeFileSync(unownedMap, "not compiler owned");
		f.state.manifest.instances = [];
		delete f.state.files["_instances/box_number.js"];
		f.save();
		hot(f, devServer());
		assert.equal(readFileSync(unownedMap, "utf8"), "not compiler owned");
	});

	test("dev compiler diagnostics preserve the last snapshot and recovery clears the overlay", t => {
		const f = fixture(t);
		f.plugin.buildStart.call(f.context);
		const server = devServer();
		f.plugin.configureServer(server);
		f.state.fail = true;
		f.save();
		assert.deepEqual(hot(f, server), []);
		assert.match(server.sent[0].err.message, /fixture compiler diagnostic/);
		assert.equal(server.sent[0].type, "error");
		assert.throws(() => f.plugin.load.call(f.context, f.entry), /fixture compiler diagnostic/);
		f.state.fail = false;
		f.save();
		assert.deepEqual(hot(f, server), []);
		assert.deepEqual(server.sent.at(-1), { type: "update", updates: [] });
	});

	test("dev watcher deletion/recreation reports errors, refreshes loaded modules and detaches on close", t => {
		const f = fixture(t);
		const server = devServer();
		const sourceModule = { id: f.entry };
		server.modules.set(f.entry, new Set([sourceModule]));
		f.plugin.configureServer(server);
		f.plugin.buildStart.call(f.context);
		rmSync(f.typeInput);
		server.watcher.emit("unlink", f.typeInput);
		assert.equal(server.sent.at(-1).type, "error");
		writeFileSync(f.typeInput, "restored");
		f.state.files["main.js"] = "export const value = 2;";
		f.save();
		server.watcher.emit("add", f.typeInput);
		assert.deepEqual(server.invalidated, [sourceModule]);
		assert.equal(server.sent.at(-1).type, "full-reload");
		f.plugin.closeBundle();
		assert.equal(server.watcher.listenerCount("add"), 0);
		assert.equal(server.watcher.listenerCount("unlink"), 0);
	});

	test("a failed first compile retains the entry watch for dev recovery", t => {
		const f = fixture(t);
		const server = devServer();
		f.plugin.configureServer(server);
		f.state.fail = true;
		f.save();
		assert.throws(() => f.plugin.buildStart.call(f.context), /fixture compiler diagnostic/);
		assert.equal(server.watched.has(f.entry), true);
		f.state.fail = false;
		f.save();
		assert.deepEqual(hot(f, server), []);
		assert.equal(f.plugin.load.call(f.context, f.entry).code, "export const value = 1;\n");
	});
});

test("source-only Vite publication invalidates dirty and failed types, recovers same lease, closes offline", t => {
 const f = fixture(t, {sourceDeclarations:{outDir:"editor-types"}});
 f.state.manifest.sourceDeclarationRoot = "_source_declarations";
 f.state.manifest.sourceDeclarationPackage = "_source_declarations/package.json";
 f.state.manifest.sourceDeclarations = [{source:f.entry,out:"_source_declarations/main.d.ms.ts"}];
 f.state.files["_source_declarations/main.d.ms.ts"] = "export declare const value: number;";
 f.state.files["_source_declarations/package.json"] = '{"type":"module"}'; f.save();
 const server = devServer(); f.plugin.configureServer(server);
 f.plugin.buildStart.call(f.context);
 const file = join(f.root,"editor-types/main.d.ms.ts");
 assert.ok(existsSync(file)); f.plugin.generateBundle.call(f.context); assert.deepEqual(f.assets,[]);
 f.plugin.watchChange(f.typeInput); assert.equal(existsSync(file),false);
 f.state.fail = true; f.save(); f.plugin.handleHotUpdate.call(f.context,{file:f.typeInput,server});
 assert.equal(existsSync(file),false); assert.match(server.sent.at(-1).err.message,/diagnostic/);
 f.state.fail = false; f.save(); f.plugin.handleHotUpdate.call(f.context,{file:f.typeInput,server});
 assert.ok(existsSync(file)); f.plugin.closeBundle();
 assert.ok(existsSync(file)); assert.equal(existsSync(join(f.root,"editor-types/.msc-source-lease")),false);
});

test("Vite sourcemap handoffs are mutable independent copies of the frozen graph", t => {
 const f = fixture(t);
 f.state.files["main.js.map"] = JSON.stringify({version:3,sources:["../../main.ms"],sourcesContent:["original source"],names:[],mappings:"AAAA",x_metadata:{labels:["original"]}});
 f.save(); f.plugin.buildStart.call(f.context);
 const first = f.plugin.load.call(f.context,f.entry);
 const original = JSON.parse(JSON.stringify(first.map));
 first.map.sourcesContent = ["Vite injected content"];
 first.map.sources[0] = "mutated source";
 first.map.x_metadata.labels.push("consumer mutation");
 const second = f.plugin.load.call(f.context,f.entry);
 assert.deepEqual(second.map,original);
 assert.notEqual(second.map,first.map);
 second.map.sourcesContent[0] = "another consumer";
 assert.deepEqual(f.plugin.load.call(f.context,f.entry).map,original);
 assert.equal(f.calls().length,1);
});
