// A slot typed by an interface or an unnamed record takes any object whose leading fields fit, so
// a cycle through it closes by way of that object: its holder and implementer register for cycle
// collection. A hierarchy whose implementers cannot reach back registers nothing. Runtime
// behaviour: corpus `cycleThroughInterfaceFieldIsCollected`.

import { compileToC } from "../helpers";

function typeInfoOf(c: string, name: string): string {
	for (const line of c.split("\n")) {
		if (line.contains(`msTypeInfo ${name}`) && line.contains(`.name = "${name}"`)) return line;
	}
	return "";
}

function cyclicOps(c: string): int32 {
	let n: int32 = 0;
	for (const line of c.split("\n")) {
		if (line.contains("msDecrefCyclic(") || line.contains("msIncrefCyclic(")) n += 1;
	}
	return n;
}

function traceRefs(c: string): int32 {
	let n: int32 = 0;
	for (const line of c.split("\n")) {
		if (line.contains("msOrcTraceRef(")) n += 1;
	}
	return n;
}

function cyclicFlag(c: string, name: string): string {
	const line = typeInfoOf(c, name);
	if (line == "") return "no TypeInfo for " + name + " in " + c.substring(0, 200);
	return line.contains(".isCyclic = MS_TRUE") ? "cyclic" : "acyclic";
}

function anonWithFields(c: string, fields: string): string {
	const lines = c.split("\n");
	for (let i = 0; i < lines.length; i += 1) {
		const line = lines[i];
		if (!line.startsWith("struct msAnon_") || !line.endsWith(" {")) continue;
		const body: string[] = [];
		let j = i + 1;
		while (j < lines.length && lines[j] != "};") { body.push(lines[j].trim()); j += 1; }
		if (body.join(" ") == fields) return line.substring(7, line.length - 2);
	}
	return "no anonymous struct with " + fields;
}

function anonWithPointerField(c: string, field: string): string {
	const lines = c.split("\n");
	for (let i = 0; i + 2 < lines.length; i += 1) {
		const line = lines[i];
		if (!line.startsWith("struct msAnon_") || !line.endsWith(" {") || lines[i + 2] != "};") continue;
		if (lines[i + 1].trim().endsWith(`* ${field};`)) return line.substring(7, line.length - 2);
	}
	return "no anonymous struct holding a pointer named " + field;
}

function compiled(src: string): string {
	const r = compileToC(src);
	return r.ok ? r.value : "compile error: " + r.error;
}

const SHAPE = `interface Shape { area: number; }
class Square implements Shape {
	area: number = 4;
	owner: Holder | null = null;
}
`;

test "E2E C: an interface field and an implementer that points back register both" {
	const c = compiled(SHAPE + `class Holder { shape: Shape | null = null; }
const h = new Holder();
const s = new Square();
h.shape = s;
s.owner = h;
console.log(h.shape.area);
`);
	assert cyclicFlag(c, "Holder") == "cyclic";
	assert cyclicFlag(c, "Square") == "cyclic";
}

test "E2E C: an array of an interface registers the cycle through its elements" {
	const c = compiled(SHAPE + `class Holder { shapes: Shape[] = []; }
const h = new Holder();
const s = new Square();
h.shapes.push(s);
s.owner = h;
console.log(h.shapes.length);
`);
	assert cyclicFlag(c, "Holder") == "cyclic";
	assert cyclicFlag(c, "Square") == "cyclic";
}

test "E2E C: an unnamed record type that a class fits registers the cycle" {
	const c = compiled(`type Area = { area: number };
class Tile { area: number = 1; owner: Holder | null = null; }
class Holder { slot: Area | null = null; }
const h = new Holder();
const t = new Tile();
h.slot = t;
t.owner = h;
console.log(t.area);
`);
	assert cyclicFlag(c, "Holder") == "cyclic";
	assert cyclicFlag(c, "Tile") == "cyclic";
}

test "E2E C: a record cell whose trace reaches no cell registers no root, though a cyclic class fits its type" {
	const c = compiled(`type Tagged = { tag: string };
type D = Tagged | { k: number };
class Sym { tag: string = "s"; owner: Holder | null = null; }
class Holder { data: D = { k: 1 }; }
const h = new Holder();
const s = new Sym();
s.owner = h;
const tagd: Tagged = s;
h.data = tagd;
h.data = { tag: "a" };
console.log(s.tag);
`);
	assert cyclicFlag(c, anonWithFields(c, "msString tag;")) == "acyclic";
	assert cyclicFlag(c, "Holder") == "cyclic";
	assert cyclicFlag(c, "Sym") == "cyclic";
}

test "E2E C: a record cell holding a closure stays registered behind the same open slot" {
	const c = compiled(`type Tagged = { tag: string, cb: () => void };
type D = Tagged | { k: number };
class Sym { tag: string = "s"; cb: () => void = () => {}; owner: Holder | null = null; }
class Holder { data: D = { k: 1 }; }
const h = new Holder();
const s = new Sym();
s.owner = h;
const tagd: Tagged = s;
h.data = tagd;
h.data = { tag: "a", cb: () => {} };
console.log(s.tag);
`);
	assert cyclicFlag(c, anonWithFields(c, "msString tag; msClosure cb;")) == "cyclic";
	assert cyclicFlag(c, "Holder") == "cyclic";
}

test "E2E C: a class whose only edges are nullable unknown fields stays registered" {
	const c = compiled(`class Parent { child: unknown | null = null; }
class Child { back: unknown | null = null; }
const p = new Parent();
const k = new Child();
p.child = k;
k.back = p;
console.log("linked");
`);
	assert cyclicFlag(c, "Parent") == "cyclic";
	assert cyclicFlag(c, "Child") == "cyclic";
}

test "E2E C: a record cell holding a nullable unknown stays registered behind an open slot" {
	const c = compiled(`type Tagged = { tag: string, any: unknown | null };
type D = Tagged | { k: number };
class Holder { data: D = { k: 1 }; }
const h = new Holder();
h.data = { tag: "a", any: h };
console.log("set");
`);
	assert cyclicFlag(c, anonWithFields(c, "msString tag; void* any;")) == "cyclic";
}

test "E2E C: a generic over an interface registers the cycle" {
	const c = compiled(SHAPE + `class Box<T> { value: T; constructor(value: T) { this.value = value; } }
class Holder { box: Box<Shape> | null = null; }
const h = new Holder();
const s = new Square();
h.box = new Box<Shape>(s);
s.owner = h;
console.log(s.area);
`);
	assert cyclicFlag(c, "Holder") == "cyclic";
	assert cyclicFlag(c, "Square") == "cyclic";
}

const SELF_RING = `interface Shape { area: number; }
class Ring { area: number = 1; next: Ring | null = null; }
`;

function traces(c: string, name: string): boolean {
	const line = typeInfoOf(c, name);
	return line != "" && !line.contains(".traceFn = NULL");
}

test "E2E C: an interface whose implementer forms its own cycle releases through the cyclic path" {
	const c = compiled(SELF_RING + `class Holder { shape: Shape | null = null; }
const h = new Holder();
const r = new Ring();
r.next = r;
h.shape = r;
console.log(h.shape.area);
`);
	assert cyclicFlag(c, "Holder") == "acyclic";
	assert cyclicFlag(c, "Ring") == "cyclic";
	assert traces(c, "Holder");
}

test "E2E C: two interfaces held in each other take the cycle of the implementer behind both" {
	const c = compiled(SELF_RING + `interface Sized { area: number; }
class Holder { slot: Sized | null = null; }
const r = new Ring();
r.next = r;
const s: Shape = r;
const z: Sized = s;
const back: Shape = z;
const h = new Holder();
h.slot = z;
console.log(back.area + h.slot.area);
`);
	assert cyclicFlag(c, "Holder") == "acyclic";
	assert traces(c, "Holder");
}

const ACYCLIC = `interface Shape { area: number; }
class Square implements Shape { area: number = 4; }
class Circle implements Shape { area: number = 3; radius: number = 1; }
class Holder { shape: Shape | null = null; shapes: Shape[] = []; }
const h = new Holder();
h.shape = new Square();
h.shapes.push(new Circle());
console.log(h.shape.area + h.shapes[0].area);
`;

test "E2E C: an interface whose implementers cannot reach back registers no root" {
	const c = compiled(ACYCLIC);
	assert cyclicFlag(c, "Holder") == "acyclic";
	assert cyclicFlag(c, "Square") == "acyclic";
	assert cyclicFlag(c, "Circle") == "acyclic";
}

test "E2E C: the acyclic hierarchy adds no cyclic reference operation" {
	const base = cyclicOps(compiled(`console.log("ok");\n`));
	assert cyclicOps(compiled(ACYCLIC)) == base;
}

test "E2E C: an interface only an unrelated record fits stays acyclic" {
	const c = compiled(`interface Rec { n: number; s: string; }
class Holder { rec: Rec = { n: 1, s: "a" }; }
const h = new Holder();
console.log(h.rec.n);
`);
	assert cyclicFlag(c, "Holder") == "acyclic";
}

test "E2E C: a record cast into an open union slot that reaches nothing leaves the slot's holders acyclic" {
	const c = compiled(`type Lit = { v: number, s: string };
type D = Lit | { k: number };
class Node { data: D | null = null; }
class Env { node: Node | null = null; }
const e = new Env();
const n = new Node();
n.data = { v: 1.5, s: "a" } as D;
e.node = n;
console.log(n.data !== null);
`);
	assert cyclicFlag(c, "Env") == "acyclic";
	assert cyclicFlag(c, "Node") == "acyclic";
}

test "E2E C: a record cast into an open union slot that holds the holder again keeps it cyclic" {
	const c = compiled(`class Env { node: Node | null = null; }
type Lit = { v: number, env: Env | null };
type D = Lit | { k: number };
class Node { data: D | null = null; }
const e = new Env();
const n = new Node();
n.data = { v: 1.5, env: e } as D;
e.node = n;
console.log(n.data !== null);
`);
	assert cyclicFlag(c, "Env") == "cyclic";
	assert cyclicFlag(c, "Node") == "cyclic";
}

test "E2E C: the record arms of a union a cyclic class holds are not traced when they reach nothing" {
	const c = compiled(`export type U = { s: string } | { n: number, b: boolean };
export class K { u: U; next: K | null; }
export function f(k: K): int32 { k.next = k; return 1; }
`);
	assert traceRefs(c) == 1;
}

test "E2E C: a union record arm that holds the cyclic class is traced beside the class's own edge" {
	const c = compiled(`export type U = { s: string } | { n: number, b: boolean } | { k: K };
export class K { u: U; next: K | null; }
export function f(k: K): int32 { k.next = k; return 1; }
`);
	assert traceRefs(c) == 2;
}

const TILE = `type Area = { area: number };
class Tile { area: number = 1; owner: Holder | null = null; }
`;

test "E2E C: a class converted into an unnamed record argument registers the cycle" {
	const c = compiled(TILE + `class Holder { slot: Area | null = null; }
function keep(h: Holder, a: Area): void { h.slot = a; }
const h = new Holder();
const t = new Tile();
keep(h, t);
t.owner = h;
console.log(t.area);
`);
	assert cyclicFlag(c, "Holder") == "cyclic";
	assert cyclicFlag(c, "Tile") == "cyclic";
}

test "E2E C: a class returned as an unnamed record registers the cycle" {
	const c = compiled(TILE + `class Holder { slot: Area | null = null; }
function asArea(t: Tile): Area { return t; }
const h = new Holder();
const t = new Tile();
h.slot = asArea(t);
t.owner = h;
console.log(t.area);
`);
	assert cyclicFlag(c, "Holder") == "cyclic";
}

test "E2E C: a class placed in an array literal of an unnamed record registers the cycle" {
	const c = compiled(TILE + `class Holder { slots: Area[] = []; }
const h = new Holder();
const t = new Tile();
h.slots = [t];
t.owner = h;
console.log(t.area);
`);
	assert cyclicFlag(c, "Holder") == "cyclic";
}

test "E2E C: a class placed in an object literal field of an unnamed record registers the cycle" {
	const c = compiled(TILE + `class Holder { box: { a: Area } | null = null; }
const h = new Holder();
const t = new Tile();
h.box = { a: t };
t.owner = h;
console.log(t.area);
`);
	assert cyclicFlag(c, "Holder") == "cyclic";
}

function selfNamedBeside(field: string): string {
	return compiled(`class C { name: C | null = null; }
type D = { tag: number } | { ${field}: string };
class HolderD { d: D = { ${field}: "a" }; }
function takeY(y: { name: C | null }): boolean { return y.name != null; }
const c = new C();
c.name = c;
const h = new HolderD();
console.log(takeY(c), h.d);
`);
}

test "E2E C: a union record arm spelled with the field names of a slot a cyclic class fits copies without cyclic operations" {
	assert cyclicOps(selfNamedBeside("name")) == cyclicOps(selfNamedBeside("nome"));
}

function holderRBeside(field: string): string {
	return compiled(`class C { name: C | null = null; }
function takeY(y: { name: C | null }): boolean { return y.name != null; }
const c = new C();
c.name = c;
class HolderR { r: { ${field}: string } | null = null; }
const h = new HolderR();
h.r = { ${field}: "a" };
console.log(takeY(c), h.r != null);
`);
}

test "E2E C: a record field type spelled with the field names of a slot a cyclic class fits copies without cyclic operations" {
	assert cyclicOps(holderRBeside("name")) == cyclicOps(holderRBeside("nome"));
}

const REJECTED = `class C { name: C | null = null; }
type R = { name: C | null };
`;

test "E2E C: an overload rejected for a call notes nothing behind its record parameter" {
	const c = compiled(REJECTED + `class Holder { r: R | null = null; }
function f(a: R, b: number): number { return 1; }
function f(a: C, b: string): number { return 2; }
const h = new Holder();
h.r = { name: null };
console.log(f(new C(), "s"), h.r != null);
`);
	assert cyclicFlag(c, anonWithPointerField(c, "name")) == "acyclic";
}

test "E2E C: an overload rejected for a call notes nothing behind the element of its record array parameter" {
	const c = compiled(REJECTED + `class Holder { r: R[] = []; }
function f(a: R[], b: number): number { return 1; }
function f(a: C[], b: string): number { return 2; }
const cs: C[] = [new C()];
const h = new Holder();
h.r.push({ name: null });
console.log(f(cs, "s"), h.r.length);
`);
	assert cyclicFlag(c, anonWithPointerField(c, "name")) == "acyclic";
}
