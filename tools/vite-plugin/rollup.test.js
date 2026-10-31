import assert from "node:assert/strict";
import { chmodSync, existsSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createRequire } from "node:module";
import { pathToFileURL } from "node:url";
import { test } from "node:test";
import metascript from "./rollup.js";
import { canonicalPath } from "./compilerCore.js";

function fixture(t, options = {}) {
	const root = canonicalPath(mkdtempSync(join(tmpdir(), "msc rollup ")));
	t.after(() => rmSync(root, { recursive: true, force: true }));
	const entry = join(root, "main.ms");
	const dependency = join(root, "types.jms");
	writeFileSync(entry, "source");
	writeFileSync(dependency, "type source");
	const msc = join(root, "fake-msc.cjs");
	writeFileSync(msc, `#!/usr/bin/env node
const fs = require("node:fs");
const path = require("node:path");
const state = JSON.parse(fs.readFileSync(path.join(__dirname, "state.json"), "utf8"));
fs.appendFileSync(path.join(__dirname, "calls.jsonl"), "call\\n");
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
	const calls = () => existsSync(join(root, "calls.jsonl")) ? readFileSync(join(root, "calls.jsonl"), "utf8").trim().split("\n").length : 0;
	return { root, entry, dependency, state, save, settings, plugin, watched, assets, context, calls };
}

test("Rollup subpath ships native types and leaves the Vite default unchanged", () => {
	const pkg = JSON.parse(readFileSync(new URL("./package.json", import.meta.url), "utf8"));
	assert.deepEqual(pkg.exports["."], { types: "./index.d.ts", default: "./index.js" });
	assert.deepEqual(pkg.exports["./rollup"], { types: "./rollup.d.ts", default: "./rollup.js" });
	for (const file of ["rollup.js", "rollup.d.ts"]) assert.ok(pkg.files.includes(file));
	assert.equal(pkg.peerDependencies.rollup, ">=4");
	assert.equal(pkg.peerDependenciesMeta.rollup.optional, true);
	assert.match(readFileSync(new URL("./rollup.d.ts", import.meta.url), "utf8"), /from "rollup"/);
});

test("one compiler snapshot supplies every Rollup output and watches type-only dependencies", t => {
	const f = fixture(t);
	f.plugin.buildStart.call(f.context, { input: f.entry });
	assert.deepEqual([...f.watched].sort(), [f.entry, f.dependency].sort());
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

test("multi-entry inputs fail instead of silently selecting one compiler root", t => {
	for (const input of [["main.ms", "other.ms"], { main: "main.ms", other: "other.ms" }]) {
		const f = fixture(t);
		assert.throws(() => f.plugin.buildStart.call(f.context, { input }), /single.*root|one.*root/);
		assert.equal(f.calls(), 0);
	}
	assert.throws(() => metascript({ entry: ["a.ms", "b.ms"] }), /entry/);
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
