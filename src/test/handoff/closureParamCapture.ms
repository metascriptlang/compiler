// A captured parameter is COPIED into the closure env, never addressed.
// Nim lambdalifting.nim:216 newAsgnStmt — capture through a parameter is the one
// case that generates an assignment; illegalCapture only rejects views and result.
// Storing `&param` instead makes the env point into a frame the closure outlives.

import { fullPipeline } from "./helpers";
import { compileToC, compileToJS } from "../helpers";
import { Node, NodeKind, ProgramData, InterfaceDeclData, TypeKind } from "../../ast/node";

const VIEW_CAPTURE = "cannot be captured as it would violate memory safety";

function refusedWith(r: Result<string, string>, needle: string): boolean {
	if (r.ok) return false;
	return r.error.indexOf(needle) >= 0;
}

function refusedOnBothBackends(src: string, needle: string): boolean {
	return refusedWith(compileToC(src), needle) && refusedWith(compileToJS(src), needle);
}

function acceptedOnBothBackends(src: string): boolean {
	return compileToC(src).ok && compileToJS(src).ok;
}

function findEnvDecl(prog: Node): Node {
	const pd = prog.data as ProgramData;
	let i = 0;
	while (i < pd.programStmts.length) {
		const stmt = pd.programStmts[i];
		if (stmt.kind == NodeKind.InterfaceDecl) {
			const id = stmt.data as InterfaceDeclData;
			if (id.interfaceName.length > 0 && id.interfaceName.charAt(0) == "$") {
				return stmt;
			}
		}
		i = i + 1;
	}
	return null as unknown as Node;
}

function envFieldKind(envDecl: Node, fieldName: string): TypeKind {
	const t = envDecl.nodeType;
	if (t == null) return TypeKind.Pending;
	let i = 0;
	while (i < t.typeNames.length) {
		if (t.typeNames[i] == fieldName) {
			if (i < t.typeChildren.length && t.typeChildren[i] != null) {
				return t.typeChildren[i].kind;
			}
		}
		i = i + 1;
	}
	return TypeKind.Pending;
}

test "a union param captured by an escaping closure is not stored as a pointer to the frame" {
	const src = "interface S { padding: number; }\nfunction make(s: S | null): () => boolean {\nreturn (): boolean => s === null;\n}";
	const prog = fullPipeline(src);
	assert prog != null;
	const env = findEnvDecl(prog);
	assert env != null;
	assert envFieldKind(env, "s") != TypeKind.Ptr;
}

test "an array param captured by an escaping closure is not stored as a pointer to the frame" {
	const src = "function make(xs: number[]): () => number {\nreturn (): number => xs.length;\n}";
	const prog = fullPipeline(src);
	assert prog != null;
	const env = findEnvDecl(prog);
	assert env != null;
	assert envFieldKind(env, "xs") != TypeKind.Ptr;
}

test "a view-typed binding named inside a closure is refused at the use on C and JS" {
	const cases = [
		{ name: "ref param read by an arrow", src: `
function f(ref n: int32): int32 {
	const read = (): int32 => n + 1;
	return read();
}
let k: int32 = 41;
console.log(f(k));
` },
		{ name: "ref param written by an arrow", src: `
function f(ref n: int32): void {
	const bump = (): void => { n = n + 1; };
	bump();
}
let k: int32 = 40;
f(k);
console.log(k);
` },
		{ name: "out param written by an arrow", src: `
function f(out n: int32): void {
	const set = (): void => { n = 9; };
	n = 1;
	set();
}
let k: int32 = 0;
f(out k);
console.log(k);
` },
		{ name: "ref param written by a function expression", src: `
function f(ref n: int32): void {
	const bump = function (): void { n = n + 5; };
	bump();
}
let k: int32 = 1;
f(k);
console.log(k);
` },
		{ name: "ref param written two closures deep", src: `
function f(ref n: int32): void {
	const outer = (): void => {
		const inner = (): void => { n = n + 3; };
		inner();
	};
	outer();
}
let k: int32 = 1;
f(k);
console.log(k);
` },
		{ name: "ref param written by a nested function declaration", src: `
function f(ref n: int32): void {
	function inner(): void { n = n + 3; }
	inner();
}
let k: int32 = 1;
f(k);
console.log(k);
` },
		{ name: "ref receiver written by an arrow", src: `
struct S { n: int32; }
function bump(this ref x: S): int32 {
	const f = (): void => { x.n = x.n + 1; };
	f();
	return x.n;
}
let v: S = { n: 10 };
console.log(v.bump());
` },
		{ name: "Span param read by an arrow", src: `
function f(xs: Span<int32>): int32 {
	const read = (): int32 => xs[1];
	return read();
}
let v: int32[] = [1, 4];
console.log(f(v));
` },
		{ name: "Span local read by an escaping arrow", src: `
function mk(): () => int32 {
	let a: int32[] = [1, 2, 3];
	const sp: Span<int32> = a;
	return (): int32 => sp[2];
}
console.log(mk()());
` },
		{ name: "Span param copied into a local first", src: `
function f(xs: Span<int32>): () => int32 {
	const s2: Span<int32> = xs;
	return (): int32 => s2[0];
}
let v: int32[] = [6, 4];
console.log(f(v)());
` },
		{ name: "struct holding a Span read by an arrow", src: `
struct Chunk { view: Span<int32>; tag: int32; }
function f(c: Chunk): int32 {
	const read = (): int32 => c.view[1] + c.tag;
	return read();
}
let v: int32[] = [1, 4];
const c: Chunk = { view: v, tag: 10 };
console.log(f(c));
` },
	];
	for (const c of cases) {
		assert refusedOnBothBackends(c.src, VIEW_CAPTURE), c.name;
	}
}

test "a view-typed parameter used in an async or generator body is refused on C and JS" {
	const cases = [
		{ name: "ref param of an async function", src: `
async function addNow(ref g: int32[]): Promise<void> {
	g.push(5);
}
async function main(): Promise<void> {
	let v: int32[] = [1];
	await addNow(v);
	console.log(v.length);
}
main();
` },
		{ name: "ref param of a generator", src: `
function* gen(ref g: int32[]): Iterator<int32> {
	g.push(10);
	yield 1;
}
let v: int32[] = [];
for (const x of gen(v)) { console.log(x); }
` },
		{ name: "Span param of a generator", src: `
function* gen(xs: Span<int32>): Iterator<int32> {
	yield xs[0];
}
let v: int32[] = [3, 4];
for (const x of gen(v)) { console.log(x); }
` },
	];
	for (const c of cases) {
		assert refusedOnBothBackends(c.src, VIEW_CAPTURE), c.name;
	}
}

test "the view-capture refusal names the declaration and the remedy" {
	const shared = `function f(ref g: int32[]): int32 {
	const read = (): int32 => g[1];
	return read();
}
let v: int32[] = [1, 4];
console.log(f(v));
`;
	assert refusedOnBothBackends(shared, "'g' is of type <int32[]> which " + VIEW_CAPTURE +
		", declared here: e2e.ms(1, 16); drop the parameter modifier: " +
		"a int32[] is already shared by reference");
	const scalar = `function f(ref n: int32): int32 {
	const read = (): int32 => n;
	return read();
}
let k: int32 = 41;
console.log(f(k));
`;
	assert refusedOnBothBackends(scalar, "'n' is of type <int32> which " + VIEW_CAPTURE +
		", declared here: e2e.ms(1, 16); return the value instead");
	const local = `function mk(): () => int32 {
	let a: int32[] = [1, 2, 3];
	const sp: Span<int32> = a;
	return (): int32 => sp[2];
}
console.log(mk()());
`;
	assert refusedOnBothBackends(local, "'sp' is of type <Span<int32>> which " + VIEW_CAPTURE +
		", declared here: e2e.ms(3, 8); return the value instead");
}

test "bindings that are not views stay capturable and views stay usable in their own body" {
	const cases = [
		{ name: "for-of binding captured per iteration", src: `
function run(): int32 {
	const src: Vec<int32> = [1, 2, 3];
	let fs: (() => int32)[] = [];
	for (const x of src) { fs.push((): int32 => x); }
	let s: int32 = 0;
	for (const f of fs) { s = s + f(); }
	return s;
}
console.log(run());
` },
		{ name: "rest param captured by an escaping arrow", src: `
function mk(...args: string[]): () => int32 {
	return (): int32 => args.length as int32;
}
console.log(mk("a", "bb")());
` },
		{ name: "unused ref param of an async function", src: `
async function later(ref g: int32[]): Promise<int32> {
	return 3;
}
async function main(): Promise<void> {
	let v: int32[] = [1];
	console.log(await later(v));
}
main();
` },
		{ name: "ref param used in its own for-of body", src: `
function f(ref g: int32[], src: int32[]): void {
	for (const x of src) { g.push(x * 2); }
}
let v: int32[] = [];
f(v, [1, 2, 3]);
console.log(v.length);
` },
		{ name: "Span param and Span local used in their own body", src: `
function sum(xs: Span<int32>): int32 {
	let t: int32 = 0;
	for (const x of xs) { t = t + x; }
	const local: Span<int32> = xs;
	return t + local[0];
}
let v: int32[] = [1, 2, 3];
console.log(sum(v));
` },
		{ name: "module-level Span read inside a closure", src: `
const backing: int32[] = [5, 6];
const top: Span<int32> = backing;
function read(): int32 {
	const at = (): int32 => top[1];
	return at();
}
console.log(read());
` },
	];
	for (const c of cases) {
		assert acceptedOnBothBackends(c.src), c.name;
	}
}

function envFieldKinds(prog: Node, fieldName: string): TypeKind[] {
	const kinds: TypeKind[] = [];
	const pd = prog.data as ProgramData;
	for (const stmt of pd.programStmts) {
		if (stmt.kind != NodeKind.InterfaceDecl) continue;
		const id = stmt.data as InterfaceDeclData;
		if (id.interfaceName.length == 0 || id.interfaceName.charAt(0) != "$") continue;
		const kind = envFieldKind(stmt, fieldName);
		if (kind != TypeKind.Pending) kinds.push(kind);
	}
	return kinds;
}

test "a captured value Vec is copied into every env that holds it, never addressed" {
	const cases = [
		{ name: "param read by an escaping arrow", field: "v", src: `
function make(v: Vec<int32>): () => int32 {
	return (): int32 => v[1];
}
` },
		{ name: "param read by a closure made per loop iteration", field: "v", src: `
function perIteration(v: Vec<int32>): (() => int32)[] {
	let fs: (() => int32)[] = [];
	for (let i: int32 = 0; i < 2; i++) { fs.push((): int32 => v[i]); }
	return fs;
}
` },
		{ name: "param read two closures deep", field: "v", src: `
function nested(v: Vec<int32>): int32 {
	const outer = (): int32 => {
		const inner = (): int32 => v[0];
		return inner();
	};
	return outer();
}
` },
		{ name: "module-level loop binding read by a closure", field: "row", src: `
const rows: Vec<Vec<int32>> = [[1, 2], [3, 4]];
let fs: (() => int32)[] = [];
for (const row of rows) { fs.push((): int32 => row[0]); }
` },
	];
	for (const c of cases) {
		const prog = fullPipeline(c.src);
		assert prog != null, c.name;
		const kinds = envFieldKinds(prog, c.field);
		assert kinds.length > 0, c.name;
		for (const kind of kinds) {
			assert kind == TypeKind.Array, c.name;
		}
	}
}
