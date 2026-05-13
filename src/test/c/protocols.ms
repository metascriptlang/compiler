// E2E C: Convention-based dispatch protocols
//
// Coverage:
//   - Phase 1: `getDynamicField` synthesis — `obj.foo` rewrites to `obj.getDynamicField("foo")`
//   - Phase 2: `asTarget` family — `const n: T = expr` rewrites to `expr.asT()`
//   - Cross-protocol: both protocols co-exist on same type
//   - Edge cases: real field priority, LHS guard, generic interface, chaining
//
// Tests verify the source compiles cleanly via the MS pipeline (parse → check
// → transform → analyze → codegen). Runtime behavior is verified separately
// in `examples/testGetDynamicField.ms` and `examples/testAsTargetProtocol.ms`
// (compile + execute end-to-end).

import { compileToC, compileProjectToC } from "../helpers";

// =====================================================================
// Phase 1: getDynamicField protocol
// =====================================================================

test "E2E C: getDynamicField synthesis compiles" {
	const src = `
interface Stub { tag: string; }

export function getDynamicField(this s: Stub, key: string): string {
	return key + "!" + s.tag;
}

function main(): void {
	const x: Stub = { tag: "abc" };
	const a: string = x.foo;
	const b: string = x.bar;
}
`;
	const c = compileToC(src);
	assert c.ok;
}

test "E2E C: getDynamicField self-referential chain compiles" {
	const src = `
interface ChainNode { path: string; }

export function getDynamicField(this n: ChainNode, key: string): ChainNode {
	return { path: n.path + "/" + key };
}

function main(): void {
	const root: ChainNode = { path: "root" };
	const r4 = root.a.b.c.d;
}
`;
	const c = compileToC(src);
	assert c.ok;
}

test "E2E C: real declared field beats getDynamicField synthesis" {
	const src = `
interface Stub { tag: string; }

export function getDynamicField(this s: Stub, key: string): string {
	return key + "!" + s.tag;
}

function main(): void {
	const x: Stub = { tag: "real" };
	// 'tag' is declared field — must resolve to field, not synthesize
	const t: string = x.tag;
}
`;
	const c = compileToC(src);
	assert c.ok;
}

test "E2E C: optional chain doesn't trigger getDynamicField synthesis" {
	// `obj?.foo` must not route through protocol — preserves null-safety
	// semantics for the optional-chain transform pass.
	const src = `
interface Holder { tag: string; }

export function getDynamicField(this h: Holder, key: string): string {
	return key + ":" + h.tag;
}

function main(): void {
	const h: Holder = { tag: "x" };
	const s = h?.weirdField;
}
`;
	const c = compileToC(src);
	// Optional chain on a non-nullable holder: protocol skips, falls through to error
	assert !c.ok;
}

test "E2E C: LHS assignment doesn't trigger getDynamicField synthesis" {
	// Writing to an unknown property must error (strict TS-like behavior)
	// NOT silently route through getDynamicField as if it were a setter.
	const src = `
interface Holder { tag: string; }

export function getDynamicField(this h: Holder, key: string): string {
	return key + ":" + h.tag;
}

function main(): void {
	const h: Holder = { tag: "x" };
	h.weirdField = "should error";
}
`;
	const c = compileToC(src);
	// Expected to fail: protocol synthesis must NOT fire on LHS
	assert !c.ok;
}

// =====================================================================
// Phase 2: asTarget coercion protocol
// =====================================================================

test "E2E C: var-decl coercion via asNumber synthesizes" {
	const src = `
interface Wrap { v: int32; }

export function asNumber(this w: Wrap): number {
	return w.v as number;
}

function main(): void {
	const w: Wrap = { v: 42 };
	const n: number = w;
}
`;
	const c = compileToC(src);
	assert c.ok;
}

test "E2E C: call-arg coercion synthesizes" {
	const src = `
interface Wrap { v: int32; }

export function asNumber(this w: Wrap): number {
	return w.v as number;
}

function take(x: number): number { return x * 2; }

function main(): void {
	const w: Wrap = { v: 5 };
	const r = take(w);
}
`;
	const c = compileToC(src);
	assert c.ok;
}

test "E2E C: return-statement coercion synthesizes" {
	const src = `
interface Wrap { v: int32; }

export function asNumber(this w: Wrap): number {
	return w.v as number;
}

function unwrap(): number {
	const w: Wrap = { v: 99 };
	return w;
}

function main(): void { const _ = unwrap(); }
`;
	const c = compileToC(src);
	assert c.ok;
}

test "E2E C: exact return-type match (asInt32 vs asInt64)" {
	const src = `
interface IntBox { v: int32; }

export function asInt32(this b: IntBox): int32 { return b.v; }
export function asInt64(this b: IntBox): int64 { return b.v as int64; }

function main(): void {
	const x: IntBox = { v: 100 };
	const a: int32 = x;
	const b: int64 = x;
}
`;
	const c = compileToC(src);
	assert c.ok;
}

// =====================================================================
// Cross-protocol: both protocols on same type
// =====================================================================

test "E2E C: cross-protocol — dynamic chain coerced to string" {
	const src = `
interface Doc { tag: string; }

export function getDynamicField(this d: Doc, key: string): Doc {
	return { tag: d.tag + "." + key };
}

export function asString(this d: Doc): string {
	return "[" + d.tag + "]";
}

function main(): void {
	const root: Doc = { tag: "root" };
	const s: string = root.user.name;
}
`;
	const c = compileToC(src);
	assert c.ok;
}

// =====================================================================
// Edge cases
// =====================================================================

test "E2E C: method call after dynamic-access chain" {
	const src = `
interface Box { tag: string; }

export function getDynamicField(this b: Box, key: string): Box {
	return { tag: b.tag + "/" + key };
}

export function describe(this b: Box): string {
	return "(" + b.tag + ")";
}

function main(): void {
	const root: Box = { tag: "root" };
	const desc = root.alpha.beta.describe();
}
`;
	const c = compileToC(src);
	assert c.ok;
}

test "E2E C: dynamic access on CallExpr result" {
	const src = `
interface Box { tag: string; }

export function getDynamicField(this b: Box, key: string): Box {
	return { tag: b.tag + "/" + key };
}

function makeBox(name: string): Box { return { tag: name }; }

function main(): void {
	const x = makeBox("factory").extra.more;
}
`;
	const c = compileToC(src);
	assert c.ok;
}

test "E2E C: multiple getDynamicField overloads (string + int key)" {
	const src = `
interface Mixed { tag: string; }

export function getDynamicField(this m: Mixed, key: string): string {
	return "str:" + key + "/" + m.tag;
}

export function getDynamicField(this m: Mixed, key: int32): string {
	return "int:" + (key as number).toString() + "/" + m.tag;
}

function main(): void {
	const m: Mixed = { tag: "z" };
	const s: string = m.foo;
	const t: string = m.getDynamicField(42);
}
`;
	const c = compileToC(src);
	assert c.ok;
}

test "E2E C: generic interface with getDynamicField" {
	const src = `
interface Container<T> {
	items: T[];
}

export function getDynamicField<T>(this c: Container<T>, key: string): T {
	if (key === "first" && c.items.length > 0) return c.items[0];
	if (key === "last" && c.items.length > 0) return c.items[c.items.length - 1];
	unreachable;
}

function main(): void {
	const ints: Container<int32> = { items: [10, 20, 30] };
	const f: int32 = ints.first;
	const l: int32 = ints.last;
}
`;
	const c = compileToC(src);
	assert c.ok;
}

// =====================================================================
// Cross-module protocol resolution (relevant for Layer A SERIALIZE)
// =====================================================================

// =====================================================================
// Phase 6: setDynamicField protocol (write side)
// =====================================================================

test "E2E C: setDynamicField synthesis compiles" {
	const src = `
interface Store { tag: string; }

export function getDynamicField(this s: Store, key: string): string {
	return key + "/" + s.tag;
}

export function setDynamicField(this s: Store, key: string, value: string): void {
	// stub body — just observe key/value flow at type level
}

function main(): void {
	const s: Store = { tag: "init" };
	s.foo = "v1";
	s.bar = "v2";
}
`;
	const c = compileToC(src);
	assert c.ok;
}

test "E2E C: real field write beats setDynamicField synthesis" {
	const src = `
interface Box { tag: string; }

export function setDynamicField(this b: Box, key: string, value: string): void {}

function main(): void {
	const b: Box = { tag: "old" };
	// 'tag' is real field — must resolve to field write, not protocol call
	b.tag = "new";
}
`;
	const c = compileToC(src);
	assert c.ok;
}

test "E2E C: compound assignment on dynamic field rejected with clear error" {
	const src = `
interface Counter { tag: string; }

export function getDynamicField(this c: Counter, key: string): int32 { return 0; }
export function setDynamicField(this c: Counter, key: string, value: int32): void {}

function main(): void {
	const c: Counter = { tag: "x" };
	c.hits += 1;
}
`;
	const c = compileToC(src);
	assert !c.ok;
}

// Chain write `a.b.c = x` (intermediate reads + final write) is deferred to
// V2: requires `leftPartOfAsgn` to be scoped to the outermost MemberExpr of
// the LHS so intermediates can fire `getDynamicField`. Out of scope for the
// initial setDynamicField rollout.

test "E2E C: setDynamicField type-coercion of RHS via fitNode" {
	const src = `
interface Box { tag: string; }

export function setDynamicField(this b: Box, key: string, value: int64): void {}

function main(): void {
	const b: Box = { tag: "x" };
	// RHS is int32 literal — fitNode must widen to int64 to match ext signature
	b.count = 100;
}
`;
	const c = compileToC(src);
	assert c.ok;
}

test "E2E C: setDynamicField recursion-guard — direct setDynamicField call still works" {
	const src = `
interface Bag { tag: string; }

export function setDynamicField(this b: Bag, key: string, value: string): void {}

function main(): void {
	const b: Bag = { tag: "t" };
	// Explicit call — must NOT re-synthesize. d.property === "setDynamicField" is the recursion guard.
	b.setDynamicField("k", "v");
}
`;
	const c = compileToC(src);
	assert c.ok;
}

test "E2E C: setDynamicField rejected when no extension exists" {
	const src = `
interface Plain { tag: string; }

function main(): void {
	const p: Plain = { tag: "x" };
	// No setDynamicField extension — error stays "Property does not exist"
	p.weirdField = "should error";
}
`;
	const c = compileToC(src);
	assert !c.ok;
}

test "E2E C: setDynamicField eval-once for side-effecting receiver" {
	// `getObj().foo = x` must evaluate getObj() exactly once. AST mutation
	// places md.object in a single slot (the synthesized callee's object),
	// so codegen sees one call site. Runtime POC verified at
	// examples/testSetDynamicField.ms style (callCount = 1 after one statement);
	// here we pin the compile-time invariant by checking the source compiles.
	const src = `
interface Box { tag: string; }
export function setDynamicField(this b: Box, key: string, value: int32): void {}
function makeBox(): Box { return { tag: "made" }; }
function main(): void {
	makeBox().count = 42;
}
`;
	const c = compileToC(src);
	assert c.ok;
}

test "E2E C: setDynamicField cross-module — extension in lib, used in main" {
	const entries = [
		{ entryPath: "src/lib.ms", entrySource: `
			export interface Bag { tag: string; }
			export function setDynamicField(this b: Bag, key: string, value: string): void {}
		` },
		{ entryPath: "src/main.ms", entrySource: `
			import { Bag } from "./lib";
			function main(): void {
				const b: Bag = { tag: "t" };
				b.foo = "hello";
			}
		` },
	];
	const cCode = compileProjectToC(entries, "src/main.ms");
	assert !cCode.contains("ERROR:");
}

test "E2E C: setDynamicField with async RHS type-checks" {
	const src = `
interface Box { tag: string; }
export function setDynamicField(this b: Box, key: string, value: int32): void {}

async function fetchVal(): Promise<int32> { return 99; }

async function doWork(): Promise<void> {
	const b: Box = { tag: "t" };
	b.count = await fetchVal();
}
function main(): void { doWork(); }
`;
	const c = compileToC(src);
	assert c.ok;
}

test "E2E C: JsonValue dynamic write via setDynamicField" {
	// Uses jsonObject() directly to avoid the pre-existing `r.value` narrowing
	// quirk that drops the Ref<JsonValueData> wrapping. The protocol path itself
	// works end-to-end (see examples/testSetDynamicField.ms for runtime POC).
	const src = `
function main(): void {
	const j = jsonObject(["name"], [jsonString("Alice")]);
	j.age = jsonInt(30 as int64);
	j.name = jsonString("Bob");
}
`;
	const c = compileToC(src);
	assert c.ok;
}

test "E2E C: JsonValue dynamic access via protocol after migration" {
	// Verifies Phase 3 migration: JsonValue.foo → JsonValue.getDynamicField("foo")
	// resolves through the protocol synthesis (not the deleted hardcoded path).
	const src = `
function main(): void {
	const r = JSON.parseValue("{\\"name\\":\\"Alice\\"}");
	if (r.ok) {
		const v = r.value;
		// dynamic access via protocol
		const name: string = v.name;
		// explicit accessor still works
		const explicit = v.name.asString();
	}
}
`;
	const c = compileToC(src);
	assert c.ok;
}
