import assert from "node:assert/strict";
import { chmodSync, existsSync, mkdtempSync, readFileSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, test } from "node:test";
import { buildCompilerGraph, canonicalPath, instanceOf, outputOf, stripQuery, withInstance } from "./compilerCore.js";

function fixture(t) {
	const root = realpathSync(mkdtempSync(join(tmpdir(), "msc core contract ")));
	t.after(() => rmSync(root, { recursive: true, force: true }));
	const entry = join(root, "main.ms");
	const dependency = join(root, "types.jms");
	writeFileSync(entry, "export const value = 1;");
	writeFileSync(dependency, "export type Value = number;");
	const msc = join(root, "fake-msc");
	writeFileSync(msc, `#!/usr/bin/env node
const fs = require("node:fs");
const path = require("node:path");
const root = __dirname;
const fixture = JSON.parse(fs.readFileSync(path.join(root, "fixture.json"), "utf8"));
fs.writeFileSync(path.join(root, "args.json"), JSON.stringify(process.argv.slice(2)));
if (fixture.fail) {
	process.stdout.write("compiler stdout\\n");
	process.stderr.write("compiler diagnostic\\n");
	process.exit(2);
}
const out = process.argv.find(arg => arg.startsWith("--output=")).slice(9);
fs.mkdirSync(out, { recursive: true });
for (const [name, text] of Object.entries(fixture.files)) {
	const file = path.join(out, name);
	fs.mkdirSync(path.dirname(file), { recursive: true });
	fs.writeFileSync(file, text);
}
for (const [name, target] of Object.entries(fixture.symlinks ?? {})) {
	fs.symlinkSync(target, path.join(out, name));
}
fs.writeFileSync(path.join(out, "_manifest.json"), fixture.rawManifest ?? JSON.stringify(fixture.manifest));
`);
	chmodSync(msc, 0o755);
	const manifest = { entry, modules: [{ source: entry, out: "main.js" }], instances: [] };
	const files = { "main.js": "export const value = 1;\n//# sourceMappingURL=main.js.map\n" };
	const options = { root, entry: "main.ms", outDir: "output tree", msc };
	const run = (changes = {}, optionChanges = {}) => {
		writeFileSync(join(root, "fixture.json"), JSON.stringify({ manifest, files, ...changes }));
		return buildCompilerGraph({ ...options, ...optionChanges });
	};
	return { root, entry: canonicalPath(entry), dependency: canonicalPath(dependency), manifest, files, options, run };
}

describe("fake compiler adapter contract (not compiler acceptance)", () => {
	test("one subprocess requests the complete split graph and preserves compiler arguments", t => {
		const f = fixture(t);
		f.manifest.declarations = [{ source: f.entry, out: "main.d.ts" }];
		const result = f.run({ files: { ...f.files, "main.d.ts": "export {};" } }, { compilerArgs: ["--define=some value"], declaration: true });
		assert.deepEqual(JSON.parse(readFileSync(join(f.root, "args.json"), "utf8")), [
			"build", f.entry, "--define=some value", "--target=js", "--split", `--output=${join(f.root, "output tree")}`, "--sourcemap", "--declaration",
		]);
		assert.equal(result.entry, f.entry);
		assert.equal(result.outDir, canonicalPath(join(f.root, "output tree")));
	});

	test("requires an entry declaration when declarations are requested", t => {
		const f = fixture(t);
		const message = /entry declaration is required when --declaration is requested/;
		assert.throws(() => f.run({}, { declaration: true }), message);
		f.manifest.declarations = [];
		assert.throws(() => f.run({}, { declaration: true }), message);
		f.manifest.declarations = [{ source: f.dependency, out: "types.d.ts" }];
		assert.throws(() => f.run({ files: { ...f.files, "types.d.ts": "export {};" } }, { declaration: true }), message);
	});

	test("declarations are opt-in and sourcemaps can be disabled", t => {
		const f = fixture(t);
		const result = f.run({ files: { ...f.files, "main.js.map": "not JSON" } }, { sourcemap: false });
		const args = JSON.parse(readFileSync(join(f.root, "args.json"), "utf8"));
		assert.equal(args.includes("--sourcemap"), false);
		assert.equal(args.includes("--declaration"), false);
		assert.equal(result.modules[0].map, null);
		assert.equal(result.artifacts.some(a => a.kind === "sourcemap"), false);
	});

	test("legacy indexes preserve source and generic-instance identities", t => {
		const f = fixture(t);
		f.manifest.modules.push({ source: f.dependency, out: "nested/types.js" });
		f.manifest.instances.push({ source: f.entry, out: "_instances/box_number.js" });
		const result = f.run({ files: { ...f.files, "nested/types.js": "export {};", "_instances/box_number.js": "export const box = 1;" } });
		const file = outputOf(result, `${f.entry}?v=123`);
		assert.equal(file, result.bySource.get(f.entry));
		assert.equal(result.byOutput.get(file).code, "export const value = 1;\n");
		const instanceFile = outputOf(result, `${f.entry}?instance=box_number`);
		assert.equal(instanceFile, result.byInstance.get("box_number"));
		assert.equal(result.byOutput.get(instanceFile).source, f.entry);
		assert.equal(result.byOutput.get(instanceFile).instance, "box_number");
		assert.deepEqual([...result.bySource.keys()], [f.entry, f.dependency]);
		assert.equal(outputOf(null, f.entry), undefined);
		assert.equal(outputOf(result, join(f.root, "absent.ms")), undefined);
	});

	test("canonical source IDs accept symlink spellings", t => {
		const f = fixture(t);
		const alias = join(f.root, "alias.ms");
		symlinkSync(f.entry, alias);
		assert.equal(outputOf(f.run(), alias), outputOf(f.run(), f.entry));
		assert.equal(stripQuery(`${alias}?v=1`), alias);
		assert.equal(instanceOf(`${alias}?v=1&instance=box`), "box");
		assert.equal(withInstance(alias, "box"), `${alias}?instance=box`);
		assert.equal(withInstance(alias, ""), alias);
	});

	test("compiler maps retain mappings and resolve sources beside the emitted module", t => {
		const f = fixture(t);
		const map = { version: 3, sources: ["../main.ms"], sourcesContent: ["source"], names: [], mappings: "AAAA" };
		const result = f.run({ files: { ...f.files, "main.js.map": JSON.stringify(map) } });
		assert.deepEqual(result.modules[0].map, { ...map, sources: [f.entry.replace(/\\/g, "/")] });
		assert.equal(result.artifacts.find(a => a.kind === "sourcemap").text, JSON.stringify(map));
	});

	test("optional declaration and dependency inventories include type-only inputs", t => {
		const f = fixture(t);
		f.manifest.declarations = [{ source: f.entry, out: "main.d.ts" }];
		f.manifest.dependencies = [f.entry, f.dependency, f.dependency];
		const result = f.run({ files: { ...f.files, "main.d.ts": "export declare const value: number;" } });
		assert.deepEqual(result.dependencies, [f.entry, f.dependency]);
		assert.equal(result.declarations[0].source, f.entry);
		assert.equal(result.declarations[0].text, "export declare const value: number;");
		assert.deepEqual(result.artifacts.map(a => a.kind), ["manifest", "javascript", "declaration"]);
	});

	test("old manifests fall back to module inputs without requiring new metadata", t => {
		const f = fixture(t);
		delete f.manifest.instances;
		const result = f.run();
		assert.deepEqual(result.dependencies, [f.entry]);
		assert.deepEqual(result.declarations, []);
		assert.deepEqual(result.instances, []);
	});

	test("per-build snapshots and nested maps cannot be mutated", t => {
		const f = fixture(t);
		const result = f.run({ files: { ...f.files, "main.js.map": JSON.stringify({ version: 3, sources: ["../main.ms"], names: [], mappings: "" }) } });
		assert.throws(() => { result.entry = "other"; }, TypeError);
		assert.throws(() => result.dependencies.push("other"), TypeError);
		assert.throws(() => { result.modules[0].code = "other"; }, TypeError);
		assert.throws(() => result.modules[0].map.sources.push("other"), TypeError);
		assert.throws(() => { result.artifacts[0].text = "other"; }, TypeError);
		assert.equal(result.bySource.set, undefined);
		assert.equal(result.byOutput.delete, undefined);
		assert.equal(result.byOutput.size, 1);
		assert.deepEqual([...result.byOutput.values()], result.modules);
	});

	test("type-only changes are visible independently of JavaScript code", t => {
		const f = fixture(t);
		f.manifest.declarations = [{ source: f.entry, out: "main.d.ts" }];
		const before = f.run({ files: { ...f.files, "main.d.ts": "export type Value = number;" } });
		const after = f.run({ files: { ...f.files, "main.d.ts": "export type Value = string;" } });
		assert.equal(before.modules[0].code, after.modules[0].code);
		assert.notEqual(before.declarations[0].text, after.declarations[0].text);
		assert.equal(before.declarations[0].text, "export type Value = number;");
	});

	test("owned artifacts identify stale outputs without deleting unrelated files", t => {
		const f = fixture(t);
		f.manifest.declarations = [{ source: f.entry, out: "main.d.ts" }];
		const before = f.run({ files: { ...f.files, "main.d.ts": "export {};", "unrelated.txt": "keep" } });
		delete f.manifest.declarations;
		const after = f.run();
		const nextFiles = new Set(after.artifacts.map(a => a.file));
		assert.deepEqual(before.artifacts.filter(a => !nextFiles.has(a.file)).map(a => a.out), ["main.d.ts"]);
		assert.equal(existsSync(join(after.outDir, "main.d.ts")), true);
		assert.equal(readFileSync(join(after.outDir, "unrelated.txt"), "utf8"), "keep");
	});

	test("subprocess diagnostics fail the build without changing an earlier snapshot", t => {
		const f = fixture(t);
		const before = f.run();
		assert.throws(() => f.run({ fail: true }), /msc build failed:\ncompiler stdout\ncompiler diagnostic/);
		assert.equal(before.modules[0].code, "export const value = 1;\n");
		assert.equal(f.run().modules[0].code, before.modules[0].code);
	});

	test("missing compiler reports its process error", t => {
		const f = fixture(t);
		assert.throws(() => f.run({}, { msc: join(f.root, "missing-msc") }), /ENOENT/);
	});

	test("separate builds do not share graph indexes", t => {
		const first = fixture(t);
		const second = fixture(t);
		const a = first.run();
		const b = second.run();
		assert.equal(a.bySource.has(second.entry), false);
		assert.equal(b.bySource.has(first.entry), false);
	});

	for (const [name, change, message] of [
		["invalid JSON", f => ({ rawManifest: "{" }), /_manifest.json/],
		["null manifest", f => ({ rawManifest: "null" }), /expected an object/],
		["non-array modules", f => ({ manifest: { ...f.manifest, modules: {} } }), /modules must be an array/],
		["non-array instances", f => ({ manifest: { ...f.manifest, instances: {} } }), /instances must be an array/],
		["non-array declarations", f => ({ manifest: { ...f.manifest, declarations: null } }), /declarations must be an array/],
		["non-array dependencies", f => ({ manifest: { ...f.manifest, dependencies: "input" } }), /dependencies must be an array/],
		["wrong entry", f => ({ manifest: { ...f.manifest, entry: f.dependency } }), /entry does not match/],
		["missing entry module", f => ({ manifest: { ...f.manifest, modules: [] } }), /entry is not present/],
		["relative source", f => ({ manifest: { ...f.manifest, modules: [{ source: "main.ms", out: "main.js" }] } }), /absolute existing input/],
		["missing dependency", f => ({ manifest: { ...f.manifest, dependencies: [join(f.root, "missing.ms")] } }), /absolute existing input/],
		["directory input", f => ({ manifest: { ...f.manifest, dependencies: [f.root] } }), /absolute existing input file/],
		["relative dependency", f => ({ manifest: { ...f.manifest, dependencies: ["types.jms"] } }), /absolute existing input file/],
		["escaping declaration", f => ({ manifest: { ...f.manifest, declarations: [{ source: f.entry, out: "../escape.d.ts" }] } }), /malformed output path/],
		["malformed module", f => ({ manifest: { ...f.manifest, modules: [null] } }), /module must be an object/],
		["missing output", f => ({ files: {} }), /output is not a file/],
		["duplicate source", f => ({ manifest: { ...f.manifest, modules: [...f.manifest.modules, { source: f.entry, out: "other.js" }] }, files: { ...f.files, "other.js": "" } }), /duplicate module source/],
		["duplicate output", f => ({ manifest: { ...f.manifest, declarations: [{ source: f.entry, out: "main.js" }] } }), /duplicate output/],
		["duplicate instance basename", f => ({ manifest: { ...f.manifest, instances: [{ source: f.entry, out: "a/box.js" }, { source: f.entry, out: "b/box.js" }] }, files: { ...f.files, "a/box.js": "", "b/box.js": "" } }), /duplicate instance/],
		["invalid source map", f => ({ files: { ...f.files, "main.js.map": "{}" } }), /invalid source map/],
	]) {
		test(`rejects ${name}`, t => {
			const f = fixture(t);
			assert.throws(() => f.run(change(f)), message);
		});
	}

	for (const out of ["../escape.js", "nested/../../escape.js", "/absolute.js", "C:\\escape.js", "C:escape.js", "\\\\host\\share\\escape.js", "nested\\..\\escape.js", "./main.js", "nested//main.js", "", "bad\0.js"]) {
		test(`rejects escaping or malformed output ${JSON.stringify(out)}`, t => {
			const f = fixture(t);
			f.manifest.modules[0].out = out;
			assert.throws(() => f.run(), /Invalid msc split manifest/);
		});
	}

	test("normalizes compiler path separators", t => {
		const f = fixture(t);
		f.manifest.modules[0].out = "nested\\main.js";
		const result = f.run({ files: { "nested/main.js": "export {};" } });
		assert.equal(result.modules[0].out, "nested/main.js");
	});

	test("rejects manifest symlinks escaping the root", t => {
		const f = fixture(t);
		const external = join(f.root, "external-manifest.json");
		writeFileSync(external, "{}");
		assert.throws(() => f.run({ symlinks: { "_manifest.json": external } }), /output escapes root/);
	});

	test("rejects output symlinks escaping the root", t => {
		const f = fixture(t);
		const external = join(f.root, "external.js");
		writeFileSync(external, "export {};");
		assert.throws(() => f.run({ files: {}, symlinks: { "main.js": external } }), /output escapes root/);
	});

	test("rejects source map symlinks escaping the root", t => {
		const f = fixture(t);
		const external = join(f.root, "external.map");
		writeFileSync(external, JSON.stringify({ sources: [] }));
		assert.throws(() => f.run({ symlinks: { "main.js.map": external } }), /output escapes root/);
	});

	test("rejects declaration symlinks escaping the root", t => {
		const f = fixture(t);
		f.manifest.declarations = [{ source: f.entry, out: "main.d.ts" }];
		const external = join(f.root, "external.d.ts");
		writeFileSync(external, "export {};");
		assert.throws(() => f.run({ symlinks: { "main.d.ts": external } }), /output escapes root/);
	});
});

test("source family requests one shared multi-root graph and immutable compiler-owned artifacts", t => {
 const f = fixture(t);
 f.manifest.entries = [f.entry, f.dependency];
 f.manifest.modules.push({source:f.dependency,out:"types.js"});
 f.manifest.declarations = [{source:f.entry,out:"main.d.ts"}];
 f.manifest.sourceDeclarationRoot = "_source_declarations";
 f.manifest.sourceDeclarationPackage = "_source_declarations/package.json";
 f.manifest.sourceDeclarations = [{source:f.entry,out:"_source_declarations/main.d.ms.ts"}, {source:f.dependency,out:"_source_declarations/types.d.jms.ts"}, {source:f.entry,out:"_source_declarations/_types/main.d.ts"}];
 const files = {...f.files,"types.js":"export {};", "main.d.ts":"export {};", "_source_declarations/package.json":'{"type":"module"}'};
 for (const row of f.manifest.sourceDeclarations) files[row.out] = "export {};";
 const result = f.run({files}, {entry:[f.entry,f.dependency,f.entry],sourceRoot:f.root});
 assert.deepEqual(result.entries,[f.entry,f.dependency]);
 assert.equal(result.sourceDeclarations.length,3);
 assert.equal(Object.isFrozen(result.sourceDeclarations[0]),true);
 const args = JSON.parse(readFileSync(join(f.root,"args.json"),"utf8"));
 assert.equal(args.filter(arg => arg === `--js-entry=${f.dependency}`).length,1);
 assert.ok(args.includes(`--declaration-source-root=${f.root}`));
 assert.ok(args.includes("--declaration"));
 f.manifest.entries = [f.entry];
 assert.throws(() => f.run({files},{entry:[f.entry,f.dependency],sourceRoot:f.root}), /entries/);
 f.manifest.entries = [f.entry,f.dependency];
 f.manifest.sourceDeclarations.pop(); f.manifest.sourceDeclarations.pop();
 assert.throws(() => f.run({files},{entry:[f.entry,f.dependency],sourceRoot:f.root}), /source.*entry|entry.*source/i);
});

test("source family rejects prefix escapes, duplicate ownership and non-ESM metadata", t => {
 const f = fixture(t);
 f.manifest.sourceDeclarationRoot = "_source_declarations";
 f.manifest.sourceDeclarationPackage = "_source_declarations/package.json";
 f.manifest.sourceDeclarations = [{source:f.entry,out:"_source_declarations/main.d.ms.ts"}];
 const files = {...f.files,"_source_declarations/main.d.ms.ts":"export {};","_source_declarations/package.json":'{"type":"module"}'};
 f.run({files},{sourceRoot:f.root});
 f.manifest.sourceDeclarations[0].out = "_source_declarations_evil/main.d.ms.ts";
 assert.throws(() => f.run({files:{...files,"_source_declarations_evil/main.d.ms.ts":"export {};"}},{sourceRoot:f.root}),/outside.*family/);
 f.manifest.sourceDeclarations[0].out = "_source_declarations/package.json";
 assert.throws(() => f.run({files},{sourceRoot:f.root}),/duplicate output/);
 f.manifest.sourceDeclarations[0].out = "_source_declarations/main.d.ms.ts";
 for (const text of ['{"type":"commonjs"}','{"type":"module","name":"user-package"}']) {
  assert.throws(() => f.run({files:{...files,"_source_declarations/package.json":text}},{sourceRoot:f.root}),/only type: module/);
 }
});

test("multi-entry packaged declarations require every requested root", t => {
 const f = fixture(t);
 f.manifest.entries = [f.entry,f.dependency];
 f.manifest.modules.push({source:f.dependency,out:"types.js"});
 f.manifest.declarations = [{source:f.entry,out:"main.d.ts"}];
 const files = {...f.files,"types.js":"export {};","main.d.ts":"export {};","types.d.ts":"export {};"};
 const options = {entry:[f.entry,f.dependency],declaration:true};
 assert.throws(() => f.run({files},options),/entry declaration is required when --declaration is requested/);
 assert.equal(f.run({files},{...options,declaration:false}).modules.length,2);
 f.manifest.declarations.push({source:f.dependency,out:"types.d.ts"});
 assert.equal(f.run({files},options).declarations.length,2);
});
