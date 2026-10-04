// @stdout: 3 3 3 0 2 2 2 00
// @exit: 0
// note: a macro argument may name a generic class (`Box`, `Map`) and expands at once, at module level and in a function, instead of waiting for an instantiation that never comes ("MacroInvocation reached C codegen unlowered"); a type parameter of the enclosing generic still waits for its instance, where `getImpl` of the bound `T` is nil as in the reference; `getTypeArg()` resolves a generic instance written at the call site (`Pair<int32>`, `Pair<Escrow>`) instead of looking the text up as a name; a builtin type (`int32`, `string`) is a type argument too, read with `getTypeImpl`, and its `getImpl` is null as in the reference, where it used to stop the build with "node is not a symbol".

import { declKind, typeArgKind, hasTypeImpl } from "./describe";

struct Escrow { seed: uint64; }
struct Pair<T> { a: T; b: T; }
class Box<U> { u: U; constructor(u: U) { this.u = u; } }
class Holder<T> {
	v: T;
	constructor(v: T) { this.v = v; }
	kind(): int32 { return declKind(T); }
}

const top: int32 = declKind(Box);

function main(): void {
	const box: int32 = declKind(Box);
	const map: int32 = declKind(Map);
	const bound: int32 = new Holder<Escrow>({ seed: 1 }).kind();
	const pair: int32 = typeArgKind<Pair<int32>>();
	const nested: int32 = typeArgKind<Pair<Escrow>>();
	const builtins: int32 = hasTypeImpl(int32) + hasTypeImpl(string);
	const builtinImpls = `${declKind(int32)}${declKind(string)}`;
	console.log(`${top} ${box} ${map} ${bound} ${pair} ${nested} ${builtins} ${builtinImpls}`);
}

main();
