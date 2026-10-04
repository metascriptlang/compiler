import { hasError, strictErrorCount } from "./helpers";
import { compileToC } from "../helpers";

const NODE = "class Node { name: string = \"n\"; }\n";

const CLASSES = `
class BaseNode { id: int32 = 0; }
class NativeNode extends BaseNode { view: string = "native"; }
interface I { v: int32; }
class Box<T> { v: T; constructor(v: T) { this.v = v; } }
`;

const KEEPER = `
class Node { name: string = "n"; }
actor K { private kept: unknown = null; take(u: unknown): void { this.kept = u; } }
`;

test "unknownAdmission: a raw address is refused as unknown by return, argument and cast" {
	const refused = [
		{
			name: "a Ptr<void> returned as unknown",
			source: "function f(p: Ptr<void>): unknown { return p; }",
		},
		{
			name: "a Ptr<void> passed to an unknown parameter",
			source: "function g(u: unknown): void {}\n" +
				"function f(p: Ptr<void>): void { g(p); }",
		},
		{
			name: "a cstring cast to unknown",
			source: "function f(c: cstring): unknown { return c as unknown; }",
		},
	];
	for (const row of refused) {
		assert hasError(row.source, "raw address"), row.name;
	}
}

test "unknownAdmission: an int32 reaches an enum by a direct cast, never through unknown" {
	const declaration = "enum K { A, B }\n";
	const reinterpreted = declaration + "function f(i: int32): K { return i as unknown as K; }";
	assert hasError(reinterpreted, "convert with `as K`");
	const direct = declaration + "function f(i: int32): K { return i as K; }";
	assert strictErrorCount(direct) == 0;
}

test "unknownAdmission: class and interface instances enter unknown" {
	const accepted = [
		{
			name: "a class instance",
			source: NODE + "function f(): void { const a: unknown = new Node(); }",
		},
		{
			name: "an interface object",
			source: "interface I { v: int32; }\n" +
				"function f(): void { const b: unknown = { v: 1 } as I; }",
		},
		{
			name: "a generic class instance",
			source: "class Box<T> { v: T; constructor(v: T) { this.v = v; } }\n" +
				"function f(): void { const c: unknown = new Box<int32>(1); }",
		},
	];
	for (const row of accepted) {
		assert strictErrorCount(row.source) == 0, row.name;
	}
}

test "unknownAdmission: an array and a map do not enter unknown" {
	const refused = [
		{
			name: "an array",
			source: "function f(): void { const xs: int32[] = [1]; const u: unknown = xs; }",
		},
		{
			name: "a map",
			source: "function f(): void { " +
				"const m = new Map<string, int32>(); const u: unknown = m; }",
		},
	];
	for (const row of refused) {
		assert hasError(row.source, "unknown holds class and interface instances"), row.name;
	}
}

test "unknownAdmission: unknown casts out to a class and to the address it holds" {
	const accepted = [
		{
			name: "a class",
			source: CLASSES + "function f(u: unknown): string { return (u as NativeNode).view; }",
		},
		{
			name: "the address of the object it holds, spelled Ptr<void>",
			source: "class C { v: int32 = 1; }\n" +
				"function f(c: C): Ptr<void> { const u: unknown = c; return u as Ptr<void>; }",
		},
	];
	for (const row of accepted) {
		assert strictErrorCount(row.source) == 0, row.name;
	}
}

test "unknownAdmission: instanceof narrows unknown to a class" {
	const source = CLASSES + "function f(u: unknown): string { " +
		"if (u instanceof NativeNode) return u.view; return \"\"; }";
	assert strictErrorCount(source) == 0;
}

test "unknownAdmission: unknown casts out to a generic class instance" {
	assert strictErrorCount(CLASSES + "function f(u: unknown): int32 { return (u as Box<int32>).v; }") == 0;
}

test "unknownAdmission: unknown casts out to no interface, C string or value" {
	const refused = [
		{
			name: "an interface",
			source: CLASSES + "function f(u: unknown): int32 { return (u as I).v; }",
			needle: "only a class has a runtime identity",
		},
		{
			name: "a C string",
			source: "function f(u: unknown): cstring { return u as cstring; }",
			needle: "never a C string",
		},
		{
			name: "a value type",
			source: "function f(u: unknown): int32 { return u as int32; }",
			needle: "the value type int32",
		},
	];
	for (const row of refused) {
		assert hasError(row.source, row.needle), row.name;
	}
}

test "unknownAdmission: a function cast never carries a value through an unknown slot" {
	const refused = [
		{
			name: "a string through an unknown return",
			source: "function f(g: () => string): () => unknown { return g as () => unknown; }",
		},
		{
			name: "an int32 through an unknown parameter",
			source: "function f(g: (x: unknown) => void): (x: int32) => void { " +
				"return g as (x: int32) => void; }",
		},
	];
	for (const row of refused) {
		assert hasError(row.source, "through an unknown slot"), row.name;
	}
}

test "unknownAdmission: a C extern signature never names unknown" {
	const refused = [
		{ name: "a parameter", source: "extern function h(p: unknown): void;" },
		{ name: "a nilable return", source: "extern function h(): unknown | null;" },
	];
	for (const row of refused) {
		assert hasError(row.source, "declare it Ptr<void>"), row.name;
	}
}

test "unknownAdmission: a C extern's variadic tail stays open to unknown" {
	const source = "extern function printf(fmt: cstring, ...args: unknown[]): int32;";
	assert strictErrorCount(source) == 0;
}

test "unknownAdmission: an unknown reaches an actor only by move" {
	const source = KEEPER +
		"function f(): void { const k = new K(); const u: unknown = new Node(); k.take(u); }";
	assert hasError(source, "actor methods only accept");
}

test "unknownAdmission: an actor holds an unknown field and takes one by move" {
	const c = compileToC(KEEPER +
		"function f(): void { " +
		"const k = new K(); const u: unknown = new Node(); k.take(move u); }\n" +
		"f();");
	assert c.ok, c.ok ? "" : c.error;
}

test "unknownAdmission: a spawn thunk sees a captured unknown as a read-only view" {
	const source = NODE + `
async function f(): Promise<void> {
	const u: unknown = new Node();
	const h = spawn(() => { (u as Node).name = "x"; return 1; });
	await h;
}`;
	assert hasError(source, "Readonly<unknown>");
}
