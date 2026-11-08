import assert from "node:assert/strict";
import fs from "node:fs";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import { dirname, isAbsolute, join, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { after, test } from "node:test";

assert.ok(Number(process.versions.node.split(".")[0]) >= 24, "Native watch policy tests require Node 24 or newer");
const rollupModule = process.env.ROLLUP_MODULE || createRequire(import.meta.url).resolve("rollup");
assert.ok(isAbsolute(rollupModule));
const packageRoot = dirname(createRequire(pathToFileURL(rollupModule)).resolve("rollup/package.json"));
assert.equal(JSON.parse(fs.readFileSync(join(packageRoot, "package.json"), "utf8")).version, "4.67.5+metascript.2");
function assertSameRuntime(source, copied) {
 const original = fs.lstatSync(source);
 const clone = fs.lstatSync(copied);
 assert.ok(original.isFile() || original.isDirectory(), source);
 assert.equal(clone.mode, original.mode, source);
 if (original.isDirectory()) {
  const entries = fs.readdirSync(source).sort();
  assert.deepEqual(fs.readdirSync(copied).sort(), entries, source);
  for (const entry of entries) assertSameRuntime(join(source, entry), join(copied, entry));
 } else assert.deepEqual(fs.readFileSync(copied), fs.readFileSync(source), source);
}
const temporaryRoot = fs.mkdtempSync(join(dirname(packageRoot), ".metascript-watch-policy-"));
const clone = join(temporaryRoot, "rollup");
let __nativePolicy;
try {
 fs.cpSync(packageRoot, clone, { recursive: true });
 assertSameRuntime(packageRoot, clone);
 const watchModule = join(clone, "dist/es/shared/watch.js");
 fs.appendFileSync(watchModule, "\nexport { chokidar as __nativePolicy };\n");
 ({ __nativePolicy } = await import(pathToFileURL(watchModule).href));
 assert.equal(typeof __nativePolicy.FSWatcher, "function");
} catch (error) {
 fs.rmSync(temporaryRoot, { recursive: true, force: true });
 throw error;
}
after(() => fs.rmSync(temporaryRoot, { recursive: true, force: true }));
const root = resolve(tmpdir(), "native-policy-unit");
const file = join(root, "entry.js");
const stats = (size, mtimeMs = size, ino = 1) => ({ size, mtimeMs, ino, isFile: () => true });

function fixture(t, options = {}) {
 t.mock.timers.enable({ apis: ["setTimeout", "Date"], now: 0 });
 const watcher = new __nativePolicy.FSWatcher({ useFsEvents: false, atomic: false, persistent: true, ...options });
 const changes = [];
 watcher.on("change", (path, stat) => changes.push({ path, stat }));
 t.after(() => watcher.close());
 return { watcher, changes };
}

test("native policy coalesces equal stats within the existing window", async t => {
 const { watcher, changes } = fixture(t);
 await watcher._emit("change", file, stats(1));
 await watcher._emit("change", file, stats(1));
 t.mock.timers.tick(50);
 assert.equal(changes.length, 1);
});

test("native policy replays only the latest meaningfully changed stats", async t => {
 const { watcher, changes } = fixture(t);
 await watcher._emit("change", file, stats(1));
 await watcher._emit("change", file, stats(2));
 await watcher._emit("change", file, stats(3));
 assert.deepEqual(changes.map(item => item.stat.size), [1]);
 t.mock.timers.tick(50);
 assert.deepEqual(changes.map(item => item.stat.size), [1, 3]);
});

test("native policy conservatively replays observations without stats", async t => {
 const { watcher, changes } = fixture(t);
 await watcher._emit("change", file);
 await watcher._emit("change", file);
 t.mock.timers.tick(50);
 assert.equal(changes.length, 2);
});

test("native policy replay keeps the original path with cwd presentation", async t => {
 const { watcher, changes } = fixture(t, { cwd: root });
 await watcher._emit("change", file, stats(1));
 await watcher._emit("change", file, stats(2));
 t.mock.timers.tick(50);
 assert.deepEqual(changes.map(item => item.path), ["entry.js", "entry.js"]);
 assert.deepEqual(changes.map(item => item.stat.size), [1, 2]);
});

test("native policy cancellation preserves another path's trailing observation", async t => {
 const { watcher, changes } = fixture(t);
 const other = join(root, "other.js");
 await watcher._emit("change", file, stats(1));
 await watcher._emit("change", other, stats(10));
 await watcher._emit("change", file, stats(2));
 await watcher._emit("change", other, stats(20));
 watcher._cancelPath(file);
 t.mock.timers.tick(50);
 assert.deepEqual(changes.map(item => item.stat.size), [1, 10, 20]);
});

test("native policy close cancels trailing change and atomic notifications", async t => {
 const { watcher, changes } = fixture(t, { atomic: 100 });
 const unlinks = [];
 watcher.on("unlink", path => unlinks.push(path));
 await watcher._emit("change", file, stats(1));
 await watcher._emit("change", file, stats(2));
 await watcher._emit("unlink", join(root, "deleted.js"));
 await watcher.close();
 t.mock.timers.tick(200);
 assert.equal(changes.length, 1);
 assert.deepEqual(unlinks, []);
});

test("native policy canceled atomic timer cannot flush a newer path lifetime", async t => {
 const { watcher } = fixture(t, { atomic: 100 });
 const unlinks = [];
 watcher.on("unlink", path => unlinks.push(path));
 await watcher._emit("unlink", file);
 t.mock.timers.tick(30);
 watcher._cancelPath(file);
 await watcher._emit("unlink", file);
 t.mock.timers.tick(70);
 assert.deepEqual(unlinks, []);
 t.mock.timers.tick(30);
 assert.deepEqual(unlinks, [file]);
});

test("native policy write-finish callback cannot publish a canceled lifetime", async t => {
 const { watcher, changes } = fixture(t, { awaitWriteFinish: { stabilityThreshold: 20, pollInterval: 5 } });
 watcher._readyEmitted = true;
 const callbacks = [];
 const original = fs.stat;
 t.mock.method(fs, "stat", function (path, ...args) {
  if (path === file) { callbacks.push(args.at(-1)); return; }
  return original.call(this, path, ...args);
 });
 await watcher._emit("change", file, stats(1));
 t.mock.timers.tick(5);
 assert.equal(callbacks.length, 1);
 watcher._cancelPath(file);
 await watcher._emit("change", file, stats(2));
 t.mock.timers.tick(5);
 assert.equal(callbacks.length, 2);
 callbacks[0](null, stats(1));
 assert.deepEqual(changes, []);
 t.mock.timers.tick(20);
 callbacks[1](null, stats(2));
 assert.deepEqual(changes.map(item => item.stat.size), [2]);
});

const subscriptionRoot = join(tmpdir(), "native-subscription-unit");

for (const [event, removed, observed] of [
 ["unlink", join(subscriptionRoot, "entry.js"), join(subscriptionRoot, "entry.js")],
 ["unlinkDir", join(subscriptionRoot, "nested"), join(subscriptionRoot, "nested", "child.js")]
]) {
 test(`native ${event} preserves observing generation until explicit unwatch`, async t => {
  const watcher = new __nativePolicy.FSWatcher({ useFsEvents: false, atomic: false, persistent: true });
  t.after(() => watcher.close());
  const generation = watcher._pathMutation;
  assert.equal(watcher._isPathActive(observed, generation), true);
  await watcher._emit(event, removed);
  assert.equal(watcher._isPathActive(observed, generation), true);
  watcher.unwatch(removed);
  assert.equal(watcher._isPathActive(observed, generation), false);
  const renewedGeneration = watcher._pathMutation;
  assert.equal(watcher._isPathActive(observed, renewedGeneration), true);
  await watcher.close();
  assert.equal(watcher._isPathActive(observed, renewedGeneration), false);
 });
}

const heldRoot = resolve(tmpdir(), "empty-hold-policy"), heldFile = join(heldRoot, "config.mjs");
const heldStats = (size, mtimeMs = size, ino = 1) => ({ size, mtimeMs, ino, isFile: () => true });
function heldFixture(t,options={}){
 t.mock.timers.enable({apis:['setTimeout','Date'],now:0});
 const watcher=new __nativePolicy.FSWatcher({useFsEvents:false,atomic:false,persistent:true,...options});
 watcher._readyEmitted=true;
 const events=[];
 watcher.on('all',(event,path,stat)=>events.push({event,path,stat,at:Date.now()}));
 t.after(()=>watcher.close());
 return{watcher,events};
}
test('leading empty change emits genuine empty file exactly at10ms, never drops',async t=>{
 const f=heldFixture(t);await f.watcher._emit('change',heldFile,heldStats(0));assert.deepEqual(f.events,[]);t.mock.timers.tick(9);assert.deepEqual(f.events,[]);t.mock.timers.tick(1);assert.equal(f.events.length,1);assert.equal(f.events[0].at,10);assert.equal(f.events[0].stat.size,0);t.mock.timers.tick(40);assert.equal(f.events.length,1);
});
test('empty change completed inside10ms publishes latest nonempty stats once',async t=>{
 const f=heldFixture(t);await f.watcher._emit('change',heldFile,heldStats(0));t.mock.timers.tick(5);const current=heldStats(7);await f.watcher._emit('change',heldFile,current);assert.equal(f.events.length,1);assert.equal(f.events[0].stat,current);assert.equal(f.events[0].at,5);t.mock.timers.tick(45);assert.equal(f.events.length,1);
});
test('new empty identity inside hold updates stats without resetting10ms deadline',async t=>{
 const f=heldFixture(t);await f.watcher._emit('change',heldFile,heldStats(0,1));t.mock.timers.tick(5);const current=heldStats(0,2);await f.watcher._emit('change',heldFile,current);assert.deepEqual(f.events,[]);t.mock.timers.tick(5);assert.equal(f.events[0].stat,current);assert.equal(f.events[0].at,10);
});
test('meaningful write after empty release retains ordinary50ms trailing replay',async t=>{
 const f=heldFixture(t);await f.watcher._emit('change',heldFile,heldStats(0));t.mock.timers.tick(10);t.mock.timers.tick(10);await f.watcher._emit('change',heldFile,heldStats(7));assert.deepEqual(f.events.map(e=>e.stat.size),[0]);t.mock.timers.tick(30);assert.deepEqual(f.events.map(e=>e.stat.size),[0,7]);
});
test('ready empty add followed by data publishes add with completed stats',async t=>{
 const f=heldFixture(t);await f.watcher._emit('add',heldFile,heldStats(0));assert.deepEqual(f.events,[]);t.mock.timers.tick(5);const current=heldStats(7);await f.watcher._emit('change',heldFile,current);assert.deepEqual(f.events.map(e=>e.event),['add']);assert.equal(f.events[0].stat,current);t.mock.timers.tick(50);assert.equal(f.events.length,1);
});
test('ready genuine empty add releases exactly10ms',async t=>{
 const f=heldFixture(t);await f.watcher._emit('add',heldFile,heldStats(0));t.mock.timers.tick(9);assert.deepEqual(f.events,[]);t.mock.timers.tick(1);assert.equal(f.events[0].event,'add');assert.equal(f.events[0].at,10);
});
test('initial empty add before ready is not held',async t=>{
 const f=heldFixture(t);f.watcher._readyEmitted=false;await f.watcher._emit('add',heldFile,heldStats(0));assert.equal(f.events.length,1);assert.equal(f.events[0].at,0);
});
test('cancel held change cannot publish or clear a newer path lifetime',async t=>{
 const f=heldFixture(t);await f.watcher._emit('change',heldFile,heldStats(0));t.mock.timers.tick(5);f.watcher._cancelPath(heldFile);await f.watcher._emit('change',heldFile,heldStats(0,2));t.mock.timers.tick(5);assert.deepEqual(f.events,[]);t.mock.timers.tick(5);assert.equal(f.events.length,1);assert.equal(f.events[0].stat.mtimeMs,2);assert.equal(f.events[0].at,15);
});
test('unwatch parent cancels descendant held change and held add',async t=>{
 const f=heldFixture(t);await f.watcher._emit('change',heldFile,heldStats(0));await f.watcher._emit('add',join(heldRoot,'other.js'),heldStats(0));f.watcher.unwatch(heldRoot);t.mock.timers.tick(100);assert.deepEqual(f.events,[]);
});
test('close cancels held change and held add timers',async t=>{
 const f=heldFixture(t);await f.watcher._emit('change',heldFile,heldStats(0));await f.watcher._emit('add',join(heldRoot,'other.js'),heldStats(0));await f.watcher.close();t.mock.timers.tick(100);assert.deepEqual(f.events,[]);
});
test('cancel one held path preserves another path trailing observation',async t=>{
 const f=heldFixture(t),other=resolve(tmpdir(),'other-policy','input.js');await f.watcher._emit('change',heldFile,heldStats(0));await f.watcher._emit('change',other,heldStats(1));await f.watcher._emit('change',other,heldStats(2));f.watcher._cancelPath(heldFile);t.mock.timers.tick(50);assert.deepEqual(f.events.map(e=>[e.path,e.stat.size]),[[other,1],[other,2]]);
});
test('held release preserves cwd presentation but owns original path lifetime',async t=>{
 const f=heldFixture(t,{cwd:heldRoot});await f.watcher._emit('change',heldFile,heldStats(0));t.mock.timers.tick(10);assert.equal(f.events[0].path,'config.mjs');
});
test('unknown completion remains conservative instead of dropping an observation',async t=>{
 const f=heldFixture(t);await f.watcher._emit('change',heldFile,heldStats(0));t.mock.timers.tick(5);await f.watcher._emit('change',heldFile);assert.equal(f.events.length,1);assert.equal(f.events[0].stat,undefined);t.mock.timers.tick(45);assert.equal(f.events.length,1);
});
test('zero-size directory change is not treated as an empty file',async t=>{
 const f=heldFixture(t);await f.watcher._emit('change',heldRoot,{...heldStats(0),isFile:()=>false});assert.equal(f.events.length,1);assert.equal(f.events[0].at,0);
});
test('unlink drops held change without publishing a stale empty generation',async t=>{
 const f=heldFixture(t);await f.watcher._emit('change',heldFile,heldStats(0));t.mock.timers.tick(5);await f.watcher._emit('unlink',heldFile);t.mock.timers.tick(50);assert.deepEqual(f.events.map(e=>e.event),['unlink']);
});
test('unlink after held add follows the add in order, per reference policy',async t=>{
 const f=heldFixture(t);await f.watcher._emit('add',heldFile,heldStats(0));t.mock.timers.tick(5);await f.watcher._emit('unlink',heldFile);assert.deepEqual(f.events.map(e=>e.event),['add','unlink']);t.mock.timers.tick(50);assert.equal(f.events.length,2);
});
