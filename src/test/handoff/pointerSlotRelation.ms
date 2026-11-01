import { strictErrorCount, hasError, checkSource } from "./helpers";
import { Severity } from "../../checker/context";
import { compileToC, compileToCWithStd, compileToJS } from "../helpers";

test "pointerSlotRelation: cursor nullability does not make ordinary references nullable" {
	const cases = [
		{ name: "bare null initializes a Cursor field", source: "interface BA { tag: string; next: Cursor<BA>; } function f(): void { const a: BA = { tag: \"x\", next: null }; }", expected: 0 },
		{ name: "bare null assigns into a Cursor field", source: "interface BA { tag: string; next: Cursor<BA>; } function f(a: BA): void { a.next = null; }", expected: 0 },
		{ name: "a ref assigns into a Cursor field", source: "interface BA { tag: string; next: Cursor<BA>; } function f(): void { const a: BA = { tag: \"x\", next: null }; const b: BA = { tag: \"y\", next: null }; a.next = b; }", expected: 0 },
		{ name: "null into a plain ref field by assignment is rejected", source: "interface BP { tag: string; } interface BH { p: BP; } function f(h: BH): void { h.p = null; }", expected: -1 },
		{ name: "null into a plain ref local by assignment is rejected", source: "interface BP { tag: string; } function f(): void { let p: BP = { tag: \"x\" }; p = null; }", expected: -1 },
		{ name: "null into a T | null field stays legal", source: "interface BP { tag: string; } interface BH { p: BP | null; } function f(h: BH): void { h.p = null; }", expected: 0 },
		{ name: "null into a bare Ptr field literal stays rejected", source: "interface BP { tag: string; next: Ptr<BP>; } function f(): void { const a: BP = { tag: \"x\", next: null }; }", expected: -1 },
	];
	for (const item of cases) {
		const errors = strictErrorCount(item.source);
		assert item.expected < 0 ? errors > 0 : errors == item.expected, item.name;
	}
}

test "pointerSlotRelation: nullable value slots fit the payload representation" {
	const cases = [
		{ name: "a returned value struct fits its nullable slot", source: "\nstruct V { n: float64; }\nfunction makeV(): V { const v: V = { n: 1.5 }; return v; }\nconst v: V | null = makeV();\n", expected: 0 },
		{ name: "an object literal fits its value-struct nullable slot", source: "\nstruct V { n: float64; }\nconst v: V | null = { n: 1.5 };\n", expected: 0 },
		{ name: "a different value struct remains rejected", source: "\nstruct V { n: float64; }\nstruct W { name: string; }\nfunction makeW(): W { const w: W = { name: \"wrong\" }; return w; }\nconst v: V | null = makeW();\n", expected: -1 },
	];
	for (const item of cases) {
		const result = compileToC(item.source);
		assert result.ok == (item.expected == 0), item.name + (result.ok ? "" : ": " + result.error);
	}
}

test "pointerSlotRelation: borrow promotion admits values but never null" {
	const cases = [
		{ name: "null into an extern Borrow<struct> param is refused", source: "\nstruct P { a: int32; }\nextern function takesBorrow(p: Borrow<P>): int32;\nextern function takesScalar(v: Borrow<float32>): int32;\nfunction local(p: Borrow<P>): int32 { return p.a; }\nfunction main(): void { takesBorrow(null); }", expected: -1 },
		{ name: "null into a Borrow<scalar> param is refused", source: "\nstruct P { a: int32; }\nextern function takesBorrow(p: Borrow<P>): int32;\nextern function takesScalar(v: Borrow<float32>): int32;\nfunction local(p: Borrow<P>): int32 { return p.a; }\nfunction main(): void { takesScalar(null); }", expected: -1 },
		{ name: "null into a MetaScript function's Borrow param is refused", source: "\nstruct P { a: int32; }\nextern function takesBorrow(p: Borrow<P>): int32;\nextern function takesScalar(v: Borrow<float32>): int32;\nfunction local(p: Borrow<P>): int32 { return p.a; }\nfunction main(): void { local(null); }", expected: -1 },
		{ name: "a value still promotes to Borrow", source: "\nstruct P { a: int32; }\nextern function takesBorrow(p: Borrow<P>): int32;\nextern function takesScalar(v: Borrow<float32>): int32;\nfunction local(p: Borrow<P>): int32 { return p.a; }\nfunction main(): void { const p: P = { a: 1 }; local(p); }", expected: 0 },
	];
	for (const item of cases) {
		const result = compileToCWithStd(item.source);
		assert result.ok == (item.expected == 0), item.name + (result.ok ? "" : ": " + result.error);
	}
}

test "pointerSlotRelation: extern address promotion preserves pointee identity" {
	const cases = [
		{ name: "a struct of another type into Ptr<P> | null is refused", source: "\nstruct P { a: int32; }\nstruct Q { b: int32; }\nfunction f(p: Ptr<P> | null): int32 { return p == null ? 0 : p.a; }\nextern function g(p: Ptr<P> | null): int32;\nfunction main(): void { const q: Q = { b: 1 }; f(q); }", expected: -1 },
		{ name: "the same holds for an extern parameter", source: "\nstruct P { a: int32; }\nstruct Q { b: int32; }\nfunction f(p: Ptr<P> | null): int32 { return p == null ? 0 : p.a; }\nextern function g(p: Ptr<P> | null): int32;\nfunction main(): void { const q: Q = { b: 1 }; g(q); }", expected: -1 },
		{ name: "the pointee struct into an extern, and null, are accepted", source: "\nstruct P { a: int32; }\nstruct Q { b: int32; }\nfunction f(p: Ptr<P> | null): int32 { return p == null ? 0 : p.a; }\nextern function g(p: Ptr<P> | null): int32;\nfunction main(): void { let p: P = { a: 1 }; g(p); g(null); f(null); }", expected: 0 },
		{ name: "a struct into a MetaScript function's Ptr<C> | null param is refused", source: "\nstruct C { a: int32; }\nfunction keep(p: Ptr<C> | null): int32 { return p == null ? 0 : p.a; }\nfunction pick<T>(p: Ptr<C> | null, t: T): int32 { return p == null ? 0 : p.a; }\nclass K { take(p: Ptr<C> | null): int32 { return p == null ? 0 : p.a; } }\nextern function ext(p: Ptr<C> | null): int32;\nfunction bump(ref p: C): void { p.a = p.a + 1; }\nfunction main(): void { const c: C = { a: 1 }; keep(c); }", expected: -1 },
		{ name: "the same through a method, a closure and a generic function", source: "\nstruct C { a: int32; }\nfunction keep(p: Ptr<C> | null): int32 { return p == null ? 0 : p.a; }\nfunction pick<T>(p: Ptr<C> | null, t: T): int32 { return p == null ? 0 : p.a; }\nclass K { take(p: Ptr<C> | null): int32 { return p == null ? 0 : p.a; } }\nextern function ext(p: Ptr<C> | null): int32;\nfunction bump(ref p: C): void { p.a = p.a + 1; }\nfunction main(): void { const c: C = { a: 1 }; const k = new K(); k.take(c); }", expected: -1 },
		{ name: "the same through a method, a closure and a generic function", source: "\nstruct C { a: int32; }\nfunction keep(p: Ptr<C> | null): int32 { return p == null ? 0 : p.a; }\nfunction pick<T>(p: Ptr<C> | null, t: T): int32 { return p == null ? 0 : p.a; }\nclass K { take(p: Ptr<C> | null): int32 { return p == null ? 0 : p.a; } }\nextern function ext(p: Ptr<C> | null): int32;\nfunction bump(ref p: C): void { p.a = p.a + 1; }\nfunction main(): void { const c: C = { a: 1 }; const f = (p: Ptr<C> | null): int32 => 0; f(c); }", expected: -1 },
		{ name: "the same through a method, a closure and a generic function", source: "\nstruct C { a: int32; }\nfunction keep(p: Ptr<C> | null): int32 { return p == null ? 0 : p.a; }\nfunction pick<T>(p: Ptr<C> | null, t: T): int32 { return p == null ? 0 : p.a; }\nclass K { take(p: Ptr<C> | null): int32 { return p == null ? 0 : p.a; } }\nextern function ext(p: Ptr<C> | null): int32;\nfunction bump(ref p: C): void { p.a = p.a + 1; }\nfunction main(): void { const c: C = { a: 1 }; pick(c, 1); }", expected: -1 },
		{ name: "an extern callee still takes the address, and null and ref still work", source: "\nstruct C { a: int32; }\nfunction keep(p: Ptr<C> | null): int32 { return p == null ? 0 : p.a; }\nfunction pick<T>(p: Ptr<C> | null, t: T): int32 { return p == null ? 0 : p.a; }\nclass K { take(p: Ptr<C> | null): int32 { return p == null ? 0 : p.a; } }\nextern function ext(p: Ptr<C> | null): int32;\nfunction bump(ref p: C): void { p.a = p.a + 1; }\nfunction main(): void { let c: C = { a: 1 }; ext(c); ext(null); keep(null); let m: C = { a: 1 }; bump(m); }", expected: 0 },
		{ name: "a scalar, boolean and enum local pass by address to an extern's Ptr<T> | null", source: "\nenum Mode { A, B }\nstruct C { a: int32; }\nstruct Pair { x: int32; y: uint16; }\nclass Box { n: int32 = 0; }\nextern function fillI32(p: Ptr<int32> | null): int32;\nextern function fillU16(p: Ptr<uint16> | null): int32;\nextern function fillF64(p: Ptr<number> | null): int32;\nextern function fillBool(p: Ptr<boolean> | null): int32;\nextern function fillMode(p: Ptr<Mode> | null): int32;\nextern function fillI64(p: Ptr<int64> | null): int32;\nextern function fillAny(p: Ptr<void> | null): int32;\nextern function readI32(p: Borrow<int32>): int32;\nfunction keep(p: Ptr<int32> | null): int32 { return p == null ? 0 : 1; }\nfunction one(): int32 { return 1; }\nfunction main(): void { let i: int32 = 0; let u: uint16 = 0; let f: number = 0; let b = false; let m = Mode.A; fillI32(i); fillU16(u); fillF64(f); fillBool(b); fillMode(m); fillI32(null); }", expected: 0 },
		{ name: "any C value local passes by address to an extern's Ptr<void> | null", source: "\nenum Mode { A, B }\nstruct C { a: int32; }\nstruct Pair { x: int32; y: uint16; }\nclass Box { n: int32 = 0; }\nextern function fillI32(p: Ptr<int32> | null): int32;\nextern function fillU16(p: Ptr<uint16> | null): int32;\nextern function fillF64(p: Ptr<number> | null): int32;\nextern function fillBool(p: Ptr<boolean> | null): int32;\nextern function fillMode(p: Ptr<Mode> | null): int32;\nextern function fillI64(p: Ptr<int64> | null): int32;\nextern function fillAny(p: Ptr<void> | null): int32;\nextern function readI32(p: Borrow<int32>): int32;\nfunction keep(p: Ptr<int32> | null): int32 { return p == null ? 0 : 1; }\nfunction one(): int32 { return 1; }\nfunction main(): void { let u: uint16 = 0; let m = Mode.B; let c: C = { a: 1 }; fillAny(u); fillAny(m); fillAny(c); fillAny(null); }", expected: 0 },
		{ name: "a field, an element and a class field have an address", source: "\nenum Mode { A, B }\nstruct C { a: int32; }\nstruct Pair { x: int32; y: uint16; }\nclass Box { n: int32 = 0; }\nextern function fillI32(p: Ptr<int32> | null): int32;\nextern function fillU16(p: Ptr<uint16> | null): int32;\nextern function fillF64(p: Ptr<number> | null): int32;\nextern function fillBool(p: Ptr<boolean> | null): int32;\nextern function fillMode(p: Ptr<Mode> | null): int32;\nextern function fillI64(p: Ptr<int64> | null): int32;\nextern function fillAny(p: Ptr<void> | null): int32;\nextern function readI32(p: Borrow<int32>): int32;\nfunction keep(p: Ptr<int32> | null): int32 { return p == null ? 0 : 1; }\nfunction one(): int32 { return 1; }\nfunction main(): void { let p: Pair = { x: 0, y: 0 }; const a: int32[] = [0, 0]; const box = new Box(); fillI32(p.x); fillU16(p.y); fillI32(a[1]); fillI32(box.n); }", expected: 0 },
		{ name: "a literal, a call result and an enum member have no address", source: "\nenum Mode { A, B }\nstruct C { a: int32; }\nstruct Pair { x: int32; y: uint16; }\nclass Box { n: int32 = 0; }\nextern function fillI32(p: Ptr<int32> | null): int32;\nextern function fillU16(p: Ptr<uint16> | null): int32;\nextern function fillF64(p: Ptr<number> | null): int32;\nextern function fillBool(p: Ptr<boolean> | null): int32;\nextern function fillMode(p: Ptr<Mode> | null): int32;\nextern function fillI64(p: Ptr<int64> | null): int32;\nextern function fillAny(p: Ptr<void> | null): int32;\nextern function readI32(p: Borrow<int32>): int32;\nfunction keep(p: Ptr<int32> | null): int32 { return p == null ? 0 : 1; }\nfunction one(): int32 { return 1; }\nfunction main(): void { fillI32(3); }", expected: -1 },
		{ name: "a literal, a call result and an enum member have no address", source: "\nenum Mode { A, B }\nstruct C { a: int32; }\nstruct Pair { x: int32; y: uint16; }\nclass Box { n: int32 = 0; }\nextern function fillI32(p: Ptr<int32> | null): int32;\nextern function fillU16(p: Ptr<uint16> | null): int32;\nextern function fillF64(p: Ptr<number> | null): int32;\nextern function fillBool(p: Ptr<boolean> | null): int32;\nextern function fillMode(p: Ptr<Mode> | null): int32;\nextern function fillI64(p: Ptr<int64> | null): int32;\nextern function fillAny(p: Ptr<void> | null): int32;\nextern function readI32(p: Borrow<int32>): int32;\nfunction keep(p: Ptr<int32> | null): int32 { return p == null ? 0 : 1; }\nfunction one(): int32 { return 1; }\nfunction main(): void { fillI32(one()); }", expected: -1 },
		{ name: "a literal, a call result and an enum member have no address", source: "\nenum Mode { A, B }\nstruct C { a: int32; }\nstruct Pair { x: int32; y: uint16; }\nclass Box { n: int32 = 0; }\nextern function fillI32(p: Ptr<int32> | null): int32;\nextern function fillU16(p: Ptr<uint16> | null): int32;\nextern function fillF64(p: Ptr<number> | null): int32;\nextern function fillBool(p: Ptr<boolean> | null): int32;\nextern function fillMode(p: Ptr<Mode> | null): int32;\nextern function fillI64(p: Ptr<int64> | null): int32;\nextern function fillAny(p: Ptr<void> | null): int32;\nextern function readI32(p: Borrow<int32>): int32;\nfunction keep(p: Ptr<int32> | null): int32 { return p == null ? 0 : 1; }\nfunction one(): int32 { return 1; }\nfunction main(): void { fillMode(Mode.A); }", expected: -1 },
		{ name: "the pointee is matched exactly, not by widening", source: "\nenum Mode { A, B }\nstruct C { a: int32; }\nstruct Pair { x: int32; y: uint16; }\nclass Box { n: int32 = 0; }\nextern function fillI32(p: Ptr<int32> | null): int32;\nextern function fillU16(p: Ptr<uint16> | null): int32;\nextern function fillF64(p: Ptr<number> | null): int32;\nextern function fillBool(p: Ptr<boolean> | null): int32;\nextern function fillMode(p: Ptr<Mode> | null): int32;\nextern function fillI64(p: Ptr<int64> | null): int32;\nextern function fillAny(p: Ptr<void> | null): int32;\nextern function readI32(p: Borrow<int32>): int32;\nfunction keep(p: Ptr<int32> | null): int32 { return p == null ? 0 : 1; }\nfunction one(): int32 { return 1; }\nfunction main(): void { let i: int32 = 0; fillI64(i); }", expected: -1 },
		{ name: "a MetaScript function and a variable still refuse a scalar", source: "\nenum Mode { A, B }\nstruct C { a: int32; }\nstruct Pair { x: int32; y: uint16; }\nclass Box { n: int32 = 0; }\nextern function fillI32(p: Ptr<int32> | null): int32;\nextern function fillU16(p: Ptr<uint16> | null): int32;\nextern function fillF64(p: Ptr<number> | null): int32;\nextern function fillBool(p: Ptr<boolean> | null): int32;\nextern function fillMode(p: Ptr<Mode> | null): int32;\nextern function fillI64(p: Ptr<int64> | null): int32;\nextern function fillAny(p: Ptr<void> | null): int32;\nextern function readI32(p: Borrow<int32>): int32;\nfunction keep(p: Ptr<int32> | null): int32 { return p == null ? 0 : 1; }\nfunction one(): int32 { return 1; }\nfunction main(): void { let i: int32 = 0; keep(i); }", expected: -1 },
		{ name: "a MetaScript function and a variable still refuse a scalar", source: "\nenum Mode { A, B }\nstruct C { a: int32; }\nstruct Pair { x: int32; y: uint16; }\nclass Box { n: int32 = 0; }\nextern function fillI32(p: Ptr<int32> | null): int32;\nextern function fillU16(p: Ptr<uint16> | null): int32;\nextern function fillF64(p: Ptr<number> | null): int32;\nextern function fillBool(p: Ptr<boolean> | null): int32;\nextern function fillMode(p: Ptr<Mode> | null): int32;\nextern function fillI64(p: Ptr<int64> | null): int32;\nextern function fillAny(p: Ptr<void> | null): int32;\nextern function readI32(p: Borrow<int32>): int32;\nfunction keep(p: Ptr<int32> | null): int32 { return p == null ? 0 : 1; }\nfunction one(): int32 { return 1; }\nfunction main(): void { let i: int32 = 0; let p: Ptr<int32> | null = i; }", expected: -1 },
		{ name: "a ref parameter forwards its pointer, not the pointer's address", source: "\nenum Mode { A, B }\nstruct C { a: int32; }\nstruct Pair { x: int32; y: uint16; }\nclass Box { n: int32 = 0; }\nextern function fillI32(p: Ptr<int32> | null): int32;\nextern function fillU16(p: Ptr<uint16> | null): int32;\nextern function fillF64(p: Ptr<number> | null): int32;\nextern function fillBool(p: Ptr<boolean> | null): int32;\nextern function fillMode(p: Ptr<Mode> | null): int32;\nextern function fillI64(p: Ptr<int64> | null): int32;\nextern function fillAny(p: Ptr<void> | null): int32;\nextern function readI32(p: Borrow<int32>): int32;\nfunction keep(p: Ptr<int32> | null): int32 { return p == null ? 0 : 1; }\nfunction one(): int32 { return 1; }\nfunction fwd(ref n: int32): void { fillI32(n); fillAny(n); }", expected: 0 },
		{ name: "a ref parameter forwarded to a Borrow<T> passes its pointer", source: "\nenum Mode { A, B }\nstruct C { a: int32; }\nstruct Pair { x: int32; y: uint16; }\nclass Box { n: int32 = 0; }\nextern function fillI32(p: Ptr<int32> | null): int32;\nextern function fillU16(p: Ptr<uint16> | null): int32;\nextern function fillF64(p: Ptr<number> | null): int32;\nextern function fillBool(p: Ptr<boolean> | null): int32;\nextern function fillMode(p: Ptr<Mode> | null): int32;\nextern function fillI64(p: Ptr<int64> | null): int32;\nextern function fillAny(p: Ptr<void> | null): int32;\nextern function readI32(p: Borrow<int32>): int32;\nfunction keep(p: Ptr<int32> | null): int32 { return p == null ? 0 : 1; }\nfunction one(): int32 { return 1; }\nfunction peek(ref n: int32): int32 { return readI32(n); }", expected: 0 },
	];
	for (const item of cases) {
		const result = compileToCWithStd(item.source);
		assert result.ok == (item.expected == 0), item.name + (result.ok ? "" : ": " + result.error);
	}
}

test "pointerSlotRelation: stacked ownership modifiers preserve the underlying relation" {
	const cases = [
		{ name: "a node passes a sink cursor parameter", source: "\ninterface N { k: int32; }\nextern function g(x: Cursor<N>): void from \"g\";\nextern function k(sink x: Cursor<N>): void from \"k\";\nfunction run(n: N): void {\n\tg(n);\n\tk(n);\n}\n", expected: 0 },
		{ name: "a mismatched type still fails a sink cursor parameter", source: "\ninterface N { k: int32; }\nextern function g(x: Cursor<N>): void from \"g\";\nextern function k(sink x: Cursor<N>): void from \"k\";\nfunction run(n: N): void {\n\tg(n);\n\tk(n);\n}\nk(1);\n", expected: -1 },
	];
	for (const item of cases) {
		const result = compileToC(item.source);
		assert result.ok == (item.expected == 0), item.name + (result.ok ? "" : ": " + result.error);
	}
}

test "pointer slot relation: forwarding a reference preserves one address layer" {
	const source = "extern function writeTyped(p: Ptr<int32> | null): int32; extern function writeOpaque(p: Ptr<void> | null): int32; extern function readBorrow(p: Borrow<int32>): int32; function forward(ref n: int32): int32 { writeTyped(n); writeOpaque(n); return readBorrow(n); }";
	const c = compileToCWithStd(source);
	assert c.ok, c.error;
	assert c.value.contains("writeTyped((&((*n_p0))))");
	assert c.value.contains("writeOpaque((&((*n_p0))))");
	assert c.value.contains("readBorrow((&((*n_p0))))");
}

test "pointer slot relation: reference cursors retain reference reads without scalar reinterpretation" {
	const source = "class Node { value: int32 = 0; next: Ptr<Node>; } function read(n: Node): int32 { return n.value; } function f(): int32 { const first = new Node(); const second = new Node(); const cursor: Ptr<Node> = first; first.next = second; return read(first.next) + read(cursor); }";
	assert strictErrorCount(source) == 0;
}

test "pointer slot relation: explicit dereference requires a typed value pointer" {
	const pre = "struct Value { n: int32; } class ObjectValue { n: int32 = 1; } interface InterfaceValue { n: int32; } type ObjectType = { n: int32 }; ";
	const setup = "const value: Value = { n: 1 }; const object = new ObjectValue(); const reference: InterfaceValue = { n: 1 }; const shape: ObjectType = { n: 1 }; const array: int32[] = [1]; const opaque = null as unknown as Ptr<void>; ";
	for (const operand of ["value", "object", "reference", "shape", "array", "opaque"]) {
		const source = pre + "function f(): void { " + setup + "const copied = " + operand + "[]; }";
		const c = compileToCWithStd(source);
		assert !c.ok, operand;
	}
	const c = compileToCWithStd(pre + "function f(): void { let arena: Value[1] = [{ n: 1 }]; const pointer = arena[0] as Ptr<Value>; pointer[].n = 4; const copied: Value = pointer[]; }");
	assert c.ok, c.error;
}

test "pointerSlotRelation: a typed pointer fits an untyped pointer slot, the reverse needs a cast" {
	const header = "extern struct Opaque;\n"
		+ "extern function newOpaque(): Ptr<Opaque>;\n"
		+ "extern function useOpaque(p: Ptr<Opaque>): void;\n"
		+ "function erase(p: Ptr<void>): void {}\n";
	const cases = [
		{
			name: "a typed pointer passes as an untyped pointer",
			body: "erase(newOpaque());",
			expected: 0,
		},
		{
			name: "a typed pointer initializes an untyped pointer",
			body: "const raw: Ptr<void> = newOpaque(); erase(raw);",
			expected: 0,
		},
		{
			name: "an untyped pointer is refused as a typed argument",
			body: "const raw: Ptr<void> = newOpaque(); useOpaque(raw);",
			expected: -1,
		},
		{
			name: "an untyped pointer is refused by a typed declaration",
			body: "const raw: Ptr<void> = newOpaque(); const typed: Ptr<Opaque> = raw;",
			expected: -1,
		},
		{
			name: "an untyped pointer passes as a typed pointer through a cast",
			body: "const raw: Ptr<void> = newOpaque(); useOpaque(raw as Ptr<Opaque>);",
			expected: 0,
		},
	];
	for (const item of cases) {
		const result = compileToC(header + item.body);
		assert result.ok == (item.expected == 0), item.name + (result.ok ? "" : ": " + result.error);
	}
}

function receiverProgram(declarations: string, body: string): string {
	const result = compileToCWithStd(`
struct Pet { hunger: uint16; name: string; }
${declarations}
function main(): int32 {
	let arena: Pet[1] = [{ hunger: 10, name: "a" }];
	const ptr = arena[0] as Ptr<Pet>;
	let pet: Pet = { hunger: 10, name: "a" };
	${body}
	return 0;
}
process.exit(main());
`);
	return result.ok ? result.value : "error: " + result.error;
}

test "pointerSlotRelation: a method call refuses a value for a pointer receiver as the free call does" {
	const declarations = "function feed(this p: Ptr<Pet>, n: uint16): uint16 { return p.hunger - n; }";
	const methodForm = receiverProgram(declarations, "console.log(pet.feed(3));");
	const freeForm = receiverProgram(declarations, "console.log(feed(pet, 3));");
	const receiverMismatch = "Argument type mismatch in 'feed' receiver: got Pet, expected Ptr<Pet>";
	const argumentMismatch = "Argument type mismatch in 'feed' arg 0: got Pet, expected Ptr<Pet>";
	assert methodForm.contains(receiverMismatch), methodForm;
	assert freeForm.contains(argumentMismatch), freeForm;
}

test "pointerSlotRelation: a method call on a Ptr<T> or Var<T> receiver lowers as the free call" {
	const cases = [
		{
			name: "a struct pointee",
			declarations: "function feed(this p: Ptr<Pet>, n: uint16): uint16 { "
				+ "p.hunger = p.hunger - n; return p.hunger; }",
			methodCall: "console.log(ptr.feed(3));",
			freeCall: "console.log(feed(ptr, 3));",
		},
		{
			name: "a Var receiver",
			declarations: "function rename(this p: Var<Pet>, name: string): void { p.name = name; }",
			methodCall: "pet.rename(\"b\"); console.log(pet.name);",
			freeCall: "rename(pet, \"b\"); console.log(pet.name);",
		},
		{
			name: "a primitive pointee",
			declarations: "extern function cellPointer(): Ptr<int32>;\n"
				+ "function bump(this p: Ptr<int32>, by: int32): int32 { p[] = p[] + by; return p[]; }",
			methodCall: "const c = cellPointer(); console.log(c.bump(2));",
			freeCall: "const c = cellPointer(); console.log(bump(c, 2));",
		},
	];
	for (const item of cases) {
		const methodForm = receiverProgram(item.declarations, item.methodCall);
		assert !methodForm.startsWith("error:"), item.name + ": " + methodForm;
		assert methodForm == receiverProgram(item.declarations, item.freeCall), item.name;
	}
}

test "pointerSlotRelation: a struct value into a Ref slot is refused and the refusal names the Ref" {
	const pre = "struct P { n: int32; s: string; }\nfunction mk(): P { return { n: 1, s: \"x\" }; }\nfunction one(): int32 { return 1; }\nfunction show(r: Ref<P>): int32 { return r.n; }\nstruct H { r: Ref<P>; }\n";
	const refused = "Type 'P' is not assignable to type 'Ref<P>' — a struct value is never copied into a new Ref implicitly";
	assert hasError(pre + "const r: Ref<P> = mk();", refused);
	assert hasError(pre + "const h: H = { r: mk() };", refused);
	assert hasError(pre + "const n = show(mk());", "got P, expected Ref<P>");
	assert hasError(pre + "const c: Ref<int32> = one();", "type 'Ref<int32>'");
	assert strictErrorCount(pre + "const r: Ref<P> = { ...mk() };\nconst h: H = { r: { n: 2, s: \"y\" } };") == 0;
}

function refusalsOf(source: string): string[] {
	return checkSource(source).errors.filter((e) => e.severity == Severity.Error).map((e) => e.message);
}

function refusedOnlyBy(source: string, starts: string, ends: string): string {
	const errors = refusalsOf(source);
	if (errors.length > 0 && !errors.some((e) => !e.startsWith(starts) || !e.endsWith(ends))) return "";
	return source + " gave [" + errors.join(" | ") + "], wanted only '" + starts + "..." + ends + "'";
}

test "pointerSlotRelation: a Ref of a reference type is refused at the type and names it as written" {
	const pre = "class P { x: int32 = 0; }\nclass G<T> { v: T; constructor(v: T) { this.v = v; } }\ninterface I { n: int32; }\ntype AP = P;\ntype D = distinct P;\nstruct S { n: int32; }\n";
	const cases = [
		{ body: "function run(): void { const a = new P(); const r: Ref<P> = a; r.x = 3; }", written: "P", what: "a class value" },
		{ body: "function set(r: Ref<P>): void { r.x = 3; }\nset(new P());", written: "P", what: "a class value" },
		{ body: "const g = new G<int32>(1);\nconst r: Ref<G<int32>> = g;", written: "G<int32>", what: "a class value" },
		{ body: "const r: Ref<AP> = new P();", written: "AP", what: "a class value" },
		{ body: "function f(r: Ref<D>): void { }", written: "D", what: "a class value" },
		{ body: "function f(r: Ref<(P)>): void { }", written: "P", what: "a class value" },
		{ body: "const i: I = { n: 1 };\nconst r: Ref<I> = i;", written: "I", what: "an interface value" },
		{ body: "function read(r: Ref<I>): int32 { return r.n; }\nconst n = read({ n: 1 });", written: "I", what: "an interface value" },
		{ body: "const r: Ref<Ref<S>> = { n: 1 };", written: "Ref<S>", what: "'Ref<S>'" },
		{ body: "function f(r: Ref<Owned<P>>): void { }", written: "Owned<P>", what: "'Owned<P>'" },
		{ body: "function f(r: Ref<Arc<S>>): void { }", written: "Arc<S>", what: "'Arc<S>'" },
		{ body: "function f(r: Ref<Locked<S>>): void { }", written: "Locked<S>", what: "'Locked<S>'" },
		{ body: "function f(r: Ref<int32[]>): void { }", written: "int32[]", what: "'int32[]'" },
		{ body: "function f(r: Ref<Map<string, int32>>): void { }", written: "Map<string, int32>", what: "" },
		{ body: "function f(r: Ref<{ x: int32 }>): void { }", written: "{ x: int32 }", what: "" },
	];
	const problems: string[] = [];
	for (const item of cases) {
		const starts = "Ref<T> takes a value type, got '" + item.written + "': " + item.what;
		const problem = refusedOnlyBy(pre + item.body, starts, " is already a counted reference, so write '" + item.written + "'");
		if (problem != "") problems.push(problem);
	}
	assert problems.length == 0, problems.join("\n");
	assert strictErrorCount(pre + "const r: Ref<S> = { n: 1 };\nconst k: Ref<int32> | null = null;\nconst t: Ref<string> | null = null;\nfunction g(r: Ref<Vec<int32>>): void { }") == 0;
}

test "pointerSlotRelation: a Ref that an instantiation fills with a reference type is refused at the instantiation on C and JS" {
	const pre = "class P { x: int32 = 0; }\ninterface I { n: int32; }\nstruct S { n: int32; }\nstruct Box<T> { r: Ref<T>; }\n";
	const cases = [
		{ body: "function run(): void { const a = new P(); const b: Box<P> = { r: a }; b.r.x = 3; console.log(\"gs \" + a.x.toString()); }\nrun();",
			starts: "Ref<T> takes a value type, but 'Box<P>' binds T = 'P': a class value" },
		{ body: "function run(): void { const i: I = { n: 1 }; const b: Box<I> = { r: i }; b.r.n = 3; console.log(\"gi \" + i.n.toString()); }\nrun();",
			starts: "Ref<T> takes a value type, but 'Box<I>' binds T = 'I': an interface value" },
		{ body: "function set<T>(r: Ref<T>, v: T): void { }\nfunction run(): void { const a = new P(); set<P>(a, a); console.log(\"gf \" + a.x.toString()); }\nrun();",
			starts: "Ref<T> takes a value type, but 'set<P>' binds T = 'P': a class value" },
		{ body: "class H<T> { v: T; r: Ref<T> | null = null; constructor(v: T) { this.v = v; } }\nconst h = new H(new P());\nconsole.log(\"gc \" + h.v.x.toString());",
			starts: "Ref<T> takes a value type, but 'H<P>' binds T = 'P': a class value" },
		{ body: "function mk<T>(v: T): T { let r: Ref<T> | null = null; return v; }\nconst q = mk(new P());\nconst n = mk(1);\nconsole.log(\"gb \" + n.toString());",
			starts: "Ref<T> takes a value type, but 'mk<P>' instantiated at " },
		{ body: "function f(r: Ref<Owned<P>>): void { }\nf(new P());", starts: "Ref<T> takes a value type, got 'Owned<P>': 'Owned<P>'" },
		{ body: "function f(r: Ref<(P)>): void { }\nf(new P());", starts: "Ref<T> takes a value type, got 'P': a class value" },
		{ body: "function run(): void { const xs: int32[] = [1]; const r: Ref<int32[]> = xs; r.push(2); console.log(\"arr \" + xs.length.toString()); }\nrun();",
			starts: "Ref<T> takes a value type, got 'int32[]': 'int32[]'" },
	];
	const problems: string[] = [];
	for (const item of cases) {
		const c = compileToC(pre + item.body);
		const js = compileToJS(pre + item.body);
		if (c.ok || c.error.indexOf(item.starts) < 0) problems.push("C: " + item.body + " gave " + (c.ok ? "a program" : c.error));
		if (js.ok || js.error.indexOf(item.starts) < 0) problems.push("JS: " + item.body + " gave " + (js.ok ? "a program" : js.error));
	}
	assert problems.length == 0, problems.join("\n");
	const bodyRefusal = compileToC(pre + cases[4].body);
	assert !bodyRefusal.ok && bodyRefusal.error.indexOf("binds T = 'P': a class value is already a counted reference") >= 0 && bodyRefusal.error.indexOf("mk<int32>") < 0, bodyRefusal.ok ? "" : bodyRefusal.error;
	const values = "function mk<T>(v: T): T { let r: Ref<T> | null = null; return v; }\nconst n = mk(1);\nconst s = mk<S>({ n: 1 });\nconst b: Box<S> = { r: { n: 2 } };\nconsole.log(\"v \" + n.toString() + \" \" + b.r.n.toString());";
	const cValues = compileToC(pre + values);
	const jsValues = compileToJS(pre + values);
	assert cValues.ok, cValues.ok ? "" : cValues.error;
	assert jsValues.ok, jsValues.ok ? "" : jsValues.error;
}

test "pointerSlotRelation: a class or interface value keeps its plain name in a refusal" {
	assert hasError("class A { n: int32 = 1; }\nclass B { s: string = \"\"; }\nconst b: B = new A();", "Type 'A' is not assignable to type 'B'");
	assert hasError("interface I { n: int32; }\ninterface J { s: string; }\nconst i: I = { n: 1 };\nconst j: J = i;", "Type 'I' is not assignable to type 'J'");
}

test "pointerSlotRelation: a Ref of a value is never dereferenced implicitly; x[] reads it" {
	const pre = "struct S { n: int32; }\nstruct Pair<T> { a: T; b: T; }\nfunction get2(x: S): int32 { return x.n; }\nfunction get(this x: S): int32 { return x.n; }\nfunction firstOf<T>(p: Pair<T>): T { return p.a; }\nconst v: Ref<S> = { n: 10 };\nconst pair: Ref<Pair<int32>> = { a: 1, b: 2 };\n";
	const hint = "a Ref is never dereferenced implicitly: write 'v[]'";
	assert hasError(pre + "const n = get2(v);", "got Ref<S>, expected S — " + hint);
	assert hasError(pre + "const w: S = v;", "Type 'Ref<S>' is not assignable to type 'S' — " + hint);
	assert hasError(pre + "const n = v.get();", "receiver: got Ref<S>, expected S — " + hint);
	assert hasError(pre + "const one = firstOf(pair);", "write 'pair[]'");
	assert hasError("struct P { a: int32; }\nstruct D extends P { b: int32; }\nfunction readP(p: P): int32 { return p.a; }\nconst r: Ref<D> = { a: 1, b: 2 };\nconst n = readP(r);", "got Ref<D>, expected P — a Ref is never dereferenced implicitly: write 'r[]'");
	assert strictErrorCount(pre + "const n = get2(v[]) + v[].get() + firstOf(pair[]);\nconst w: S = v[];") == 0;
}
