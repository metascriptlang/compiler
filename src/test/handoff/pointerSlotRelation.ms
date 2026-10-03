import { strictErrorCount } from "./helpers";
import { compileToC, compileToCWithStd } from "../helpers";

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
		{ name: "the pointee struct into an extern, and null, are accepted", source: "\nstruct P { a: int32; }\nstruct Q { b: int32; }\nfunction f(p: Ptr<P> | null): int32 { return p == null ? 0 : p.a; }\nextern function g(p: Ptr<P> | null): int32;\nfunction main(): void { const p: P = { a: 1 }; g(p); g(null); f(null); }", expected: 0 },
		{ name: "a struct into a MetaScript function's Ptr<C> | null param is refused", source: "\nstruct C { a: int32; }\nfunction keep(p: Ptr<C> | null): int32 { return p == null ? 0 : p.a; }\nfunction pick<T>(p: Ptr<C> | null, t: T): int32 { return p == null ? 0 : p.a; }\nclass K { take(p: Ptr<C> | null): int32 { return p == null ? 0 : p.a; } }\nextern function ext(p: Ptr<C> | null): int32;\nfunction bump(ref p: C): void { p.a = p.a + 1; }\nfunction main(): void { const c: C = { a: 1 }; keep(c); }", expected: -1 },
		{ name: "the same through a method, a closure and a generic function", source: "\nstruct C { a: int32; }\nfunction keep(p: Ptr<C> | null): int32 { return p == null ? 0 : p.a; }\nfunction pick<T>(p: Ptr<C> | null, t: T): int32 { return p == null ? 0 : p.a; }\nclass K { take(p: Ptr<C> | null): int32 { return p == null ? 0 : p.a; } }\nextern function ext(p: Ptr<C> | null): int32;\nfunction bump(ref p: C): void { p.a = p.a + 1; }\nfunction main(): void { const c: C = { a: 1 }; const k = new K(); k.take(c); }", expected: -1 },
		{ name: "the same through a method, a closure and a generic function", source: "\nstruct C { a: int32; }\nfunction keep(p: Ptr<C> | null): int32 { return p == null ? 0 : p.a; }\nfunction pick<T>(p: Ptr<C> | null, t: T): int32 { return p == null ? 0 : p.a; }\nclass K { take(p: Ptr<C> | null): int32 { return p == null ? 0 : p.a; } }\nextern function ext(p: Ptr<C> | null): int32;\nfunction bump(ref p: C): void { p.a = p.a + 1; }\nfunction main(): void { const c: C = { a: 1 }; const f = (p: Ptr<C> | null): int32 => 0; f(c); }", expected: -1 },
		{ name: "the same through a method, a closure and a generic function", source: "\nstruct C { a: int32; }\nfunction keep(p: Ptr<C> | null): int32 { return p == null ? 0 : p.a; }\nfunction pick<T>(p: Ptr<C> | null, t: T): int32 { return p == null ? 0 : p.a; }\nclass K { take(p: Ptr<C> | null): int32 { return p == null ? 0 : p.a; } }\nextern function ext(p: Ptr<C> | null): int32;\nfunction bump(ref p: C): void { p.a = p.a + 1; }\nfunction main(): void { const c: C = { a: 1 }; pick(c, 1); }", expected: -1 },
		{ name: "an extern callee still takes the address, and null and ref still work", source: "\nstruct C { a: int32; }\nfunction keep(p: Ptr<C> | null): int32 { return p == null ? 0 : p.a; }\nfunction pick<T>(p: Ptr<C> | null, t: T): int32 { return p == null ? 0 : p.a; }\nclass K { take(p: Ptr<C> | null): int32 { return p == null ? 0 : p.a; } }\nextern function ext(p: Ptr<C> | null): int32;\nfunction bump(ref p: C): void { p.a = p.a + 1; }\nfunction main(): void { const c: C = { a: 1 }; ext(c); ext(null); keep(null); let m: C = { a: 1 }; bump(m); }", expected: 0 },
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
	assert c.value.contains("writeTyped(&((*n)))");
	assert c.value.contains("writeOpaque(&((*n)))");
	assert c.value.contains("readBorrow(&((*n)))");
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
