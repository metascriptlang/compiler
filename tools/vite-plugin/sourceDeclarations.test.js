import assert from "node:assert/strict";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";

async function fixture(t) {
 const { createSourceDeclarationPublisher } = await import("./sourceDeclarations.js");
 const root = mkdtempSync(join(tmpdir(), "msc-publisher-"));
 const options = { outDir: join(root, "types"), rootDir: root };
 const owners = [];
 const open = () => { const owner = createSourceDeclarationPublisher(options, root); owners.push(owner); return owner; };
 t.after(() => { owners.forEach(owner => owner.close()); rmSync(root, {recursive:true, force:true}); });
 const graph = (name = "main.d.ms.ts", text = "export declare const value: number;") => ({ sourceDeclarationRoot: "_source_declarations", sourceDeclarations: [ {out: `_source_declarations/${name}`, text} ], sourceDeclarationPackage: {out: "_source_declarations/package.json", text: '{"type":"module"}'} });
 return {root, options, open, graph};
}

test("exclusive lifetime lease fails closed, never steals a stale lease", async t => {
 const f = await fixture(t); const owner = f.open();
 assert.throws(f.open, /lease.*(held|exists|exclusive)/i);
 owner.close(); const next = f.open(); next.close();
 const lease = join(f.options.outDir, ".msc-source-lease"); mkdirSync(lease); writeFileSync(join(lease, "owner.json"), '{"pid":999999999,"token":"dead"}');
 assert.throws(f.open, /lease.*(held|exists|exclusive)/i);
 assert.equal(existsSync(lease), true);
});

test("publishes exact family, invalidates on dirty, same owner recovers and preserves offline files", async t => {
 const f = await fixture(t); const owner = f.open();
 owner.publish(f.graph());
 const file = join(f.options.outDir, "main.d.ms.ts");
 assert.match(readFileSync(file, "utf8"), /value: number/);
 assert.deepEqual(JSON.parse(readFileSync(join(f.options.outDir, "package.json"))), {type:"module"});
 owner.invalidate(); assert.equal(existsSync(file), false);
 owner.publish(f.graph("main.d.jms.ts")); assert.equal(existsSync(file), false);
 owner.close(); assert.equal(existsSync(join(f.options.outDir, "main.d.jms.ts")), true);
 const next = f.open(); assert.equal(existsSync(join(f.options.outDir, "main.d.jms.ts")), false);
 next.publish(f.graph());
});

test("validates entire plan before mutation, refuses unowned and reserved paths", async t => {
 const f = await fixture(t); const owner = f.open(); owner.publish(f.graph());
 const file = join(f.options.outDir, "main.d.ms.ts");
 writeFileSync(join(f.options.outDir, "neighbor.txt"), "unrelated");
 for (const name of ["neighbor.txt", "../escape", ".msc-source-ledger.json", ".msc-source-lease/owner.json", "package.json"]) {
  assert.throws(() => owner.publish(f.graph(name)), /collision|path|reserved|duplicate|family/);
  assert.equal(existsSync(file), true);
 }
 assert.equal(readFileSync(join(f.options.outDir, "neighbor.txt"), "utf8"), "unrelated");
});

test("rejects symlink parents and files without deleting targets", async t => {
 const f = await fixture(t); const owner = f.open();
 const outside = join(f.root, "outside"); mkdirSync(outside); writeFileSync(join(outside, "x.d.ts"), "safe");
 symlinkSync(outside, join(f.options.outDir, "_types"));
 assert.throws(() => owner.publish(f.graph("_types/x.d.ts")), /symlink/);
 assert.equal(readFileSync(join(outside, "x.d.ts"), "utf8"), "safe");
});

test("refuses unowned declarations and ledger identity changes without overwriting neighbors", async t => {
 const f = await fixture(t); const owner = f.open(); owner.publish(f.graph());
 const neighbor = join(f.options.outDir,"neighbor.d.ms.ts"); writeFileSync(neighbor,"unowned");
 assert.throws(() => owner.publish(f.graph("neighbor.d.ms.ts")), /Unowned.*collision/);
 assert.equal(readFileSync(neighbor,"utf8"),"unowned");
 owner.close();
 const ledger = join(f.options.outDir,".msc-source-ledger.json");
 const metadata = JSON.parse(readFileSync(ledger,"utf8")); metadata.sourceRoot += "/other"; writeFileSync(ledger,JSON.stringify(metadata));
 assert.throws(f.open,/identity mismatch/);
 assert.ok(existsSync(join(f.options.outDir,"main.d.ms.ts")));
});

test("partial writes roll back, package publishes first and ledger commits last", async t => {
 const fs = (await import("node:fs")).default;
 const {syncBuiltinESMExports} = await import("node:module");
 const f = await fixture(t); const owner = f.open(); owner.publish(f.graph());
 const original = fs.renameSync; const writes = [];
 const restore = () => { fs.renameSync = original; syncBuiltinESMExports(); };
 t.after(restore);
 fs.renameSync = (from,to) => { if(to.endsWith("/fail.d.ts")) throw new Error("injected rename failure"); writes.push(to); original(from,to); };
 syncBuiltinESMExports();
 const graph = f.graph(); graph.sourceDeclarations.push({out:"_source_declarations/_types/fail.d.ts",text:"export {};"});
 assert.throws(() => owner.publish(graph), /publication failed.*injected rename failure/);
 assert.equal(existsSync(join(f.options.outDir,"main.d.ms.ts")),false);
 assert.equal(existsSync(join(f.options.outDir,"package.json")),false);
 restore(); owner.publish(f.graph());
 fs.renameSync = (from,to) => { writes.push(to); original(from,to); }; syncBuiltinESMExports(); writes.length = 0;
 owner.publish(f.graph()); restore();
 assert.deepEqual(writes.map(path => path.slice(f.options.outDir.length+1)),["package.json","main.d.ms.ts",".msc-source-ledger.json"]);
});

test("process exit releases only its own lifetime lease; SIGKILL remains fail-closed", {timeout:10000}, async t => {
 const {spawn} = await import("node:child_process"); const {once} = await import("node:events");
 const f = await fixture(t);
 const module = new URL("./sourceDeclarations.js",import.meta.url).href;
 const start = async () => {
  const child = spawn(process.execPath,["--input-type=module","-e",`import {createSourceDeclarationPublisher} from ${JSON.stringify(module)};
const owner=createSourceDeclarationPublisher(${JSON.stringify(f.options)},${JSON.stringify(f.root)});
process.on('message',()=>process.exit(0)); process.send('ready');`],{stdio:["ignore","pipe","pipe","ipc"]});
  t.after(() => { if(child.exitCode === null && child.signalCode === null) child.kill("SIGKILL"); });
  await once(child,"message"); return child;
 };
 let child = await start(); assert.throws(f.open,/exclusive.*lease/);
 let exited = once(child,"exit"); child.send("exit"); await exited;
 const owner = f.open(); owner.close();
 child = await start(); exited = once(child,"exit"); child.kill("SIGKILL"); await exited;
 assert.throws(f.open,/never automatically reclaimed/);
 assert.ok(existsSync(join(f.options.outDir,".msc-source-lease/owner.json")));
});
