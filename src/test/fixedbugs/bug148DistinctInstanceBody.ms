// bug148 — a generic instance over `distinct T` was emitted with the un-substituted body
// Symptom: `type Wrap<T> = distinct T`; a parameter, return or field typed `Wrap<int32>` came out as `void *` in C
//          (clang: passing 'void *' to parameter of incompatible type 'double'), and a value of
//          `type Box<T> = distinct T[]` crashed at run time; the js lane was fine.
// Root cause: distinctInstanceRepr returned the distinct declaration's generic body with `T` still free — only
//             distinctBody substituted the instance's type arguments, while the C type desc, peelToRepr and the
//             parameter ABI read the un-substituted one.
// Fix: one substitution routine (instanceBody) behind both helpers: the eager body when the instance carries one,
//      else the declaration body with the instance's arguments substituted.

type Wrap148<T> = distinct T;
type Box148<T> = distinct T[];
type Cnt148<E> = distinct number;

interface Row148 { name: Wrap148<string>; n: Wrap148<int32>; }

function bump148(w: Wrap148<int32>): Wrap148<int32> { return ((w as int32) + 1) as Wrap148<int32>; }
function inc148(x: Cnt148<string>): Cnt148<string> { return ((x as number) + 1) as Cnt148<string>; }

test "a distinct over a type parameter is passed and returned with the substituted representation" {
	const w = 5 as Wrap148<int32>;
	const b = bump148(w);
	assert (b as int32) === 6;
}

test "struct fields of a distinct over a type parameter carry the substituted representation" {
	const rows: Row148[] = [{ name: "hi" as Wrap148<string>, n: 7 as Wrap148<int32> }, { name: "yo" as Wrap148<string>, n: 8 as Wrap148<int32> }];
	let total = 0;
	for (const x of rows) { total = total + (x.n as int32); }
	assert total === 15;
	assert (rows[0].name as string) === "hi";
}

test "a distinct over an array of the type parameter iterates through its base" {
	const b = [1, 2, 3] as Box148<int32>;
	const inner = b as int32[];
	let sum = 0;
	for (const v of inner) { sum = sum + v; }
	assert inner.length === 3;
	assert sum === 6;
}

test "a phantom distinct keeps its scalar representation" {
	const c = 3 as Cnt148<string>;
	assert (inc148(c) as number) === 4;
}
