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
