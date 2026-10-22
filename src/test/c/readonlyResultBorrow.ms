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

test "the mutable signature of a Readonly overload pair still borrows" {
	const fault = rcFault(`
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
`, ["first", "writeFirst"]);
	assert fault == "", fault;
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
