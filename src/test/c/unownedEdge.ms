// Unowned<T> is a stored edge counted on its target's second count: it keeps the class out of
// the cycle collector, a store counts it, the holder's destroy releases it, and a read never
// moves it into a strong owner. Runtime behaviour: corpus `unownedEdgeReadsItsTarget` and its `unownedEdge*` siblings.

import { compileToC, builtModuleC } from "../helpers";
import { hostTargetInfo } from "../../checker/types";

function typeInfoOf(c: string, name: string): string {
	for (const line of c.split("\n")) {
		if (line.contains(`msTypeInfo ${name}`) && line.contains(`.name = "${name}"`)) return line;
	}
	return "";
}

// The release classification: a debug build keeps owned cycles under the collector to report them.
function verdict(decls: string, name: string): string {
	const r = compileToC(decls + "\nconsole.log(\"ok\");\n", hostTargetInfo(), false, false, true);
	if (!r.ok) return r.error;
	const line = typeInfoOf(r.value, name);
	if (line == "") return `no TypeInfo for ${name}`;
	return line.contains(".isCyclic = MS_TRUE") ? "cyclic" : "acyclic";
}

function unownedLines(c: string): string {
	return c.split("\n").filter((line: string): boolean => line.includes("Unowned") || line.includes("error")).join("\n");
}

function emitted(src: string): string {
	const r = compileToC(src);
	return r.ok ? r.value : r.error;
}

test "an Unowned back edge is acyclic" {
	assert verdict("class N { up: Unowned<N> | null = null; }\nconst n = new N();", "N") == "acyclic";
}

test "a plain back edge is cyclic" {
	assert verdict("class N { up: N | null = null; }\nconst n = new N();", "N") == "cyclic";
}

test "the compiler's own Node is acyclic: its owning edges are Owned and its edges back from symbols and flow nodes Unowned" {
	const c = builtModuleC("unownedEdge", "compilerNode", "import { NodeKind, createNodeAt, makeLoc } from \"std/meta/node\";\nconst n = createNodeAt(NodeKind.Identifier, { name: \"x\" }, makeLoc(1, 1));\nconsole.log(n.kind);\n", ["--danger"], "metaZnode");
	assert typeInfoOf(c, "Node").contains(".isCyclic = MS_FALSE"), typeInfoOf(c, "Node") != "" ? typeInfoOf(c, "Node") : c.slice(0, 400);
}

test "the compiler's inline frame and ident chains are acyclic: each link owns the one before it" {
	const frames = builtModuleC("unownedEdge", "compilerFrame", "import { InlineFrame } from \"std/meta/node\";\nconst f = new InlineFrame(\"g\", new InlineFrame(\"f\", null, 1), 2);\nconsole.log(f.callLine);\n", ["--danger"], "metaZnode");
	assert typeInfoOf(frames, "InlineFrame").contains(".isCyclic = MS_FALSE"), typeInfoOf(frames, "InlineFrame") != "" ? typeInfoOf(frames, "InlineFrame") : frames.slice(0, 400);
	const idents = builtModuleC("unownedEdge", "compilerIdent", "import { createIdentCache, getIdentId } from \"../../../src/checker/idents\";\nconsole.log(getIdentId(createIdentCache(), \"x\"));\n", ["--danger"], "idents");
	assert typeInfoOf(idents, "IdentEntry").contains(".isCyclic = MS_FALSE"), typeInfoOf(idents, "IdentEntry") != "" ? typeInfoOf(idents, "IdentEntry") : idents.slice(0, 400);
}

test "the compiler's flow graph is acyclic: a label's antecedent list and a reduce label's target name their flow node Unowned" {
	const c = builtModuleC("unownedEdge", "compilerFlow", "import { FlowNode, FlowList, FlowReduceLabelData } from \"std/meta/node\";\nconst f = new FlowNode();\nconst l: FlowList = { flow: f, next: null };\nconst r: FlowReduceLabelData = { target: f, antecedents: l };\nf.reduceLabelData = r;\nconsole.log(r.antecedents.next == null);\n", ["--danger"], "metaZnode");
	for (const name of ["FlowNode", "FlowList", "FlowReduceLabelData"]) {
		assert typeInfoOf(c, name).contains(".isCyclic = MS_FALSE"), typeInfoOf(c, name) != "" ? typeInfoOf(c, name) : c.slice(0, 400);
	}
}

test "the compiler's Symbol is acyclic: a type names its symbol and a symbol its owner Unowned, a symbol owns its overloads" {
	const c = builtModuleC("unownedEdge", "compilerSymbol", "import { makeSymbol } from \"../../../src/checker/symbol\";\nimport { SymbolKind } from \"std/meta/node\";\nconst s = makeSymbol(\"x\", SymbolKind.Variable, null, false);\nconsole.log(s.name);\n", ["--danger"], "metaZnode");
	assert typeInfoOf(c, "Symbol").contains(".isCyclic = MS_FALSE"), typeInfoOf(c, "Symbol") != "" ? typeInfoOf(c, "Symbol") : c.slice(0, 400);
}

test "owned children with an Unowned parent edge are acyclic" {
	assert verdict("class N { kids: Vec<Owned<N>> = []; up: Unowned<N> | null = null; }\nconst n = new N();", "N") == "acyclic";
	assert verdict("class N { left: Owned<N> | null = null; up: Unowned<N> | null = null; }\nconst n = new N();", "N") == "acyclic";
}

test "Unowned of an alias that names its own holder keeps the back edge" {
	assert verdict("type P = N;\nclass N { kids: Vec<Owned<N>> = []; up: Unowned<P> | null = null; }\nconst n = new N();", "N") == "acyclic";
	assert verdict("class N { kids: Vec<Owned<N>> = []; up: Unowned<P> | null = null; }\ntype P = N;\nconst n = new N();", "N") == "acyclic";
	assert verdict("type P = N;\nclass N { ups: Vec<Unowned<P>> = []; }\nconst n = new N();", "N") == "acyclic";
}

test "a store into an Unowned slot counts on the second count" {
	const c = emitted("class T { id: int32 = 0; }\nclass H { at: Unowned<T> | null = null; }\nconst t = new T();\nconst h = new H();\nh.at = t;\nconsole.log(t.id);\n");
	assert c.contains("msUnownedAssign"), c;
	assert c.contains("msUnownedDecref"), c;
}

test "a literal's Unowned field takes its value on the second count, not a strong copy" {
	const element = emitted("class T { id: int32 = 4; }\nstruct V { at: Unowned<T> | null; tag: int32; }\nfunction f(t: T): int32 {\n\tconst vs: V[] = [{ at: t, tag: 1 }];\n\treturn vs.length;\n}\nconsole.log(f(new T()));\n");
	assert element.contains("msUnownedTake(t_p0)"), element;
	assert !element.contains("msIncref(t_p0)"), element;
	const returned = emitted("class T { id: int32 = 4; }\nstruct V { at: Unowned<T> | null; tag: int32; }\nfunction f(t: T): V { return { at: t, tag: 2 }; }\nconst t = new T();\nconsole.log(f(t).tag);\n");
	assert returned.contains("msUnownedTake(t_p0)"), returned;
}

test "the last read of an Unowned field is a copy, not a move" {
	const c = emitted("class T { id: int32 = 4; }\nstruct V { at: Unowned<T> | null; }\nfunction f(t: T): int32 {\n\tlet v: V = { at: null };\n\tv.at = t;\n\tconst r = v.at;\n\treturn r != null ? r.id : 0;\n}\nconsole.log(f(new T()));\n");
	assert !c.contains("msPtrWasMoved(v_1_.at)"), c;
}

test "a read of an Unowned slot as a plain value is a checked load in place; a copy into another slot is not a read" {
	const head = "class T { id: int32 = 4; }\nclass H { at: Unowned<T> | null = null; ups: Unowned<T>[] = []; }\n";
	const field = emitted(head + "function f(h: H): int32 { const r = h.at; return r != null ? r.id : 0; }\nconst t = new T();\nconst h = new H();\nh.at = t;\nconsole.log(f(h));\n");
	assert field.contains("msUnownedPeek((*h_p0).at)"), unownedLines(field);
	const element = emitted(head + "function f(h: H): int32 { return h.ups[0].id; }\nconst t = new T();\nconst h = new H();\nh.ups.push(t);\nconsole.log(f(h));\n");
	assert element.contains("msUnownedPeek("), unownedLines(element);
	const copied = emitted(head + "function f(a: H, b: H): void { a.at = b.at; a.ups.push(b.ups[0]); }\nconst t = new T();\nconst a = new H();\nconst b = new H();\nb.at = t;\nb.ups.push(t);\nf(a, b);\nconsole.log(a.ups.length);\n");
	assert !copied.contains("msUnownedPeek"), unownedLines(copied);
}

function bodyOf(c: string, name: string): string {
	const lines = c.split("\n");
	for (let i = 0; i < lines.length; i += 1) {
		if (!lines[i].endsWith(") {") || !lines[i].contains(` ${name}__`)) continue;
		let j = i + 1;
		while (j < lines.length && lines[j] != "}") j += 1;
		return lines.slice(i, j).join("\n");
	}
	return `no function ${name} in\n${c}`;
}

const VIEWS_HEAD = "class T { id: int32 = 4; name: string = \"t\"; }\nclass H { at: Unowned<T> | null = null; }\nclass R { items: T[] = []; }\nfunction nameOf(t: Readonly<T>): int32 { return t.name.length; }\nfunction drop(r: R): int32 { r.items = []; return 0; }\n";
const VIEWS_TAIL = "const t = new T();\nconst h = new H();\nh.at = t;\nconst r = new R();\nr.items.push(t);\nconsole.log(f(h, r));\n";

test "an Unowned read that nothing can release before its last use takes no count" {
	const tested = emitted(VIEWS_HEAD + "function f(h: H, r: R): int32 { return h.at != null ? 1 : 0; }\n" + VIEWS_TAIL);
	assert !bodyOf(tested, "f").contains("msIncref"), bodyOf(tested, "f");
	const read = emitted(VIEWS_HEAD + "function f(h: H, r: R): int32 { return h.at != null ? h.at.id + nameOf(h.at) : 0; }\n" + VIEWS_TAIL);
	assert !bodyOf(read, "f").contains("msIncref"), bodyOf(read, "f");
	const local = emitted(VIEWS_HEAD + "function f(h: H, r: R): int32 { const p = h.at; return p != null ? p.id + nameOf(p) : 0; }\n" + VIEWS_TAIL);
	assert !bodyOf(local, "f").contains("msIncref"), bodyOf(local, "f");
	assert !bodyOf(local, "f").contains("msDecref"), bodyOf(local, "f");
}

test "an Unowned read that becomes an owner, or outlives a call that may release, is counted" {
	const stored = emitted(VIEWS_HEAD + "function f(h: H, r: R): int32 { const p = h.at; if (p != null) r.items.push(p); return 0; }\n" + VIEWS_TAIL);
	assert bodyOf(stored, "f").contains("msIncref"), bodyOf(stored, "f");
	const released = emitted(VIEWS_HEAD + "function f(h: H, r: R): int32 { const p = h.at; drop(r); return p != null ? p.id : 0; }\n" + VIEWS_TAIL);
	assert bodyOf(released, "f").contains("msIncref"), bodyOf(released, "f");
	const argument = emitted(VIEWS_HEAD + "function keep(t: T, r: R): int32 { r.items = []; return t.id; }\nfunction f(h: H, r: R): int32 { return h.at != null ? keep(h.at, r) : 0; }\n" + VIEWS_TAIL);
	assert bodyOf(argument, "f").contains("msIncref"), bodyOf(argument, "f");
	const owner = emitted(VIEWS_HEAD + "function f(h: H, r: R): int32 { let p = h.at; { const o = new T(); h.at = o; p = h.at; } return p != null ? p.id : 0; }\n" + VIEWS_TAIL);
	assert bodyOf(owner, "f").contains("msIncref"), bodyOf(owner, "f");
}

test "an Unowned read passed to a call that writes only slots that cannot own its type takes no count" {
	const head = VIEWS_HEAD + "class W { t: T = new T(); }\nclass L { names: string[] = []; n: int32 = 0; w: W | null = null; }\n";
	const unrelated = emitted(head + "function note(t: T, l: L): int32 { l.names.push(t.name); l.names = []; l.n = t.id; return l.n; }\nfunction f(h: H, r: R): int32 { const l = new L(); return h.at != null ? note(h.at, l) : 0; }\n" + VIEWS_TAIL);
	assert !bodyOf(unrelated, "f").contains("msIncref"), bodyOf(unrelated, "f");
	const edge = emitted(head + "function relink(t: T, h: H): int32 { h.at = null; return t.id; }\nfunction f(h: H, r: R): int32 { return h.at != null ? relink(h.at, h) : 0; }\n" + VIEWS_TAIL);
	assert !bodyOf(edge, "f").contains("msIncref"), bodyOf(edge, "f");
	const appended = emitted(head + "function grow(t: T, r: R): int32 { r.items.push(new T()); return t.id; }\nfunction f(h: H, r: R): int32 { return h.at != null ? grow(h.at, r) : 0; }\n" + VIEWS_TAIL);
	assert !bodyOf(appended, "f").contains("msIncref"), bodyOf(appended, "f");
	const through = emitted(head + "function dropW(t: T, l: L): int32 { l.w = null; return t.id; }\nfunction f(h: H, r: R): int32 { const l = new L(); return h.at != null ? dropW(h.at, l) : 0; }\n" + VIEWS_TAIL);
	assert bodyOf(through, "f").contains("msIncref"), bodyOf(through, "f");
}

test "an Unowned read is counted across a call that empties a slot typed by an interface or a record its class fits" {
	const head = VIEWS_HEAD + "interface Named { id: int32; }\nclass G { slot: Named | null = null; rec: { id: int32 } | null = null; }\nconst g = new G();\n";
	const tail = "const t = new T();\nconst h = new H();\nh.at = t;\nconst r = new R();\ng.slot = t;\ng.rec = t;\nconsole.log(f(h, r));\n";
	const iface = emitted(head + "function empty(): int32 { g.slot = null; return 0; }\nfunction f(h: H, r: R): int32 { const p = h.at; empty(); return p != null ? p.id : 0; }\n" + tail);
	assert bodyOf(iface, "f").contains("msIncref"), bodyOf(iface, "f");
	const record = emitted(head + "function empty(): int32 { g.rec = null; return 0; }\nfunction f(h: H, r: R): int32 { const p = h.at; empty(); return p != null ? p.id : 0; }\n" + tail);
	assert bodyOf(record, "f").contains("msIncref"), bodyOf(record, "f");
}

test "a conditional joining Unowned reads stays a view when nothing can release before its last use" {
	const head = VIEWS_HEAD + "function idOf(t: T | null): int32 { return t != null ? t.id : 0; }\n";
	const joined = emitted(head + "function f(h: H, r: R): int32 { const k = r.items.length; return idOf(k > 0 ? h.at : null) + k; }\n" + VIEWS_TAIL);
	assert !bodyOf(joined, "f").contains("msIncref"), bodyOf(joined, "f");
	const bound = emitted(head + "function pick(t: T | null): T | null { return t; }\nfunction f(h: H, r: R): int32 { const q = pick(r.items.length > 0 ? h.at : null); return idOf(q); }\n" + VIEWS_TAIL);
	assert !bodyOf(bound, "f").contains("msIncref"), bodyOf(bound, "f");
	const released = emitted(head + "function f(h: H, r: R): int32 { const p = r.items.length > 0 ? h.at : null; drop(r); return idOf(p); }\n" + VIEWS_TAIL);
	assert bodyOf(released, "f").contains("msIncref"), bodyOf(released, "f");
}

const HOLDERS_HEAD = "class T { id: int32 = 4; }\nclass S { t: T | null = null; }\nclass H { at: Unowned<T> | null = null; ss: S[] = []; }\n";
const HOLDERS_TAIL = "const t = new T();\nconst h = new H();\nh.at = t;\nconst s = new S();\ns.t = t;\nh.ss.push(s);\nconsole.log(f(h));\n";

test "an Unowned view stays uncounted beside a local that may own its target only while that local is a cursor" {
	const rebound = emitted(HOLDERS_HEAD + "function f(h: Readonly<H>): int32 { const p = h.at; let s: Readonly<S> | null = null; for (const x of h.ss) { s = x; } return p != null && s != null ? p.id : 0; }\n" + HOLDERS_TAIL);
	assert !bodyOf(rebound, "f").contains("msIncref"), bodyOf(rebound, "f");
	const bound = emitted(HOLDERS_HEAD + "function f(h: Readonly<H>): int32 { const p = h.at; for (const x of h.ss) { const s: Readonly<S> = x; if (s.t != null) return 1; } return p != null ? p.id : 0; }\n" + HOLDERS_TAIL);
	assert !bodyOf(bound, "f").contains("msIncref"), bodyOf(bound, "f");
	const owner = emitted(HOLDERS_HEAD + "function f(h: Readonly<H>): int32 { const p = h.at; let s: S | null = null; for (let i = 0; i < 2; i += 1) { s = new S(); } return p != null && s != null ? p.id : 0; }\n" + HOLDERS_TAIL);
	assert bodyOf(owner, "f").contains("msIncref"), bodyOf(owner, "f");
}

test "a holder of a Cursor field releases nothing an Unowned view reads" {
	const cursor = emitted(HOLDERS_HEAD + "class Item { at: Cursor<Readonly<S>>; constructor(s: Readonly<S>) { this.at = s; } }\nfunction g(h: Readonly<H>, items: Item[]): int32 { const p = h.at; items.pop(); return p != null ? p.id : 0; }\nfunction f(h: Readonly<H>): int32 { return g(h, [new Item(h.ss[0])]); }\n" + HOLDERS_TAIL);
	assert !bodyOf(cursor, "g").contains("msIncref"), bodyOf(cursor, "g");
	const strong = emitted(HOLDERS_HEAD + "class Item { at: S; constructor(s: S) { this.at = s; } }\nfunction g(h: Readonly<H>, items: Item[]): int32 { const p = h.at; items.pop(); return p != null ? p.id : 0; }\nfunction f(h: Readonly<H>): int32 { return g(h, [new Item(new S())]); }\n" + HOLDERS_TAIL);
	assert bodyOf(strong, "g").contains("msIncref"), bodyOf(strong, "g");
}

test "a push into an array of Cursor elements hands over nothing an Unowned view reads" {
	const cursors = emitted(HOLDERS_HEAD + "function f(h: Readonly<H>): int32 { const p = h.at; const seen: Cursor<Readonly<S>>[] = []; for (const x of h.ss) { seen.push(x); } return p != null ? p.id + seen.length : 0; }\n" + HOLDERS_TAIL);
	assert !bodyOf(cursors, "f").contains("msIncref"), bodyOf(cursors, "f");
	const owners = emitted(HOLDERS_HEAD + "function g(h: H, keep: S[]): int32 { const p = h.at; const s = new S(); keep.push(s); return p != null ? p.id : 0; }\nfunction f(h: H): int32 { return g(h, []); }\n" + HOLDERS_TAIL);
	assert bodyOf(owners, "g").contains("msIncref"), bodyOf(owners, "g");
}

test "a view a routine returns through an Unowned edge stays uncounted until a call can release its type" {
	const head = VIEWS_HEAD + "class L { names: string[] = []; }\nconst log = new L();\nfunction atOf(h: H): Readonly<T> | null { return h.at; }\nfunction note(l: L, s: string): int32 { l.names.push(s); l.names = []; return 0; }\n";
	const unrelated = emitted(head + "function f(h: H, r: R): int32 { const p = atOf(h); note(log, \"x\"); return p != null ? p.id : 0; }\n" + VIEWS_TAIL);
	assert !bodyOf(unrelated, "f").contains("msIncref"), bodyOf(unrelated, "f");
	const released = emitted(head + "function f(h: H, r: R): int32 { const p = atOf(h); drop(r); return p != null ? p.id : 0; }\n" + VIEWS_TAIL);
	assert bodyOf(released, "f").contains("msIncref"), bodyOf(released, "f");
}

test "an array of T and an array of Unowned<T> never stand for each other where one is written or read unchecked" {
	const head = "class N { id: int32 = 1; }\nclass H { ups: Unowned<N>[] = []; }\nconst h = new H();\n";
	const refused = "so one array cannot stand for the other";
	assert emitted(head + "const xs: N[] = [new N()];\nh.ups = xs;\nconsole.log(h.ups.length);\n").contains(refused);
	assert emitted(head + "const ys: N[] = h.ups;\nconsole.log(ys.length);\n").contains(refused);
	assert emitted(head + "function f(a: N[]): int32 { return a.length; }\nconsole.log(f(h.ups));\n").contains(refused);
	assert emitted(head + "function f(a: Readonly<N[]>): int32 { return a.length; }\nconsole.log(f(h.ups));\n").contains(refused);
	assert emitted(head + "function f(a: Unowned<N>[]): int32 { return a.length; }\nconst xs: N[] = [new N()];\nconsole.log(f(xs));\n").contains(refused);
	assert !emitted(head + "function f(a: Readonly<Unowned<N>[]>): int32 { return a.length; }\nconst xs: N[] = [new N()];\nconsole.log(f(xs));\n").contains(refused);
}

test "Unowned is a field type: a local, a parameter, a return or a static that names it is refused" {
	const head = "class N { id: int32 = 1; }\nclass H { at: Unowned<N> | null = null; }\n";
	assert emitted(head + "const n = new N();\nconst p: Unowned<N> | null = n;\nconsole.log(p != null);\n").contains("Unowned<T> is the type of a class or struct field");
	assert emitted(head + "function f(x: Unowned<N>): int32 { return 0; }\nconsole.log(f(new N()));\n").contains("Unowned<T> is the type of a class or struct field");
	assert emitted(head + "function f(h: H): Unowned<N> | null { return h.at; }\nconsole.log(f(new H()) == null);\n").contains("Unowned<T> is the type of a class or struct field");
	assert emitted(head + "class S { static at: Unowned<N> | null = null; }\nconsole.log(S.at == null);\n").contains("Unowned<T> is the type of a class or struct field");
}

test "an Unowned element of a field's own array is pushed on the second count and popped back strong" {
	const body = "\nfunction f(h: H, n: N): int32 {\n\th.ups.push(n);\n\treturn h.ups.pop().id;\n}\nconsole.log(f(new H(), new N()));\n";
	for (const field of ["Vec<Unowned<N>>", "Unowned<N>[]"]) {
		const c = emitted(`class N { id: int32 = 1; }\nclass H { ups: ${field} = []; }` + body);
		assert c.contains("msUnownedTake(n_p1)"), c;
		assert c.contains("msUnownedGive("), c;
	}
}

test "emptying an array of Unowned elements gives each one up on the second count" {
	const tail = "const t = new T();\nconst h = new H();\nh.ups.push(t);\nf(h);\nconsole.log(h.ups.length);\n";
	const plain = emitted("class T { id: int32 = 4; }\nclass H { ups: Unowned<T>[] = []; }\nfunction f(h: H): void { h.ups.length = 0; }\n" + tail);
	assert plain.contains("msUnownedRefArraySetLen("), unownedLines(plain);
	assert !plain.contains("msAcyclicRefArraySetLen(") && !plain.contains("msRefArraySetLen("), plain;
	const readonly = emitted("class T { id: int32 = 4; }\nclass H { ups: Unowned<Readonly<T>>[] = []; }\nfunction f(h: H): void { h.ups.length = 0; }\n" + tail);
	assert readonly.contains("msUnownedRoRefArraySetLen("), unownedLines(readonly);
}

test "cutting an array of Unowned elements gives the evicted edges up on the second count, unread" {
	const tail = "const t = new T();\nconst h = new H();\nh.ups.push(t);\nf(h);\nconsole.log(h.ups.length);\n";
	const plain = "class T { id: int32 = 4; }\nclass H { ups: Unowned<T>[] = []; }\n";
	const spliced = builtModuleC("unownedEdge", "cutsplice", plain + "function f(h: H): void { h.ups.splice(0, 1); }\n" + tail, []);
	assert spliced.contains("msUnownedRefArraySetLen("), unownedLines(spliced);
	const shrunk = builtModuleC("unownedEdge", "cutshrink", plain + "function f(h: H): void { h.ups.shrink(0); }\n" + tail, []);
	assert shrunk.contains("msUnownedRefArraySetLen("), unownedLines(shrunk);
	const readonly = builtModuleC("unownedEdge", "cutreadonly", "class T { id: int32 = 4; }\nclass H { ups: Unowned<Readonly<T>>[] = []; }\nfunction f(h: H): void { h.ups.splice(0, 1); }\n" + tail, []);
	assert readonly.contains("msUnownedRoRefArraySetLen("), unownedLines(readonly);
}

test "an Unowned edge in a union member, a tuple or a type argument is refused, naming the struct that holds one" {
	const head = "class N { id: int32 = 1; }\n";
	const refused = "so a union member, a tuple, a function type or a type argument cannot hold one — store the back edge in a struct field and hold the struct, as in 'struct Up { at: Unowned<N> }' and 'Map<string, Up>'";
	assert emitted(head + "class H { ups: (Unowned<N> | string)[] = []; }\nconsole.log(new H().ups.length);\n").contains(refused);
	assert emitted(head + "class H { ups: Map<string, Unowned<N>> = new Map(); }\nconsole.log(new H().ups.size >= 0);\n").contains(refused);
	assert emitted(head + "class H { ups: Set<Unowned<N>> | null = null; }\nconsole.log(new H().ups == null);\n").contains(refused);
	assert emitted(head + "class H { pair: [Unowned<N>, int32] | null = null; }\nconsole.log(new H().pair == null);\n").contains(refused);
	const wrapped = compileToC(head + "struct Up { at: Unowned<N>; }\nclass H { ups: Map<string, Up> = new Map<string, Up>(); }\nconst n = new N();\nconst h = new H();\nh.ups.set(\"p\", { at: n });\nconsole.log(h.ups.get(\"p\")!.at.id);\n");
	assert wrapped.ok, wrapped.ok ? "" : wrapped.error;
	const nullable = compileToC(head + "struct Up { at: Unowned<N>; }\nclass H { up: Up | null = null; }\nconst n = new N();\nconst h = new H();\nh.up = { at: n };\nconsole.log(h.up!.at.id);\n");
	assert nullable.ok, nullable.ok ? "" : nullable.error;
}

test "an array of Unowned elements is held anywhere an array is: nested, nullable, a local, a parameter or a return" {
	const c = emitted("class N { id: int32 = 1; }\nclass H { grid: Unowned<N>[][] = []; maybe: Unowned<N>[] | null = null; }\nfunction pick(xs: Unowned<N>[]): Unowned<N>[] { const out: Unowned<N>[] = []; for (const x of xs) out.push(x); return out; }\nconst n = new N();\nconst h = new H();\nh.grid.push([n]);\nh.maybe = pick(h.grid[0]);\nconsole.log(h.grid.length);\n");
	assert !c.contains("error"), unownedLines(c);
	assert c.contains("msUnownedTake("), unownedLines(c);
}

test "a value holding an Unowned edge does not cross a thread by move, reply or spawn result" {
	const head = "class N { id: int32 = 1; }\nclass H { at: Unowned<N> | null = null; }\n";
	const refused = "holding an Unowned edge is not sendable";
	assert emitted(head + "actor A { n: int32 = 0; take(h: H): void { this.n = h.at != null ? 1 : 0; } }\nfunction f(): void { const h = new H(); const a = new A(); a.take(move h); }\nf();\n").contains(refused);
	assert emitted(head + "actor A { make(): H { return new H(); } }\nasync function g(): Promise<int32> { const a = new A(); const h = await a.make(); return h.at == null ? 0 : 1; }\nconsole.log(await g());\n").contains(refused);
	assert emitted(head + "async function g(): Promise<int32> { const h = new H(); const t = spawn(() => { return h.at != null ? 1 : 0; }, { move: [h] }); return await t; }\nconsole.log(await g());\n").contains(refused);
	assert emitted(head + "class W { h: H = new H(); }\nasync function g(): Promise<int32> { const w = new W(); const t = spawn(() => { return w.h.at != null ? 1 : 0; }, { move: [w] }); return await t; }\nconsole.log(await g());\n").contains(refused);
	assert emitted(head + "async function g(): Promise<int32> { const t = spawn(() => { return new H(); }); const h = await t; return h.at == null ? 0 : 1; }\nconsole.log(await g());\n").contains(refused);
}

test "a value holding an Unowned edge is still lent to an awaited actor call and a spawn that reads it" {
	const head = "class N { id: int32 = 1; }\nclass H { at: Unowned<N> | null = null; }\n";
	assert !emitted(head + "actor A { weigh(h: H): int32 { return h.at != null ? h.at.id : 0; } }\nasync function g(): Promise<int32> { const n = new N(); const h = new H(); h.at = n; const a = new A(); return await a.weigh(h); }\nconsole.log(await g());\n").contains("not sendable");
	assert !emitted(head + "async function g(): Promise<int32> { const n = new N(); const h = new H(); h.at = n; const t = spawn(() => { return h.at != null ? h.at.id : 0; }); return await t; }\nconsole.log(await g());\n").contains("not sendable");
}

test "an Unowned field is never moved out, because it holds no ownership to move" {
	const head = "class N { id: int32 = 1; }\nclass H { at: Unowned<N> | null = null; }\nclass K { kept: N | null = null; }\n";
	const refused = "an Unowned<T> field holds no ownership of its target";
	assert emitted(head + "function f(n: N): int32 { const h = new H(); h.at = n; const x = move h.at; return x != null ? x.id : 0; }\nconsole.log(f(new N()));\n").contains(refused);
	assert emitted(head + "function keep(k: K, sink v: N | null): void { k.kept = v; }\nfunction f(n: N, k: K): void { const h = new H(); h.at = n; keep(k, move h.at); }\nf(new N(), new K());\n").contains(refused);
	assert emitted(head + "function f(n: N): int32 { const h = new H(); const g = new H(); h.at = n; g.at = move h.at; return g.at != null ? g.at.id : 0; }\nconsole.log(f(new N()));\n").contains(refused);
	assert emitted("class N { id: int32 = 1; }\nclass H { at: Unowned<N>; constructor(n: N) { this.at = n; } }\nfunction f(n: N): int32 { const h = new H(n); const x = move h.at; return x.id; }\nconsole.log(f(new N()));\n").contains(refused);
}

test "a local bound to an Unowned read is a plain reference, so storing into it is a strong store" {
	const c = emitted("class N { id: int32 = 1; }\nclass H { at: Unowned<N> | null = null; }\nfunction f(h: H, m: N): int32 {\n\tlet p = h.at;\n\tp = m;\n\treturn p != null ? p.id : 0;\n}\nconst n = new N();\nconst h = new H();\nh.at = n;\nconsole.log(f(h, n));\n");
	assert !c.contains("msUnownedAssign((&(p_1_))"), c;
	assert !c.contains("error"), c;
}

test "Unowned takes a class" {
	assert emitted("const v: Unowned<string> | null = null;\nconsole.log(v);\n").contains("Unowned<T> takes a class type");
	assert emitted("struct S { a: int32 }\nclass H { s: Unowned<S> | null = null; }\nconsole.log(new H().s == null);\n").contains("Unowned<T> takes a class type");
}
