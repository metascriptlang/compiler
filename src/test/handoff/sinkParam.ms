// `sink name: T` is a contextual parameter modifier, same family as out/ref:
// the declared type carries Sink, the analyzer reads the argument's ownership
// from it, and everything that compares or substitutes types looks through it.

import { compileToC } from "../helpers";

test "a literal argument reaches a sink overload" {
	const src = `
extern function put(this arr: uint8[], sink value: uint8): void from "&msUint8ArrayPush";
extern function put<T>(this arr: T[], value: T): void from "&msGenericArrayPush";
export function fill(): int32 {
	const a: uint8[] = [];
	a.put(0);
	return a.length;
}
`;
	const r = compileToC(src);
	assert r.ok, r.ok ? "" : r.error;
	assert r.value.contains("msUint8ArrayPush(");
}

test "a generic sink parameter binds T from the argument" {
	const src = `
class Pet { hunger: int32 = 3; }
extern function put<T>(this arr: T[], sink value: T): void from "&msGenericArrayPush";
export function fill(): int32 {
	const pets: Pet[] = [];
	pets.put(new Pet());
	return pets.length;
}
`;
	const r = compileToC(src);
	assert r.ok, r.ok ? "" : r.error;
}

test "sink as a param name compiles" {
	const src = `
export function pick(sink: int32): int32 {
	return sink;
}
`;
	const r = compileToC(src);
	assert r.ok, r.ok ? "" : r.error;
}

test "a sink parameter on a function with a body is rejected" {
	const src = `
class Pet { hunger: int32 = 3; }
export function eat(sink p: Pet): int32 { return 1; }
`;
	const r = compileToC(src);
	assert !r.ok;
	assert r.error.contains("only an extern declaration can take ownership");
}
