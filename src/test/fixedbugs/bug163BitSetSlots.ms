// bug163 — a BitSet in a slot typed by kind did not reach C
// Symptom: `BitSet<E>[]` emitted `msRefArray` (clang: assigning to 'void *' from 'uint8_t');
//          `Box<BitSet<E>>` and `HashMap<string, BitSet<E>>` re-checked their bodies with `T`
//          spelled `unknown`; `BitSet<E> | null` was a raw union whose C did not compile.
// Root cause: elemArrayCName, monoConcreteTypeName, injectConcreteTypeSyms and isMaybeWrappable
//             each dispatched on TypeKind with an arm for the sibling kinds and none for Set.
// Fix: a Set arm in each, following the arm next to it (Distinct peel, Array recursion,
//      value-type Maybe wrapping).

import { compileToC, compileToCWithStd } from "../helpers";

const E163 = "enum E { A, B, C, D } const some: BitSet<E> = E.A | E.C; ";

function cFor(body: string): string {
	const c = compileToC(E163 + body);
	if (!c.ok) return "";
	return c.value;
}

test "bug163: an array of sets is an array of the set's word" {
	const c = cFor("const arr: BitSet<E>[] = [some]; console.log(arr[0].has(E.A));");
	assert c != "";
	assert c.contains("msUint8Array* arr");
}

test "bug163: a set as a generic class argument re-checks the body with the set type" {
	const c = cFor("class Box<T> { v: T; constructor(v: T) { this.v = v; } get(): T { return this.v; } } const b: Box<BitSet<E>> = new Box(some); console.log(b.get().has(E.C));");
	assert c != "";
	assert c.contains("uint8_t v;");
}

test "bug163: a set as a HashMap value instantiates the std methods" {
	const c = compileToCWithStd(E163 + "const m: HashMap<string, BitSet<E>> = new HashMap(); m.set(\"k\", some); const g = m.get(\"k\"); console.log(g != null ? g.has(E.C) : false);");
	assert c.ok;
}

test "bug163: a nullable set is carried as a Maybe, not a raw union" {
	const c = cFor("function pick(on: boolean): BitSet<E> | null { return on ? some : null; } const g = pick(true); console.log(g != null ? g.has(E.C) : false);");
	assert c != "";
	assert !c.contains("msUnion_");
}
