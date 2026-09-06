// bug129 — same-named methods on a class share one emitted name
//
// Symptom:    two methods with the same name on a class emitted one C function
//             name for both bodies ("conflicting types for 'Box_describe__…_u0'"),
//             and on js the later class member overwrote the earlier one, so
//             every call silently ran the last body.
// Root cause: src/checker/collectPass.ms — a routine only receives its
//             emitted-name disambiguator when its symbol passes through
//             defineSymbol (scope insertion). Class methods are registered in
//             the extension registry instead and never reach that path, so
//             every method symbol kept overloadIdx 0. Free functions and
//             standalone extension methods were unaffected, and the checker
//             already resolved the call to the right symbol.
// Fix:        collectClassMethod chains a same-named sibling method onto the
//             first one's overload set and takes the next slot, exactly as
//             defineSymbol does for free functions, so each method owns a
//             distinct emitted name on both backends. The slot counter spans
//             static and instance methods together: the C name places both in
//             one namespace, so splitting the counter by static-ness puts a
//             static and an instance method of one name back on the same name.

class Box {
	v: int32 = 0;
	describe(n: int32): string { return "int:" + n.toString(); }
	describe(s: string): string { return "str:" + s; }
	add(a: int32): int32 { return a; }
	add(a: int32, b: int32): int32 { return a + b; }
	pick(n: int32): int32 { return n + 1; }
	pick(s: string): string { return "s:" + s; }
	static make(n: int32): string { return "static-int:" + n.toString(); }
	static make(s: string): string { return "static-str:" + s; }
}

test "bug129: instance method overload dispatches on param type" {
	const b = new Box();
	assert b.describe(5) == "int:5";
	assert b.describe("x") == "str:x";
}

test "bug129: instance method overload dispatches on arity" {
	const b = new Box();
	assert b.add(2) == 2;
	assert b.add(2, 3) == 5;
}

test "bug129: static method overload dispatches on param type" {
	assert Box.make(5) == "static-int:5";
	assert Box.make("x") == "static-str:x";
}

class Slot {
	static of(n: int32): string { return "static:" + n.toString(); }
	of(s: string): string { return "inst:" + s; }
}

test "bug129: a static and an instance method may share a name" {
	const s = new Slot();
	assert Slot.of(5) == "static:5";
	assert s.of("x") == "inst:x";
}

test "bug129: overloaded methods may differ in return type" {
	const b = new Box();
	assert b.pick(4) == 5;
	assert b.pick("x") == "s:x";
}
