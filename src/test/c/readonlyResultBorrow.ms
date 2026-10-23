import { compileToC } from "../helpers";

function functionBody(code: string, name: string): string {
	for (const line of code.split("\n")) {
		const at = line.indexOf(" " + name);
		if (at < 0 || !line.endsWith(" {") || line.indexOf("(", at) < 0) continue;
		const start = code.indexOf(line + "\n");
		const end = code.indexOf("\n}", start);
		if (end >= 0) return code.slice(start, end);
	}
	return "";
}

function rcOps(body: string): int32 {
	return (body.split("msIncref").length - 1 + body.split("msDecref").length - 1) as int32;
}

function rcFault(source: string, names: string[]): string {
	const result = compileToC(source);
	if (!result.ok) return result.error;
	for (const name of names) {
		const body = functionBody(result.value, name);
		if (body == "") return name + " has no definition";
		if (rcOps(body) != 0) return name + " takes an rc op on a borrowed result:\n" + body;
	}
	return "";
}

test "a Readonly result is borrowed by callee and caller, cyclic class" {
	const fault = rcFault(`
class Node { kids: Node[] = []; n: int32 = 0; }
function first(t: Readonly<Node>): Readonly<Node> | null {
	if (t.kids.length == 0) return null;
	return t.kids[0];
}
export function readFirst(t: Readonly<Node>): int32 {
	const f = first(t);
	return f == null ? -1 : f.n;
}
`, ["first", "readFirst"]);
	assert fault == "", fault;
}

test "a Readonly result is borrowed, acyclic class through an overload pair" {
	const fault = rcFault(`
class Leaf { n: int32 = 0; }
class Node { kids: Leaf[] = []; }
function first(t: Node): Leaf | null;
function first(t: Readonly<Node>): Readonly<Leaf> | null;
function first(t: Readonly<Node>): Readonly<Leaf> | null {
	if (t.kids.length == 0) return null;
	return t.kids[0];
}
export function readFirst(t: Readonly<Node>): int32 {
	const f = first(t);
	return f == null ? -1 : f.n;
}
`, ["first", "readFirst"]);
	assert fault == "", fault;
}

test "the mutable signature of a Readonly overload pair yields the path its body returns" {
	const result = compileToC(`
class Node { kids: Node[] = []; n: int32 = 0; }
function first(t: Node): Node | null;
function first(t: Readonly<Node>): Readonly<Node> | null;
function first(t: Readonly<Node>): Readonly<Node> | null {
	if (t.kids.length == 0) return null;
	return t.kids[0];
}
export function writeFirst(t: Node): void {
	const m = first(t);
	if (m != null) m.n = 8;
}
export function writePath(t: Node): void {
	const m = t.kids[0];
	m.n = 8;
}
`);
	assert result.ok, result.ok ? "" : result.error;
	assert rcOps(functionBody(result.value, "first")) == 0, functionBody(result.value, "first");
	assert rcOps(functionBody(result.value, "writeFirst")) == rcOps(functionBody(result.value, "writePath")), functionBody(result.value, "writeFirst");
}

test "a Readonly result read as a temporary takes no rc op" {
	const fault = rcFault(`
class Node { kids: Node[] = []; n: int32 = 0; }
function nxt(t: Readonly<Node>): Readonly<Node> { return t.kids[0]; }
export function readNext(t: Readonly<Node>): int32 { return nxt(t).n; }
`, ["nxt", "readNext"]);
	assert fault == "", fault;
}

test "a Readonly result may borrow from any view parameter" {
	const fault = rcFault(`
class Node { n: int32 = 0; }
function pick(a: Readonly<Node>, b: Readonly<Node>): Readonly<Node> { return a.n > b.n ? a : b; }
export function bigger(a: Readonly<Node>, b: Readonly<Node>): int32 { return pick(a, b).n; }
`, ["pick", "bigger"]);
	assert fault == "", fault;
}

test "a borrowed result stored or returned owned is copied" {
	const result = compileToC(`
class Node { kids: Node[] = []; n: int32 = 0; }
function nxt(t: Readonly<Node>): Readonly<Node> { return t.kids[0]; }
export function keep(t: Readonly<Node>, xs: Readonly<Node>[]): void { xs.push(nxt(t)); }
`);
	assert result.ok, result.ok ? "" : result.error;
	const body = functionBody(result.value, "keep");
	assert body.split("msIncref").length - 1 == 1, body;
}

test "a call through a two-body overload set decides by the body it runs" {
	const fault = rcFault(`
class Node { kids: Node[] = []; n: int32 = 0; }
function at(t: Readonly<Node>, i: int32): Readonly<Node> { return t.kids[i]; }
function at(t: Readonly<Node>): Readonly<Node> { return at(t, 0); }
export function readAt(t: Readonly<Node>): int32 { return at(t).n + at(t, 0).n; }
`, ["readAt"]);
	assert fault == "", fault;
}

test "a Readonly module const read as a result, an argument or a field path takes no rc op" {
	const fault = rcFault(`
class Node { kids: Node[] = []; n: int32 = 0; }
const ROOT: Readonly<Node> = new Node();
function pick(t: Readonly<Node> | null): Readonly<Node> { return t != null ? t : ROOT; }
function look(t: Readonly<Node>): int32 { return t.n; }
export function readArg(): int32 { return look(ROOT); }
export function readRet(): int32 { const p = pick(null); return p.n; }
export function readField(): int32 { return ROOT.n + ROOT.kids.length; }
`, ["pick", "readArg", "readRet", "readField"]);
	assert fault == "", fault;
}

test "a local bound to a deep Readonly module const built in place borrows it" {
	const fault = rcFault(`
class Node { kids: Node[] = []; n: int32 = 0; }
const ROOT: Readonly<Node> = new Node();
function look(t: Readonly<Node>): int32 { return t.n; }
export function readLocal(): int32 { const r = ROOT; return r.n + r.kids.length; }
`, ["readLocal", "look"]);
	assert fault == "", fault;
}

test "a local bound to a module let or a mutable const still copies it" {
	for (const decl of ["let ROOT: Readonly<Node> = new Node();", "const ROOT: Node = new Node();"]) {
		const result = compileToC(`
class Node { kids: Node[] = []; n: int32 = 0; }
${decl}
export function readLocal(): int32 { const r = ROOT; return r.n; }
`);
		assert result.ok, result.ok ? "" : result.error;
		assert rcOps(functionBody(result.value, "readLocal")) > 0, functionBody(result.value, "readLocal");
	}
}

test "an argument path stays borrowed across a call that writes only holders of other types" {
	const fault = rcFault(`
class Node { kids: Node[] = []; n: int32 = 0; }
class Seen { entries: Cursor<Readonly<Node>>[] = []; marks: int32[] = []; }
function note(s: Seen, t: Readonly<Node>): void { s.entries.push(t); s.marks.push(t.n); s.marks[0] = 1; }
export function scan(t: Readonly<Node>, seen: Seen): int32 {
	note(seen, t);
	let sum = t.n;
	for (let i = 0; i < t.kids.length; i += 1) sum += scan(t.kids[i], seen);
	return sum;
}
`, ["scan"]);
	assert fault == "", fault;
}

test "an argument path is kept alive across a call that may write a holder of its type" {
	for (const write of ["o.kids[0] = new Node();", "o.kids.length = 0;", "o.kids = [];"]) {
		const result = compileToC(`
class Node { kids: Node[] = []; n: int32 = 0; }
function hit(o: Node, t: Readonly<Node>): int32 { ${write} return t.n; }
export function scan(t: Node, o: Node): int32 { return hit(o, t.kids[0]); }
`);
		assert result.ok, result.ok ? "" : result.error;
		assert rcOps(functionBody(result.value, "scan")) > 0, write + "\n" + functionBody(result.value, "scan");
	}
}

test "a tail-recursive walk over a nullable view keeps the loop local a view" {
	for (const param of ["Readonly<Node> | null", "Readonly<Node | null>", "null | Readonly<Node>"]) {
		const fault = rcFault(`
class Node { kids: Node[] = []; n: int32 = 0; next: Node | null = null; }
export function walk(t: ${param}, acc: int32): int32 {
	if (t == null) return acc;
	if (t.n > 2) return walk(t.kids.length > 0 ? t.kids[0] : null, acc + 1);
	return walk(t.next, acc + t.n);
}
`, ["walk"]);
		assert fault == "", param + ": " + fault;
	}
}

test "a tail call that hands its view parameter an owned value still owns it" {
	const result = compileToC(`
class Node { kids: Node[] = []; n: int32 = 0; next: Node | null = null; }
export function walk(t: Readonly<Node> | null, acc: int32): int32 {
	if (t == null) return acc;
	if (acc > 3) return acc;
	return walk(new Node(), acc + 1);
}
`);
	assert result.ok, result.ok ? "" : result.error;
	assert rcOps(functionBody(result.value, "walk")) > 0, functionBody(result.value, "walk");
}

test "an argument path stays borrowed across a write to elements no object of its type can be" {
	const fault = rcFault(`
class Node { kids: Node[] = []; n: int32 = 0; }
interface Note { line: string; at: int32; }
class Log { notes: Note[] = []; }
function hit(log: Log, t: Readonly<Node>): int32 { log.notes[0] = { line: "x", at: t.n }; return t.n; }
export function scan(t: Node, log: Log): int32 { return hit(log, t.kids[0]); }
`, ["scan"]);
	assert fault == "", fault;
}

test "an argument path is kept alive across a write to elements its type is assignable to" {
	const cases = [
		"class Node { kids: Node[] = []; n: int32 = 0; }\ninterface Named { kids: Node[]; n: int32; }\nfunction made(): Named { return new Node(); }",
		"class Node { kids: Node[] = []; n: int32 = 0; }\ninterface Named { kids: Node[]; }\nfunction made(): Named { return new Node(); }",
		"class Node { kids: Node[] = []; n: int32 = 0; }\nclass Marked extends Node { line: string = \"\"; }\ninterface Named { kids: Node[]; n: int32; line: string; }\nfunction made(): Named { return new Marked(); }",
	];
	for (const decls of cases) {
		const result = compileToC(`
${decls}
class Log { named: Named[] = []; }
function hit(log: Log, t: Readonly<Node>): int32 { log.named[0] = made(); return t.n; }
export function scan(t: Node, log: Log): int32 { return hit(log, t.kids[0]); }
`);
		assert result.ok, result.ok ? "" : result.error;
		assert rcOps(functionBody(result.value, "scan")) > 0, decls + "\n" + functionBody(result.value, "scan");
	}
}

test "a view call's result stays borrowed across writes that miss the path its callee returns" {
	const fault = rcFault(`
class Node { kids: Node[] = []; next: Node | null = null; n: int32 = 0; }
class Out { lines: string[] = []; }
function last(t: Readonly<Node>): Readonly<Node> { return t.next != null ? last(t.next) : t; }
export function count(t: Readonly<Node>, out: Out): int32 {
	const p = last(t);
	out.lines.push("x");
	out.lines[0] = "y";
	return p.n;
}
`, ["count"]);
	assert fault == "", fault;
}

test "a view call's result is owned across a write to a slot its callee returns through" {
	for (const write of ["out.node.next = null;", "out.node.kids[0] = new Node();"]) {
		const result = compileToC(`
class Node { kids: Node[] = []; next: Node | null = null; n: int32 = 0; }
class Out { node: Node = new Node(); }
function last(t: Readonly<Node>): Readonly<Node> { return t.next != null ? last(t.next) : t.kids.length > 0 ? t.kids[0] : t; }
export function count(t: Readonly<Node>, out: Out): int32 {
	const p = last(t);
	${write}
	return p.n;
}
`);
		assert result.ok, result.ok ? "" : result.error;
		assert rcOps(functionBody(result.value, "count")) > 0, write + "\n" + functionBody(result.value, "count");
	}
}

function borrowedOps(body: string, local: string): int32 {
	let n = 0;
	for (const line of body.split("\n")) {
		if ((line.includes("msIncref") || line.includes("msDecref")) && (line.includes(local + "_") || line.includes("dollarborrow"))) n += 1;
	}
	return n as int32;
}

test "a view call's result stays borrowed across an append to the array it was read from" {
	const result = compileToC(`
class Node { kids: Node[] = []; n: int32 = 0; }
function first(t: Readonly<Node>): Readonly<Node> { return t.kids[0]; }
export function grow(t: Node, o: Node): int32 {
	const k = first(t);
	o.kids.push(new Node());
	o.kids.push(new Node());
	return k.n;
}
`);
	assert result.ok, result.ok ? "" : result.error;
	const body = functionBody(result.value, "grow");
	assert borrowedOps(body, "k") == 0, body;
}

test "a view call's result is owned across a removal or overwrite of the elements it was read from" {
	for (const write of ["o.kids.pop();", "o.kids.splice(0, 1);", "o.kids.shift();", "o.kids[0] = new Node();", "o.kids.length = 0;"]) {
		const result = compileToC(`
class Node { kids: Node[] = []; n: int32 = 0; }
function first(t: Readonly<Node>): Readonly<Node> { return t.kids[0]; }
export function grow(t: Node, o: Node): int32 {
	const k = first(t);
	${write}
	return k.n;
}
`);
		assert result.ok, result.ok ? "" : result.error;
		assert rcOps(functionBody(result.value, "grow")) > 0, write + "\n" + functionBody(result.value, "grow");
	}
}

test "a view call's result stays borrowed across an overwrite of elements that need no cleanup" {
	const fault = rcFault(`
class Node { kids: Node[] = []; n: int32 = 0; }
class Marks { flags: (int32 | boolean)[] = [0]; }
function first(t: Readonly<Node>): Readonly<Node> { return t.kids[0]; }
export function mark(t: Node, m: Marks): int32 {
	const k = first(t);
	m.flags[0] = true;
	return k.n;
}
`, ["mark"]);
	assert fault == "", fault;
}

test "an argument path is kept alive across an append the callee makes to its array" {
	const result = compileToC(`
class Node { kids: Node[] = []; n: int32 = 0; }
function hit(o: Node, t: Readonly<Node>): int32 { o.kids.push(new Node()); return t.n; }
export function scan(t: Node, o: Node): int32 { return hit(o, t.kids[0]); }
`);
	assert result.ok, result.ok ? "" : result.error;
	assert rcOps(functionBody(result.value, "scan")) > 0, functionBody(result.value, "scan");
}

test "a heap cell read from an array stays borrowed across pushes that reallocate the array" {
	const result = compileToC(`
class Node { kids: Node[] = []; n: int32 = 0; }
function firstKid(t: Readonly<Node>): Readonly<Node> { return t.kids[0]; }
function grow(o: Node): void { for (let i = 0; i < 4096; i += 1) o.kids.push(new Node()); }
export function look(t: Readonly<Node>, o: Node): int32 {
	const k = firstKid(t);
	grow(o);
	o.kids.push(new Node());
	return k.n;
}
`);
	assert result.ok, result.ok ? "" : result.error;
	assert borrowedOps(functionBody(result.value, "look"), "k") == 0, functionBody(result.value, "look");
}

test "an address into an array is refused across a push to an array a caller can pass for it" {
	const sources = [`
class Node { kids: Node[] = []; n: int32 = 0; }
export function look(t: Node, o: Node): int32 {
	const b: Borrow<Node> = t.kids[0];
	GROW for (let i = 0; i < 4096; i += 1) o.kids.push(new Node());
	return b.n;
}
`, `
struct Pt { n: int32; s: string; }
export function look(xs: Pt[], ys: Pt[]): int32 {
	const b: Borrow<Pt> = xs[0];
	GROW for (let i = 0; i < 4096; i += 1) ys.push({ n: i, s: "x" });
	return b.n;
}
`];
	for (const source of sources) {
		const refused = compileToC(source.replace("GROW", ""));
		assert !refused.ok && refused.error.includes("cannot borrow 'b'"), refused.ok ? source : refused.error;
		const accepted = compileToC(source.replace("GROW", "//"));
		assert accepted.ok, accepted.ok ? "" : accepted.error;
	}
}

test "a view stays borrowed across a write to a same-named field of an unrelated generic class" {
	const fault = rcFault(`
class Node { data: Node | null = null; n: int32 = 0; }
class Box<T> { data: T[] = []; }
function reset<T>(b: Box<T>): void { b.data = []; }
function inner(t: Readonly<Node>): Readonly<Node> | null { return t.data; }
export function look(t: Readonly<Node>, b: Box<string>): int32 {
	const d = inner(t);
	reset(b);
	return d == null ? 0 : d.n;
}
`, ["look"]);
	assert fault == "", fault;
}

test "a view is owned across a write to the generic class field it was read through" {
	const result = compileToC(`
class Node { n: int32 = 0; }
class Box<T> { data: T[] = []; }
function reset<T>(b: Box<T>): void { b.data = []; }
function firstOf(b: Readonly<Box<Node>>): Readonly<Node> { return b.data[0]; }
export function look(b: Box<Node>, o: Box<Node>): int32 {
	const d = firstOf(b);
	reset(o);
	return d.n;
}
`);
	assert result.ok, result.ok ? "" : result.error;
	assert borrowedOps(functionBody(result.value, "look"), "d") > 0, functionBody(result.value, "look");
}

test "a view stays borrowed across a callee's element write to an array of an unrelated class" {
	const fault = rcFault(`
class Node { kids: Node[] = []; n: int32 = 0; }
class Other { n: int32 = 0; }
function refill(others: Other[]): void { others[0] = new Other(); }
function firstKid(t: Readonly<Node>): Readonly<Node> { return t.kids[0]; }
export function look(t: Readonly<Node>, others: Other[]): int32 {
	const k = firstKid(t);
	refill(others);
	return k.n;
}
`, ["look"]);
	assert fault == "", fault;
}

test "a view is owned across a callee's element write to an array of its own class" {
	const result = compileToC(`
class Node { kids: Node[] = []; n: int32 = 0; }
function refill(kids: Node[]): void { kids[0] = new Node(); }
function firstKid(t: Readonly<Node>): Readonly<Node> { return t.kids[0]; }
export function look(t: Readonly<Node>, o: Node): int32 {
	const k = firstKid(t);
	refill(o.kids);
	return k.n;
}
`);
	assert result.ok, result.ok ? "" : result.error;
	assert borrowedOps(functionBody(result.value, "look"), "k") > 0, functionBody(result.value, "look");
}
