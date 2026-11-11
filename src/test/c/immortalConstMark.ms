import { compileToC } from "../helpers";
import { execFileResult, cwd, env } from "std/process";
import { writeFile, ensureDir, removeAll, readFile, readDir } from "std/fs";

const SOURCE = `
class Leaf { n: int32 = 1; }
class Node { next: Node | null = null; leaf: Leaf = new Leaf(); }
function chain(): Node { const a = new Node(); a.next = new Node(); return a; }
const EMPTY: Readonly<Node> = chain();
const PLAIN = new Node();
const ALIAS: Readonly<Node> = PLAIN;
console.log(EMPTY.next != null, PLAIN.leaf.n, ALIAS === PLAIN);
`;

const STRUCTS = `
class Leaf { n: int32 = 1; }
struct W { leaf: Leaf; tag: int32; }
class Node { w: W = { leaf: new Leaf(), tag: 7 }; }
const KW: Readonly<W> = { leaf: new Leaf(), tag: 3 };
const EMPTY: Readonly<Node> = new Node();
class H { w: Readonly<W> | null = null; plain: W | null = null; }
const h = new H();
h.w = EMPTY.w;
h.plain = { leaf: new Leaf(), tag: 1 };
const copy: Readonly<W> = KW;
console.log(copy.tag, h.w!.tag, h.plain!.tag);
`;

test "immortalConstMark: a Readonly<S> value copies through its own hook pair, whose fields count through the Ro flavor, and a struct const is marked through its Ro reach hook" {
	const result = compileToC(STRUCTS);
	assert result.ok, result.ok ? "" : result.error;
	const c = result.ok ? result.value : "";
	assert c.contains("RoReach((&(KW__") && c.contains("msImmortalBegin())") && c.contains("msImmortalEnd();"), "the struct const is marked through the reach hook of its view";
	assert c.contains("W__") && c.contains("RoCopy("), "a Readonly<W> copy calls the Ro hook pair";
	const roCopy = hookBody(c, "W__", "RoCopy(");
	assert roCopy.contains("msIncrefRo(") && !roCopy.contains("msIncRef(") && !roCopy.contains("msIncref("), "the Ro copy hook counts its field through the Ro flavor:\n" + roCopy;
	const plainCopy = hookBody(c, "W__", "Copy(", "RoCopy(");
	assert plainCopy.contains("msIncref(") && !plainCopy.contains("msIncrefRo("), "the plain W copy hook keeps the plain op:\n" + plainCopy;
}

const COUNTLESS_INSTANCE = `
class Cache { entries: Map<string, Result<string, string>> = new Map<string, Result<string, string>>(); }
function filled(): Cache { const c = new Cache(); c.entries.set("a", Result.ok("b")); return c; }
const K: Readonly<Cache> = filled();
console.log(K.entries.size);
`;

test "immortalConstMark: the reach walk skips a generic-instance value whose body holds no count" {
	const result = compileToC(COUNTLESS_INSTANCE);
	assert result.ok, result.ok ? "" : result.error;
	const c = result.ok ? result.value : "";
	assert c.contains("msImmortalize(K__"), "the const is marked through its reach hook";
}

const RECURSIVE = `
struct Tree { value: int32; children: Vec<Tree>; }
const tree: Tree = { value: 1, children: [{ value: 2, children: [] }] };
console.log(tree.children[0].value);
`;

function reachHooks(c: string): Map<string, string> {
	const hooks = new Map<string, string>();
	const lines = c.split("\n");
	for (let i = 0; i < lines.length; i += 1) {
		const open = lines[i].indexOf("(");
		if (!lines[i].startsWith("void ") || !lines[i].endsWith("{") || open < 0) continue;
		const words = lines[i].substring(0, open).split(" ");
		const name = words[words.length - 1];
		if (!name.endsWith("Reach")) continue;
		const body: string[] = [];
		let j = i + 1;
		while (j < lines.length && lines[j] != "}") { body.push(lines[j]); j += 1; }
		hooks.set(name, body.join("\n"));
	}
	return hooks;
}

function reachCalls(hooks: Map<string, string>, from: string): string[] {
	const body = hooks.get(from) ?? "";
	return [...hooks.keys()].filter((name) => body.contains(name + "("));
}

test "immortalConstMark: a recursive value struct's reach hook walks its elements back through itself" {
	const result = compileToC(RECURSIVE);
	assert result.ok, result.ok ? "" : result.error;
	const c = result.ok ? result.value : "";
	const hooks = reachHooks(c);
	const tree = [...hooks.keys()].filter((name) => name.startsWith("Tree__"));
	assert tree.length == 1, [...hooks.keys()].join(", ");
	const own = tree[0];
	const recurses = reachCalls(hooks, own).some((next) => next == own || reachCalls(hooks, next).includes(own));
	assert recurses, own + " does not reach itself through its elements:\n" + (hooks.get(own) ?? "");
}

const CLOSURES = `
type Handler = (n: int32) => int32;
function mk(b: int32): Sendable<Handler> { return (n: int32): int32 => n + b; }
const F: Sendable<Handler> = mk(3);
console.log(F(1));
`;

test "immortalConstMark: a Sendable function const has its env marked after its initializer" {
	const result = compileToC(CLOSURES);
	assert result.ok, result.ok ? "" : result.error;
	const c = result.ok ? result.value : "";
	assert c.contains("msImmortalizeClosure("), "the Sendable function const marks its env";
}

function hookBody(c: string, prefix: string, suffix: string, notSuffix: string = ""): string {
	const lines = c.split("\n");
	for (let i = 0; i < lines.length; i += 1) {
		const l = lines[i];
		if (!l.startsWith("void " + prefix) || !l.contains(suffix) || !l.endsWith("{")) continue;
		if (notSuffix != "" && l.contains(notSuffix)) continue;
		const body: string[] = [];
		let j = i + 1;
		while (j < lines.length && lines[j] != "}") { body.push(lines[j].trim()); j += 1; }
		return body.join("\n");
	}
	return "";
}

test "immortalConstMark: a deep-Readonly module const built fresh is marked immortal after its initializer, through a lifted reach hook; a mutable const and an alias of one stay mortal" {
	const result = compileToC(SOURCE);
	assert result.ok, result.ok ? "" : result.error;
	const c = result.ok ? result.value : "";
	assert c.contains("msImmortalize(EMPTY__"), "the fresh Readonly const is marked";
	assert !c.contains("msImmortalize(PLAIN__"), "a const typed mutable stays mortal";
	assert !c.contains("msImmortalize(ALIAS__"), "a Readonly alias of a mutable const reaches cells the const does not own, so it stays mortal";
	assert c.contains("Node__") && c.contains("Reach("), "the walk goes through a lifted reach hook";
}

const SHARED_WALKS = `
class Leaf { n: int32 = 1; }
class Ring { next: Ring | null = null; prev: Ring | null = null; }
class Mixed { next: Mixed | null = null; leaf: Leaf = new Leaf(); }
class Wrap { r: Ring | null = null; }
class Outer { w: Wrap = new Wrap(); }
struct Pair { a: Ring | null; b: Ring | null; }
class Holder { p: Pair = { a: null, b: null }; }
const R: Readonly<Ring> = new Ring();
const M: Readonly<Mixed> = new Mixed();
const O: Readonly<Outer> = new Outer();
const H: Readonly<Holder> = new Holder();
console.log(R.next == null, M.leaf.n, O.w.r == null, H.p.a == null);
`;

function emittedMain(name: string, source: string): string {
	const root = cwd();
	const msc = env.get("MSC") != "" ? env.get("MSC") : `${root}/msc`;
	const dir = `${root}/out/immortalConstMark/${name}`;
	removeAll(dir);
	ensureDir(dir);
	writeFile(`${dir}/main.ms`, source);
	const r = execFileResult(msc, ["build", `${dir}/main.ms`, "--emit=c", "--output=prog"], dir);
	if (r.exitCode != 0) return `BUILD-FAILED ${r.output}${r.errorOutput}`;
	for (const file of readDir(`${dir}/out/debug`)) {
		if (file != "mainOms.c" && !file.endsWith("ZmainOms.c")) continue;
		const c = readFile(`${dir}/out/debug/${file}`);
		if (c.ok) return c.value;
	}
	return `BUILD-FAILED no C for main in ${dir}/out/debug`;
}

function typeInfoOf(c: string, prefix: string): string {
	for (const line of c.split("\n")) {
		if (line.startsWith("msTypeInfo " + prefix) && line.contains("TypeInfo = {")) return line;
	}
	return "";
}

function typeInfoCName(info: string): string {
	return info.substring("msTypeInfo ".length, info.indexOf("TypeInfo = {"));
}

test "immortalConstMark: a reach walk that makes the same calls as the type's trace or custody walk reuses that hook and its thunk" {
	const c = emittedMain("sharedWalks", SHARED_WALKS);
	assert !c.startsWith("BUILD-FAILED"), c;
	const hooks = reachHooks(c);
	for (const name of ["Ring__", "Wrap__", "Holder__", "Outer__"]) {
		const info = typeInfoOf(c, name);
		assert info != "", "no TypeInfo for " + name;
		const cName = typeInfoCName(info);
		const walk = name == "Outer__" ? "RttiCustody" : "RttiTrace";
		assert info.contains(".reachFn = " + cName + walk), name + " keeps its own reach walk:\n" + info;
		assert !hooks.has(cName + "Reach"), name + " still lifts a reach hook";
		assert !c.contains(cName + "RttiReach"), name + " still emits a reach thunk";
	}
}

test "immortalConstMark: a reach walk that also enters an acyclic field keeps its own hook and thunk" {
	const c = emittedMain("sharedWalks", SHARED_WALKS);
	assert !c.startsWith("BUILD-FAILED"), c;
	const info = typeInfoOf(c, "Mixed__");
	assert info.contains(".reachFn = " + typeInfoCName(info) + "RttiReach"), info;
	const reach = hookBody(c, "Mixed__", "Reach(");
	assert reach.contains(".next") && reach.contains(".leaf"), "the Mixed reach walk enters both fields:\n" + reach;
}
