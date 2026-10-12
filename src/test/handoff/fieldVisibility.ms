import { checkProjectDiagnostics, compileProjectToCWithStd, MapEntry } from "../helpers";

const proofModule = "export struct Account { address: uint64; }\nexport struct Signer { private account: Account; }\nexport function signer(a: Account): Signer { return { account: a }; }\nexport function address(this s: Signer): uint64 { return s.account.address; }\n";
const generics = "export struct Box<T> { private v: T; n: int32; }\nexport function box<T>(x: T): Box<T> { return { v: x, n: 1 }; }\nexport function unbox<T>(b: Box<T>): T { return b.v; }\n";

function diagnostics(library: string, main: string): string[] {
	const entries: MapEntry[] = [
		{ entryPath: "src/lib.ms", entrySource: library },
		{ entryPath: "src/main.ms", entrySource: main },
	];
	return checkProjectDiagnostics(entries, "src/main.ms");
}

function errorsOf(library: string, main: string): string[] {
	const out: string[] = [];
	for (const m of diagnostics(library, main)) {
		if (m.indexOf("is imported but never used") < 0) out.push(m);
	}
	return out;
}

function refusesPrivate(library: string, main: string, field: string): boolean {
	for (const m of diagnostics(library, main)) {
		if (m.indexOf("'" + field + "' is a private field") >= 0) return true;
	}
	return false;
}

function cOf(library: string, main: string): string {
	const entries: MapEntry[] = [
		{ entryPath: "src/lib.ms", entrySource: library },
		{ entryPath: "src/main.ms", entrySource: main },
	];
	return compileProjectToCWithStd(entries, "src/main.ms");
}

const useProof = "import { Account, Signer, address, signer } from \"./lib\";\n";

test "fieldVisibility: a struct with a private field reaches C through the module that declares it" {
	const c = cOf(proofModule, useProof + "const ok = signer({ address: 7 });\nconsole.log(ok.address());\n");
	assert !c.startsWith("ERROR"), c;
}

test "fieldVisibility: another module builds, reads, writes, spreads or destructures no private struct field" {
	const prefix = useProof + "const ok = signer({ address: 7 });\n";
	assert refusesPrivate(proofModule, useProof + "const f: Signer = { account: { address: 1 } };\n", "account");
	assert refusesPrivate(proofModule, prefix + "console.log(ok.account.address);\n", "account");
	assert refusesPrivate(proofModule, "import { Account, Signer, signer } from \"./lib\";\nlet ok = signer({ address: 7 });\nok.account = { address: 2 };\n", "account");
	assert refusesPrivate(proofModule, prefix + "const c: Signer = { ...ok };\n", "account");
	assert refusesPrivate(proofModule, prefix + "const { account } = ok;\n", "account");
	assert refusesPrivate(proofModule, prefix + "const { ...rest } = ok;\n", "account");
}

test "fieldVisibility: a private struct field is not reached by adopting or converting an anonymous value" {
	assert refusesPrivate(proofModule, useProof + "const acct: Account = { address: 1 };\nconst raw = { account: acct };\nconst s: Signer = raw;\n", "account");
	assert refusesPrivate(proofModule, useProof + "const acct: Account = { address: 1 };\nconst raw = { account: acct };\nconst s = raw as Signer;\n", "account");
	assert refusesPrivate(proofModule, useProof + "const s = { account: { address: 1 } } as Signer;\n", "account");
}

test "fieldVisibility: the declaring module and a copy of the whole value keep working" {
	assert errorsOf(proofModule, useProof + "const ok = signer({ address: 7 });\nconst copy = ok;\nconsole.log(copy.address());\n").length == 0;
	const own = "export struct Account { address: uint64; }\nexport struct Signer { private account: Account; }\nconst s: Signer = { account: { address: 4 } };\nconst { account } = s;\nconst c: Signer = { ...s };\nexport const total: uint64 = s.account.address + account.address + c.account.address;\n";
	assert errorsOf("export const unused = 0;\n", own).length == 0;
}

test "fieldVisibility: a generic struct's private field is visible to its own generic code only" {
	const use = "import { Box, box, unbox } from \"./lib\";\nconst b = box<int32>(4);\n";
	assert errorsOf(generics, use + "console.log(unbox(b), b.n);\n").length == 0;
	assert refusesPrivate(generics, use + "console.log(b.v);\n", "v");
	assert refusesPrivate(generics, "import { Box } from \"./lib\";\nconst b: Box<int32> = { v: 1, n: 2 };\n", "v");
}

test "fieldVisibility: a private class member is visible inside its class body only" {
	const cls = "export class B {\n\tprivate secret: int32 = 1;\n\tbump(): int32 { this.secret += 1; const f = () => this.secret; return f(); }\n\tpeek(other: B): int32 { return other.secret; }\n\tstatic make(): B { const b = new B(); b.secret = 5; return b; }\n}\n";
	assert errorsOf("export const unused = 0;\n", cls + "const b = B.make();\nconsole.log(b.bump(), b.peek(b));\n").length == 0;
	assert refusesPrivate("export const unused = 0;\n", cls + "const b = new B();\nb.secret = 9;\n", "secret");
	assert refusesPrivate("export const unused = 0;\n", cls + "function outside(b: B): int32 { return b.secret; }\n", "secret");
	assert refusesPrivate("export const unused = 0;\n", "class P { private s: int32 = 1; }\nclass Q extends P { peek(): int32 { return this.s; } }\n", "s");
}

test "fieldVisibility: a generic class reaches its private members from methods, statics and initializers" {
	const bag = "export class Bag<T> {\n\tprivate items: T[] = [];\n\tadd(x: T): int32 { this.items.push(x); return this.items.length; }\n\tstatic of(x: T): Bag<T> { const b = new Bag<T>(); b.items.push(x); return b; }\n}\n";
	const use = "import { Bag } from \"./lib\";\n";
	assert errorsOf(bag, use + "const g = new Bag<int32>();\nconsole.log(g.add(1), Bag.of<int32>(2).add(3));\n").length == 0;
	assert refusesPrivate(bag, use + "const g = new Bag<int32>();\nconsole.log(g.items.length);\n", "items");
}

test "fieldVisibility: a private field is inherited through a single struct parent only" {
	const lib = "export struct A { private a: int32; }\nexport struct B { b: int32; }\n";
	let refused = false;
	for (const m of diagnostics(lib, "import { A, B } from \"./lib\";\nstruct D extends A, B { d: int32; }\n")) { if (m.indexOf("cannot inherit the private field 'a'") >= 0) refused = true; }
	assert refused;
	assert refusesPrivate(lib, "import { A } from \"./lib\";\nstruct C extends A { c: int32; }\nfunction read(x: C): int32 { return x.a; }\n", "a");
}

test "fieldVisibility: only a struct field takes the private modifier" {
	assert diagnostics("export const unused = 0;\n", "interface I { private x: int32; }\n").length > 0;
	assert diagnostics("export const unused = 0;\n", "struct S { protected x: int32; }\n").length > 0;
	assert errorsOf("export const unused = 0;\n", "struct S { private: int32; }\nconst s: S = { private: 1 };\n").length == 0;
}

test "fieldVisibility: as converts a struct only to itself, a distinct of it or a struct it extends" {
	const lib = "export struct P { x: int32; }\nexport struct Q { x: int32; }\nexport struct D extends P { y: int32; }\nexport type T = distinct P;\n";
	const pre = "import { P, Q, D, T } from \"./lib\";\nconst p: P = { x: 3 };\nconst d: D = { x: 1, y: 2 };\n";
	let refused = false;
	for (const m of diagnostics(lib, pre + "const q = p as Q;\n")) { if (m.indexOf("cannot convert P to Q") >= 0) refused = true; }
	assert refused;
	assert errorsOf(lib, pre + "const b = d as P;\nconst t = p as T;\nconst back = t as P;\nconst lit = { x: 9 } as P;\nconst raw = { x: 5 };\nconst adopted = raw as P;\nconsole.log(b.x, back.x, lit.x, adopted.x);\n").length == 0;
}

test "fieldVisibility: as builds a struct only from a struct, a distinct of one, or a union holding one" {
	const lib = "export struct P { x: int32; }\nexport struct Box<T> { x: int32; }\nexport struct Proof { private n: int32; }\nexport struct Q { y: int32; }\nexport type D = distinct P;\nexport enum Color { Red, Green }\n";
	const pre = "import { P, Q, Box, Proof, D, Color } from \"./lib\";\nconst n: int32 = 5;\nconst s = \"a\";\n";
	const refusal = ": only a struct, a distinct of it, or a struct it extends converts to a struct";
	assert reports(lib, pre + "const q = (0 as uint64) as Proof;\n", "cannot convert uint64 to Proof" + refusal);
	assert reports(lib, pre + "const q = (0 as uint64) as Proof;\n", "Proof has private fields, so only the module that declares it builds one");
	assert reports(lib, pre + "const q = n as P;\n", "cannot convert int32 to P" + refusal);
	assert reports(lib, pre + "const q = true as P;\n", "cannot convert boolean to P" + refusal);
	assert reports(lib, pre + "const q = s as P;\n", "cannot convert string to P" + refusal);
	assert reports(lib, pre + "const q = Color.Red as P;\n", "cannot convert Color to P" + refusal);
	assert reports(lib, pre + "const q = n as Box<int32>;\n", "cannot convert int32 to Box<int32>" + refusal);
	assert reports(lib, pre + "const q = n as D;\n", "cannot convert int32 to D" + refusal);
	assert reports(lib, pre + "const q = [1, 2] as P;\n", "cannot convert int32[] to P" + refusal);
	assert reports(lib, pre + "function pick(b: boolean): int32 | string { return b ? 1 : \"s\"; }\nconst q = pick(true) as P;\n", "cannot convert int32 | string to P" + refusal);
	assert reports(lib, pre + "function forge<V>(v: V): P { return v as P; }\nconsole.log(forge<int32>(1).x);\n", "cannot convert int32 to P" + refusal);
	assert reports(lib, pre + "function f(): int32 { return 1; }\nconst q = f as Proof;\n", "cannot convert function to Proof" + refusal);
	assert reports(lib, pre + "const q = ((): int32 => 1) as Proof;\n", "cannot convert function to Proof" + refusal);
	assert reports(lib, pre + "const q = new Map<string, int32>() as Proof;\n", "cannot convert Map<string, int32> to Proof" + refusal);
	assert reports(lib, pre + "const q = Promise.resolve(3) as Proof;\n", "cannot convert Promise<int32> to Proof" + refusal);
	assert reports(lib, pre + "function v(): void {}\nconst q = v() as Proof;\n", "cannot convert void to Proof" + refusal);
	assert reports(lib, pre + "extern function mkp(): Ptr<void> from \"mkp\";\nconst q = mkp() as Proof;\n", "cannot convert Ptr<void> to Proof" + refusal);
	assert reports(lib, pre + "extern function mks(): cstring from \"mks\";\nconst q = mks() as Proof;\n", "cannot convert cstring to Proof" + refusal);
	assert reports(lib, pre + "function f(a: int32[]): Proof { return a[0..1] as Proof; }\n", "cannot convert Span<int32> to Proof" + refusal);
	assert reports(lib, pre + "function g(): int32 { return 1; }\nfunction pick(b: boolean): (() => int32) | null { return b ? g : null; }\nconst q = pick(true) as Proof;\n", "to Proof" + refusal);
	assert reports(lib, pre + "function pick(b: boolean): P | Q { return b ? ({ x: 1 } as P) : ({ y: 2 } as Q); }\nconst q = pick(true) as Proof;\n", "to Proof" + refusal);
	assert reports(lib, pre + "function ma(): int32[] | null { return null; }\nconst q = ma() as Proof;\n", "to Proof" + refusal);
	assert reports(lib, pre + "function mm(): Map<string, int32> | null { return null; }\nconst q = mm() as Proof;\n", "to Proof" + refusal);
	assert !reports(lib, pre + "const q = null as Proof;\n", "converts to a struct");
	assert !reports(lib, pre + "const q = missing as Proof;\n", "converts to a struct");
}

test "fieldVisibility: as still takes a struct, a union holding one, or an object literal to a struct" {
	const lib = "export struct P { x: int32; }\nexport struct Proof { private n: int32; }\nexport type D = distinct P;\n";
	const pre = "import { P, Proof, D } from \"./lib\";\nconst p: P = { x: 1 };\nfunction pick(b: boolean): P | int32 { return b ? p : 2; }\n";
	assert errorsOf(lib, pre + "const a = p as P;\nconst b = p as D;\nconst c = pick(true) as P;\nconst d = { x: 7 } as P;\nconsole.log(a.x, c.x, d.x);\n").length == 0;
	assert errorsOf(lib, pre + "function boom(): never { throw new Error(\"x\"); }\nfunction forge<V>(v: V): P { return v as P; }\nconst viaNever = (): P => boom() as P;\nconsole.log(forge<P>(p).x);\n").length == 0;
}

test "fieldVisibility: as takes a nullable struct to its payload and still refuses an unrelated one" {
	const lib = "export struct P { x: int32; }\nexport struct Q { x: int32; }\n";
	const pre = "import { P, Q } from \"./lib\";\nconst m = new Map<string, P>();\nm.set(\"a\", { x: 3 });\nfunction first(n: P | null): P { return n as P; }\nclass Store<K> { cells: Map<K, P> = new Map<K, P>(); at(k: K): P { return this.cells.get(k) as P; } }\n";
	assert errorsOf(lib, pre + "const got = m.get(\"a\") as P;\nconst s = new Store<string>();\ns.cells.set(\"b\", { x: 4 });\nconsole.log(got.x, first(got).x, s.at(\"b\").x);\n").length == 0;
	let refused = false;
	for (const m of diagnostics(lib, pre + "const q = m.get(\"a\") as Q;\n")) { if (m.indexOf("cannot convert P | null to Q") >= 0) refused = true; }
	assert refused;
}

test "fieldVisibility: as converts a generic struct instance only to itself, a distinct of it or a struct it extends" {
	const lib = "export struct P { x: int32; }\nexport struct Box<T> { x: int32; }\nexport struct Kept<T> extends P { item: T; }\nexport struct A { a: int32; }\nexport struct B { b: int32; }\nexport type D = distinct Box<A>;\n";
	const pre = "import { P, Box, Kept, A, B, D } from \"./lib\";\nconst p: P = { x: 3 };\nconst ba: Box<A> = { x: 1 };\nconst k: Kept<A> = { x: 2, item: { a: 4 } };\nfunction same<T>(b: Box<T>): Box<T> { return b as Box<T>; }\n";
	assert errorsOf(lib, pre + "const d = ba as D;\nconst back = d as Box<A>;\nconst up = k as P;\nconsole.log(same<A>(ba).x, back.x, up.x);\n").length == 0;
	assert reports(lib, pre + "const q = ba as Box<B>;\n", "cannot convert Box<A> to Box<B>");
	assert reports(lib, pre + "const q = p as Box<A>;\n", "cannot convert P to Box<A>");
	assert reports(lib, pre + "const q = ba as P;\n", "cannot convert Box<A> to P");
	assert reports(lib, pre + "function forge<T>(raw: P): Box<T> { return raw as Box<T>; }\nconsole.log(forge<A>(p).x);\n", "cannot convert P to Box<A>");
}

test "fieldVisibility: a refused struct conversion says who builds a struct with private fields" {
	const lib = "export struct Account { address: uint64; }\nexport struct Signer { private account: Account; }\nexport struct P { x: int32; }\nexport struct Q { x: int32; }\n";
	const pre = "import { Account, Signer, P, Q } from \"./lib\";\nconst raw: Account = { address: 1 };\nconst p: P = { x: 3 };\n";
	assert reports(lib, pre + "const s = raw as Signer;\n", "Signer has private fields, so only the module that declares it builds one");
	assert reports(lib, pre + "const q = p as Q;\n", "build a Q from its fields, or declare a converter from P to Q");
}

test "fieldVisibility: as converts a container only to one whose elements are equal up to distinct" {
	const lib = "export struct P { x: int32; }\nexport struct Q { y: string; }\nexport type D = distinct P;\n";
	const pre = "import { P, Q, D } from \"./lib\";\nconst ps: P[] = [{ x: 7 }];\nconst sized: P[2] = [{ x: 1 }, { x: 2 }];\nconst np: P | null = ps[0];\nconst tup: [P, int32] = [{ x: 1 }, 2];\nfunction made(): Result<P, string> { return Result.ok({ x: 3 }); }\nconst r = made();\n";
	assert errorsOf(lib, pre + "const same = ps as P[];\nconst ds = ps as D[];\nconst lit = [{ x: 4 }] as P[];\nconst got = np as P;\nconsole.log(same.length, ds.length, lit.length, got.x, sized.length, tup[1], r.ok);\n").length == 0;
	assert reports(lib, pre + "const q = ps as Q[];\n", "cannot convert P[] to Q[]: it holds P where Q[] holds Q");
	assert reports(lib, pre + "const q = ps as Q[];\n", "convert each element instead: `.map((e) => e as Q)`");
	assert reports(lib, pre + "const q = sized as Q[2];\n", "cannot convert P[2] to Q[2]");
	assert reports(lib, pre + "const q = r as Result<Q, string>;\n", "cannot convert Result<P, string> to Result<Q, string>");
	assert reports(lib, pre + "const q = tup as [Q, int32];\n", "cannot convert [P, int32] to [Q, int32]");
	assert reports(lib, pre + "const q = np as (Q | null);\n", "cannot convert P | null to Q | null");
	assert reports(lib, pre + "const ints: int32[] = [1];\nconst q = ints as string[];\n", "cannot convert int32[] to string[]");
}

function reports(library: string, main: string, needle: string): boolean {
	for (const m of diagnostics(library, main)) {
		if (m.indexOf(needle) >= 0) return true;
	}
	return false;
}

test "fieldVisibility: a private method is called inside its class only, a protected member also from a subclass" {
	const none = "export const unused = 0;\n";
	const cls = "class P {\n\tprotected level: int32 = 1;\n\tprivate secret(): int32 { return 40; }\n\tprotected shared(): int32 { return 2 + this.secret(); }\n\tpeekOther(other: P): int32 { return other.level + other.shared(); }\n\tstatic peek(p: P): int32 { return p.secret(); }\n}\nclass Q extends P {\n\ttotal(): int32 { return this.level + 1; }\n\tviaSibling(other: Q): int32 { return other.level; }\n}\n";
	assert errorsOf(none, cls + "const q = new Q();\nconsole.log(q.total(), q.viaSibling(q), q.peekOther(q), P.peek(q));\n").length == 0;
	assert reports(none, cls + "console.log(new P().secret());\n", "'secret' is a private method");
	assert reports(none, cls + "console.log(new P().shared());\n", "'shared' is a protected method of class 'P' and is only accessible inside that class and its subclasses");
	assert reports(none, cls + "console.log(new P().level);\n", "'level' is a protected field");
	assert reports(none, "class P { private secret(): int32 { return 40; } }\nclass Q extends P { peek(): int32 { return this.secret(); } }\n", "'secret' is a private method");
}

test "fieldVisibility: a subclass reaches a protected member only through an instance of itself" {
	const none = "export const unused = 0;\n";
	const base = "class P {\n\tprotected level: int32 = 1;\n\tprotected shared(): int32 { return 2; }\n}\n";
	const through = "only accessible through an instance of class 'Q'; this is an instance of class 'P'";
	assert reports(none, base + "class Q extends P { viaParent(p: P): int32 { return p.level; } }\n", through);
	assert reports(none, base + "class Q extends P { viaParent(p: P): int32 { return p.shared(); } }\n", through);
	assert reports(none, base + "class Q extends P { viaParent(): int32 { const me: P = this; return me.level; } }\n", through);
	assert reports(none, base + "class Q extends P { }\nclass S extends P { peek(q: Q): int32 { return q.level; } }\n", "only accessible through an instance of class 'S'; this is an instance of class 'Q'");
	assert errorsOf(none, base + "class Q extends P { }\nclass T extends Q { viaT(t: T): int32 { return t.level + this.level; } }\n").length == 0;
}

test "fieldVisibility: code a macro or template expands is checked with the macro's module as a friend" {
	const lib = "import { Node, NodeKind, DeclKind, ClassDecoratorContext } from \"std/meta\";\nexport struct Account { address: uint64; }\nexport struct Signer { private account: Account; }\nexport function address(this s: Signer): uint64 { return s.account.address; }\n"
		+ "export macro mint(value: Node): Node {\n\treturn { kind: NodeKind.TypeAssertion, line: 0, column: 0, asExpr: { kind: NodeKind.ObjectLiteral, line: 0, column: 0, keys: [\"account\"], properties: [value] }, asType: \"Signer\" };\n}\n"
		+ "export macro peek(s: Node): Node {\n\treturn { kind: NodeKind.MemberExpr, line: 0, column: 0, object: s, property: \"account\", isOptional: false };\n}\n"
		+ "export macro mintTwice(value: Node): Node {\n\treturn { kind: NodeKind.CallExpr, line: 0, column: 0, callee: { kind: NodeKind.Identifier, line: 0, column: 0, name: \"mint\" }, arguments: [value] };\n}\n"
		+ "export macro declareProof(value: Node): Node {\n\treturn { kind: NodeKind.SpliceMany, line: 0, column: 0, spliceNodes: [{ kind: NodeKind.VariableDecl, line: 0, column: 0, declName: \"proof\", declType: \"Signer\", initializer: { kind: NodeKind.ObjectLiteral, line: 0, column: 0, keys: [\"account\"], properties: [value] }, declKind: DeclKind.Const, nameLocation: { line: 0, column: 0 } }] };\n}\n"
		+ "export macro sealed(value: Node, context: ClassDecoratorContext): Node {\n\treturn value;\n}\n"
		+ "export template unwrapped(s: Signer): uint64 { return s.account.address; }\n"
		+ "export template showProof(s: Signer): void {\n\tconst inner = s.account;\n\tconsole.log(inner.address);\n}\n";
	const use = "import { Account, Signer, address, mint, peek, mintTwice, declareProof, sealed, unwrapped, showProof } from \"./lib\";\n";
	assert errorsOf(lib, use + "const s = mint({ address: 7 });\nconst t = mintTwice({ address: 8 });\nconsole.log(s.address(), peek(t).address, unwrapped(s));\n").length == 0;
	assert errorsOf(lib, use + "declareProof({ address: 3 });\nconst top = proof;\nfunction inside(): uint64 {\n\tdeclareProof({ address: 4 });\n\tshowProof(proof);\n\treturn proof.address() + top.address();\n}\n").length == 0;
	assert errorsOf(lib, use + "@sealed\nclass Reader { read(s: Signer): uint64 { return s.account.address; } }\n").length == 0;
	assert refusesPrivate(lib, use + "const s = { account: { address: 7 } } as Signer;\n", "account");
	assert refusesPrivate(lib, use + "const s = mint({ address: 7 });\nconsole.log(s.account.address);\n", "account");
	assert refusesPrivate(lib, use + "class Plain { read(s: Signer): uint64 { return s.account.address; } }\n", "account");
	assert refusesPrivate(lib, use + "function local(): void { const proof: Signer = { account: { address: 4 } }; }\n", "account");
}

const sealedLib = "export struct Proof { private word: uint64; }\nexport struct Mixed { pub: uint64; private word: uint64; }\nexport struct Box<T> { private v: T; }\nexport struct Wrap { n: uint64; p: Proof; }\nexport class Cls { x: uint64 = 1; }\nexport struct Holder { c: Cls; }\n"
	+ "export function make(): Proof { return { word: 7 }; }\nexport function makeBox<T>(v: T): Box<T> { return { v: v }; }\nexport function needs(p: Proof): uint64 { return 1; }\n"
	+ "function inside(flag: boolean): uint64 {\n\tlet a: Proof;\n\tif (flag) { a = {} as Proof; } else { a = { word: 1 }; }\n\tconst b: Proof = {};\n\tconst many: Proof[2] = [];\n\tconst more = new Array<Proof>(2);\n\tconst m: Mixed = { pub: 1 };\n\tconst w: Wrap = { n: 1 };\n\tlet bx: Box<uint64>;\n\tbx = { v: 1 };\n\treturn needs(a) + needs(b) + needs(many[0]) + needs(more[0]) + needs(w.p) + m.pub + bx.v + needs({});\n}\nexport const total: uint64 = inside(true);\n";
const sealedUse = "import { Proof, Mixed, Box, Wrap, Holder, make, makeBox, needs } from \"./lib\";\n";
const sealedWhy = "has a private field and can only be built by the module that declares it";

test "fieldVisibility: a struct with a private field has no default value outside its module" {
	const forms: string[] = [
		"function f(): uint64 { let p: Proof; return needs(p); }\n",
		"function f(flag: boolean): uint64 { let p: Proof; if (flag) { p = make(); } return needs(p); }\n",
		"function f(): uint64 { let r: Proof; return needs(r); }\nfunction g(): Proof { let r: Proof; return r; }\n",
		"function f(): uint64 { return needs({} as Proof); }\n",
		"function f(): uint64 { const p: Proof = {}; return needs(p); }\n",
		"function f(): uint64 { return needs({}); }\n",
		"function f(): uint64 { const m: Mixed = { pub: 1 }; return m.pub; }\n",
		"function f(): uint64 { const w: Wrap = { n: 1 }; return w.n; }\n",
		"function f(): uint64 { let b: Box<uint64>; return b.n; }\n",
		"let sealed: Proof;\nfunction f(): uint64 { return needs(sealed); }\n",
		"class Keeps { p: Proof; constructor() {} }\n",
	];
	for (const form of forms) assert reports(sealedLib, sealedUse + form, sealedWhy), form;
}

test "fieldVisibility: a sized array or a counted array of a struct with a private field is refused outside its module" {
	assert reports(sealedLib, sealedUse + "function f(): uint64 { let many: Proof[2]; return needs(many[0]); }\n", sealedWhy);
	assert reports(sealedLib, sealedUse + "function f(): uint64 { const many: Proof[2] = []; return needs(many[0]); }\n", "2 of 2 slots are left without a value");
	assert reports(sealedLib, sealedUse + "function f(): uint64 { const many: Proof[3] = [make()]; return needs(many[0]); }\n", "2 of 3 slots are left without a value");
	assert reports(sealedLib, sealedUse + "function f(): uint64 { const many = new Array<Proof>(2); return needs(many[0]); }\n", "would fill the array with default values");
	assert reports(sealedLib, sealedUse + "function f(): uint64 { const many: Proof[] = new Array(2); return needs(many[0]); }\n", "would fill the array with default values");
}

test "fieldVisibility: a sized array or a counted array of a struct holding a class is refused" {
	assert reports(sealedLib, sealedUse + "function f(): uint64 { let hs: Holder[2]; return hs[0].c.x; }\n", "may be read before it is assigned");
	assert reports(sealedLib, sealedUse + "function f(): uint64 { const hs: Holder[2] = []; return hs[0].c.x; }\n", "2 of 2 slots are left without a value");
	assert reports(sealedLib, sealedUse + "function f(): uint64 { const hs = new Array<Holder>(2); return hs[0].c.x; }\n", "would fill the array with default values");
}

test "fieldVisibility: a value from the declaring module, a full assignment and the declaring module itself are accepted" {
	assert errorsOf("export const unused = 0;\n", "export const total: uint64 = 0;\n").length == 0;
	assert errorsOf(sealedLib, sealedUse + "function pass(p: Proof): uint64 { return needs(p); }\nfunction every(flag: boolean): uint64 {\n\tlet x: Proof;\n\tif (flag) { x = make(); } else { x = make(); }\n\treturn needs(x);\n}\nfunction opt(): uint64 {\n\tlet o: Proof | null = null;\n\tif (o != null) return needs(o);\n\treturn 0;\n}\nconst boxed = makeBox<uint64>(3);\nconst full: Proof[2] = [make(), make()];\nconst dyn: Proof[] = [];\ndyn.push(make());\nconst grown = new Array<Proof>();\ngrown.push(make());\nconsole.log(pass(make()) + every(true) + opt() + needs(full[0]) + needs(dyn[0]) + needs(grown[0]));\n").length == 0;
	assert errorsOf("export const unused = 0;\n", sealedLib).length == 0;
}
