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

test "fieldVisibility: a private method is called inside its class only, a protected member also from a subclass" {
	const none = "export const unused = 0;\n";
	const cls = "class P {\n\tprotected level: int32 = 1;\n\tprivate secret(): int32 { return 40; }\n\tprotected shared(): int32 { return 2 + this.secret(); }\n\tstatic peek(p: P): int32 { return p.secret(); }\n}\nclass Q extends P {\n\ttotal(): int32 { return this.level + 1; }\n\tviaParent(): int32 { const me: P = this; return me.shared(); }\n}\n";
	assert errorsOf(none, cls + "const q = new Q();\nconsole.log(q.total(), q.viaParent(), P.peek(q));\n").length == 0;
	let privateCall = false;
	for (const m of diagnostics(none, cls + "console.log(new P().secret());\n")) { if (m.indexOf("'secret' is a private method") >= 0) privateCall = true; }
	assert privateCall;
	let protectedCall = false;
	for (const m of diagnostics(none, cls + "console.log(new P().shared());\n")) { if (m.indexOf("'shared' is a protected method") >= 0) protectedCall = true; }
	assert protectedCall;
	let protectedField = false;
	for (const m of diagnostics(none, cls + "console.log(new P().level);\n")) { if (m.indexOf("'level' is a protected field") >= 0) protectedField = true; }
	assert protectedField;
	let subclassPrivate = false;
	for (const m of diagnostics(none, "class P { private secret(): int32 { return 40; } }\nclass Q extends P { peek(): int32 { return this.secret(); } }\n")) { if (m.indexOf("'secret' is a private method") >= 0) subclassPrivate = true; }
	assert subclassPrivate;
}
