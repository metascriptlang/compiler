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

function cyclicFlag(c: string, name: string): string {
	const line = typeInfoOf(c, name);
	if (line == "") return "no TypeInfo for " + name + " in " + c.substring(0, 200);
	return line.contains(".isCyclic = MS_TRUE") ? "cyclic" : "acyclic";
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
